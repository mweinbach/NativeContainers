import AppKit
import Darwin
import Foundation

struct HostCommandResult: Equatable, Sendable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String
  let outputWasTruncated: Bool
}

struct HostProcessOutput: Equatable, Sendable {
  let standardOutput: String
  let standardError: String
  let wasTruncated: Bool

  var combinedForError: String {
    let combined = [standardError, standardOutput]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(combined.suffix(2_000))
  }
}

struct HostProcessConfiguration: Sendable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]?
  let currentDirectoryURL: URL?
  let observeApplicationTermination: Bool
  let applicationTerminationCleanup: (@Sendable () -> Void)?

  init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    observeApplicationTermination: Bool = false,
    applicationTerminationCleanup: (@Sendable () -> Void)? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL
    self.observeApplicationTermination = observeApplicationTermination
    self.applicationTerminationCleanup = applicationTerminationCleanup
  }
}

protocol HostProcessSession: AnyObject, Sendable {
  var processID: Int32 { get }
  var isRunning: Bool { get }
  var terminationStatus: Int32? { get }
  func send(signal: Int32) throws
  func capturedOutput() -> HostProcessOutput
}

protocol HostProcessLaunching: Sendable {
  func launch(_ configuration: HostProcessConfiguration) throws -> any HostProcessSession
}

protocol HostCommandExecuting: Sendable {
  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult
}

extension HostCommandExecuting {
  func execute(
    executableURL: URL,
    arguments: [String],
    timeout: Duration = .seconds(15)
  ) async throws -> HostCommandResult {
    try await execute(
      executableURL: executableURL,
      arguments: arguments,
      environment: nil,
      timeout: timeout
    )
  }
}

enum HostProcessError: LocalizedError, Equatable, Sendable {
  case launchFailed(String)
  case signalFailed(signal: Int32, code: Int32)
  case timedOut
  case didNotExitAfterKill

  var errorDescription: String? {
    switch self {
    case .launchFailed(let reason):
      "The host process could not be launched: \(reason)"
    case .signalFailed(let signal, let code):
      "Signal \(signal) could not be sent to the owned process (errno \(code))."
    case .timedOut:
      "The host command timed out."
    case .didNotExitAfterKill:
      "The host command did not confirm exit after SIGKILL."
    }
  }
}

struct FoundationHostProcessLauncher: HostProcessLaunching {
  let maximumOutputBytes: Int

  init(maximumOutputBytes: Int = 1_024 * 1_024) {
    precondition(maximumOutputBytes > 0)
    self.maximumOutputBytes = maximumOutputBytes
  }

  func launch(_ configuration: HostProcessConfiguration) throws -> any HostProcessSession {
    do {
      return try FoundationHostProcessSession(
        configuration: configuration,
        maximumOutputBytes: maximumOutputBytes
      )
    } catch {
      throw HostProcessError.launchFailed(error.localizedDescription)
    }
  }
}

actor FoundationHostCommandExecutor: HostCommandExecuting {
  private let launcher: any HostProcessLaunching
  private let pollInterval: Duration
  private let terminationGracePeriod: Duration
  private let killConfirmationTimeout: Duration

  init(
    launcher: any HostProcessLaunching = FoundationHostProcessLauncher(),
    pollInterval: Duration = .milliseconds(50),
    terminationGracePeriod: Duration = .milliseconds(500),
    killConfirmationTimeout: Duration = .seconds(2)
  ) {
    self.launcher = launcher
    self.pollInterval = pollInterval
    self.terminationGracePeriod = terminationGracePeriod
    self.killConfirmationTimeout = killConfirmationTimeout
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    let session = try launcher.launch(
      HostProcessConfiguration(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        observeApplicationTermination: true
      )
    )

    do {
      let didExit = try await waitForExit(session, timeout: timeout)
      guard didExit else {
        try await terminateUncancelled(session)
        throw HostProcessError.timedOut
      }
    } catch is CancellationError {
      try await terminateUncancelled(session)
      throw CancellationError()
    }

    let output = session.capturedOutput()
    return HostCommandResult(
      exitCode: session.terminationStatus ?? -1,
      standardOutput: output.standardOutput,
      standardError: output.standardError,
      outputWasTruncated: output.wasTruncated
    )
  }

  private func terminateUncancelled(_ session: any HostProcessSession) async throws {
    let pollInterval = pollInterval
    let terminationGracePeriod = terminationGracePeriod
    let killConfirmationTimeout = killConfirmationTimeout

    try await Task.detached(priority: .userInitiated) {
      if session.isRunning {
        try session.send(signal: SIGTERM)
        if await Self.waitForExitUncancelled(
          session,
          timeout: terminationGracePeriod,
          pollInterval: pollInterval
        ) {
          return
        }
      }
      if session.isRunning {
        try session.send(signal: SIGKILL)
      }
      guard
        await Self.waitForExitUncancelled(
          session,
          timeout: killConfirmationTimeout,
          pollInterval: pollInterval
        )
      else {
        throw HostProcessError.didNotExitAfterKill
      }
    }.value
  }

  private nonisolated static func waitForExitUncancelled(
    _ session: any HostProcessSession,
    timeout: Duration,
    pollInterval: Duration
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while session.isRunning {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: pollInterval)
    }
    return true
  }

  private func waitForExit(
    _ session: any HostProcessSession,
    timeout: Duration
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while session.isRunning {
      try Task.checkCancellation()
      guard clock.now < deadline else { return false }
      try await Task.sleep(for: pollInterval)
    }
    return true
  }
}

private final class FoundationHostProcessSession: HostProcessSession, @unchecked Sendable {
  private struct State {
    var processID: Int32 = 0
    var isRunning = false
    var terminationStatus: Int32?
    var standardOutput = Data()
    var standardError = Data()
    var outputWasTruncated = false
    var applicationTerminationCleanupPerformed = false
  }

  private let process = Process()
  private let standardOutputPipe = Pipe()
  private let standardErrorPipe = Pipe()
  private let maximumOutputBytes: Int
  private let stateLock = NSLock()
  private let applicationTerminationCleanup: (@Sendable () -> Void)?
  private var state = State()
  private var terminationObserver: NSObjectProtocol?

  var processID: Int32 {
    stateLock.withLock { state.processID }
  }

  var isRunning: Bool {
    stateLock.withLock { state.isRunning }
  }

  var terminationStatus: Int32? {
    stateLock.withLock { state.terminationStatus }
  }

  init(
    configuration: HostProcessConfiguration,
    maximumOutputBytes: Int
  ) throws {
    self.maximumOutputBytes = maximumOutputBytes
    applicationTerminationCleanup = configuration.applicationTerminationCleanup
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.environment = configuration.environment
    process.currentDirectoryURL = configuration.currentDirectoryURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe

    standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consume(handle.availableData, standardError: false)
    }
    standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consume(handle.availableData, standardError: true)
    }
    process.terminationHandler = { [weak self] process in
      self?.didExit(status: process.terminationStatus)
    }

    try process.run()
    stateLock.withLock {
      state.processID = process.processIdentifier
      state.isRunning = state.terminationStatus == nil
    }
    try? standardOutputPipe.fileHandleForWriting.close()
    try? standardErrorPipe.fileHandleForWriting.close()

    if configuration.observeApplicationTermination {
      terminationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.terminateSynchronouslyForApplicationExit()
        self?.performApplicationTerminationCleanup()
      }
    }
  }

  func send(signal: Int32) throws {
    let target = stateLock.withLock { () -> Int32? in
      guard state.isRunning, state.processID > 0 else { return nil }
      return state.processID
    }
    guard let target else { return }

    guard Darwin.kill(target, signal) == 0 else {
      let code = errno
      if code == ESRCH {
        stateLock.withLock {
          state.isRunning = false
        }
        return
      }
      throw HostProcessError.signalFailed(signal: signal, code: code)
    }
  }

  func capturedOutput() -> HostProcessOutput {
    stateLock.withLock {
      HostProcessOutput(
        standardOutput: String(decoding: state.standardOutput, as: UTF8.self),
        standardError: String(decoding: state.standardError, as: UTF8.self),
        wasTruncated: state.outputWasTruncated
      )
    }
  }

  private func consume(_ data: Data, standardError: Bool) {
    guard !data.isEmpty else { return }
    stateLock.withLock {
      if standardError {
        appendBounded(data, to: &state.standardError)
      } else {
        appendBounded(data, to: &state.standardOutput)
      }
    }
  }

  private func appendBounded(_ data: Data, to destination: inout Data) {
    if data.count >= maximumOutputBytes {
      destination = Data(data.suffix(maximumOutputBytes))
      state.outputWasTruncated = true
      return
    }
    let excess = destination.count + data.count - maximumOutputBytes
    if excess > 0 {
      destination.removeFirst(excess)
      state.outputWasTruncated = true
    }
    destination.append(data)
  }

  private func didExit(status: Int32) {
    drainRemainingOutput()
    stateLock.withLock {
      state.isRunning = false
      state.terminationStatus = status
    }
    removeTerminationObserver()
  }

  private func drainRemainingOutput() {
    standardOutputPipe.fileHandleForReading.readabilityHandler = nil
    standardErrorPipe.fileHandleForReading.readabilityHandler = nil
    if let data = try? standardOutputPipe.fileHandleForReading.readToEnd() {
      consume(data, standardError: false)
    }
    if let data = try? standardErrorPipe.fileHandleForReading.readToEnd() {
      consume(data, standardError: true)
    }
    try? standardOutputPipe.fileHandleForReading.close()
    try? standardErrorPipe.fileHandleForReading.close()
  }

  private func terminateSynchronouslyForApplicationExit() {
    let target = stateLock.withLock { () -> Int32? in
      guard state.isRunning, state.processID > 0 else { return nil }
      return state.processID
    }
    guard let target else { return }

    _ = Darwin.kill(target, SIGTERM)
    for _ in 0..<20 {
      if Darwin.kill(target, 0) != 0, errno == ESRCH { break }
      usleep(25_000)
    }
    if Darwin.kill(target, 0) == 0 {
      _ = Darwin.kill(target, SIGKILL)
    }
  }

  private func performApplicationTerminationCleanup() {
    let shouldRun = stateLock.withLock { () -> Bool in
      guard !state.applicationTerminationCleanupPerformed else { return false }
      state.applicationTerminationCleanupPerformed = true
      return true
    }
    if shouldRun {
      applicationTerminationCleanup?()
    }
  }

  private func removeTerminationObserver() {
    let observer = stateLock.withLock { () -> NSObjectProtocol? in
      let observer = terminationObserver
      terminationObserver = nil
      return observer
    }
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  deinit {
    removeTerminationObserver()
    let target = stateLock.withLock { state.isRunning ? state.processID : 0 }
    if target > 0 {
      _ = Darwin.kill(target, SIGKILL)
    }
    performApplicationTerminationCleanup()
  }
}
