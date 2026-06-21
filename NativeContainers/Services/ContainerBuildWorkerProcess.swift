import Darwin
import Foundation

protocol ContainerBuildWorkerExecutableLocating: Sendable {
  func locateBuildWorker() throws -> URL
}

struct DefaultContainerBuildWorkerExecutableLocator: ContainerBuildWorkerExecutableLocating {
  private static let executableName = "NativeContainersBuildWorker"

  private let bundleURL: URL
  private let bundleExecutableURL: URL?

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    bundleExecutableURL: URL? = Bundle.main.executableURL
  ) {
    self.bundleURL = bundleURL
    self.bundleExecutableURL = bundleExecutableURL
  }

  func locateBuildWorker() throws -> URL {
    if let applicationBundleURL {
      return
        applicationBundleURL
        .appending(path: "Contents", directoryHint: .isDirectory)
        .appending(path: "Helpers", directoryHint: .isDirectory)
        .appending(path: Self.executableName, directoryHint: .notDirectory)
    }

    guard let bundleExecutableURL else {
      throw ContainerBuildWorkerProcessError.executableNotFound(
        bundleURL.appending(path: Self.executableName).path(percentEncoded: false)
      )
    }
    return bundleExecutableURL.deletingLastPathComponent().appending(
      path: Self.executableName,
      directoryHint: .notDirectory
    )
  }

  private var applicationBundleURL: URL? {
    var candidate = bundleURL.standardizedFileURL
    while true {
      if candidate.pathExtension.lowercased() == "app" {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent != candidate else { return nil }
      candidate = parent
    }
  }
}

struct FixedContainerBuildWorkerExecutableLocator: ContainerBuildWorkerExecutableLocating {
  let executableURL: URL

  func locateBuildWorker() throws -> URL { executableURL }
}

enum ContainerBuildWorkerEnvironment {
  private static let inheritedRuntimeKeys: Set<String> = [
    "BUILDKIT_COLORS",
    "CONTAINER_APP_ROOT",
    "CONTAINER_DEBUG",
    "CONTAINER_DEFAULT_PLATFORM",
    "CONTAINER_INSTALL_ROOT",
    "CONTAINER_LOG_ROOT",
    "NO_COLOR",
    "XDG_CONFIG_HOME",
  ]

  static func sanitized(from source: [String: String]) -> [String: String] {
    var environment = [
      "PATH": nonempty(source["PATH"]) ?? "/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": nonempty(source["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path,
      "TMPDIR":
        nonempty(source["TMPDIR"])
        ?? FileManager.default.temporaryDirectory.path(percentEncoded: false),
    ]

    for key in inheritedRuntimeKeys {
      guard let value = nonempty(source[key]), !isSensitive(key) else { continue }
      environment[key] = value
    }
    return environment
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func isSensitive(_ key: String) -> Bool {
    let uppercased = key.uppercased()
    return key == "SSH_AUTH_SOCK"
      || uppercased.contains("REGISTRY")
      || uppercased.contains("CREDENTIAL")
      || uppercased.contains("PASSWORD")
      || uppercased.contains("SECRET")
      || uppercased.contains("TOKEN")
  }
}

enum ContainerBuildWorkerDiagnostics: Equatable, Sendable {
  case captured(tail: String, wasTruncated: Bool)
  case suppressed

  static let suppressedMessage = "Build output suppressed while secrets were mounted."

  var tail: String {
    switch self {
    case .captured(let tail, _): tail
    case .suppressed: Self.suppressedMessage
    }
  }

  var wasTruncated: Bool {
    switch self {
    case .captured(_, let wasTruncated): wasTruncated
    case .suppressed: false
    }
  }
}

struct ContainerBuildWorkerProcessOutput: Equatable, Sendable {
  let events: [ContainerBuildWorkerEvent]
  let terminalEvent: ContainerBuildWorkerEvent
  let result: ContainerBuildWorkerResult?
  let diagnostics: ContainerBuildWorkerDiagnostics
  let exitStatus: Int32

  var standardErrorTail: String { diagnostics.tail }
  var standardErrorWasTruncated: Bool { diagnostics.wasTruncated }
}

typealias ContainerBuildWorkerEventHandler =
  @Sendable (ContainerBuildWorkerEvent) async -> Void

protocol ContainerBuildWorkerRunning: Sendable {
  func run(
    _ request: ContainerBuildWorkerRequest,
    secrets: ContainerBuildSecretSourcePayload,
    onEvent: @escaping ContainerBuildWorkerEventHandler
  ) async throws -> ContainerBuildWorkerProcessOutput
}

extension ContainerBuildWorkerRunning {
  func run(
    _ request: ContainerBuildWorkerRequest,
    onEvent: @escaping ContainerBuildWorkerEventHandler = { _ in }
  ) async throws -> ContainerBuildWorkerProcessOutput {
    try await run(request, secrets: .empty, onEvent: onEvent)
  }
}

enum ContainerBuildWorkerProcessError: Error, Equatable, LocalizedError, Sendable {
  case executableNotFound(String)
  case executableNotRunnable(String)
  case launchFailed(String)
  case requestWriteFailed(String)
  case secretPayloadMismatch
  case standardOutputReadFailed(String)
  case standardErrorReadFailed(String)
  case invalidOutputFrame(ContainerBuildWorkerFrameError)
  case missingHello
  case duplicateHello
  case incompatibleProtocolVersion(received: Int?, expected: Int)
  case malformedHello
  case protocolVersionOnNonHello(ContainerBuildWorkerEventKind)
  case duplicateTerminalEvent(
    first: ContainerBuildWorkerEventKind,
    duplicate: ContainerBuildWorkerEventKind
  )
  case eventAfterTerminal(ContainerBuildWorkerEventKind)
  case missingTerminalEvent(exitStatus: Int32, standardErrorTail: String)
  case malformedTerminalEvent(ContainerBuildWorkerEventKind)
  case unexpectedTerminalEvent(
    operation: ContainerBuildWorkerOperation,
    event: ContainerBuildWorkerEventKind
  )
  case workerFailed(
    failure: ContainerBuildWorkerFailure,
    exitStatus: Int32,
    standardErrorTail: String
  )
  case nonzeroExit(status: Int32, standardErrorTail: String)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let path):
      "The native image-build worker was not found at \(path)."
    case .executableNotRunnable(let path):
      "The native image-build worker at \(path) is not an executable file."
    case .launchFailed(let message):
      "The native image-build worker could not be launched: \(message)"
    case .requestWriteFailed(let message):
      "The reviewed build request could not be sent to the worker: \(message)"
    case .secretPayloadMismatch:
      "The build worker secret payload did not match the reviewed control request."
    case .standardOutputReadFailed(let message):
      "The build worker's control stream failed: \(message)"
    case .standardErrorReadFailed(let message):
      "The build worker's diagnostic stream failed: \(message)"
    case .invalidOutputFrame(let error):
      error.localizedDescription
    case .missingHello:
      "The build worker did not identify its control-protocol version first."
    case .duplicateHello:
      "The build worker sent more than one protocol hello event."
    case .incompatibleProtocolVersion(let received, let expected):
      "The build worker uses protocol version \(received.map(String.init) ?? "none"); this app requires version \(expected)."
    case .malformedHello:
      "The build worker's protocol hello event contained operation data."
    case .protocolVersionOnNonHello(let kind):
      "The build worker's \(kind.rawValue) event unexpectedly contained a protocol version."
    case .duplicateTerminalEvent(let first, let duplicate):
      "The build worker sent duplicate terminal events (\(first.rawValue), then \(duplicate.rawValue))."
    case .eventAfterTerminal(let kind):
      "The build worker sent a \(kind.rawValue) event after its terminal event."
    case .missingTerminalEvent(let exitStatus, _):
      "The build worker exited with status \(exitStatus) without a terminal event."
    case .malformedTerminalEvent(let kind):
      "The build worker's \(kind.rawValue) terminal event had an invalid payload."
    case .unexpectedTerminalEvent(let operation, let event):
      "The \(operation.rawValue) worker operation ended with an unexpected \(event.rawValue) event."
    case .workerFailed(let failure, _, _):
      failure.message
    case .nonzeroExit(let status, _):
      "The build worker reported success but exited with status \(status)."
    }
  }
}

struct ContainerBuildWorkerProcess: ContainerBuildWorkerRunning, Sendable {
  private static let readChunkBytes = 64 * 1_024
  private static let maximumStandardErrorBytes = 1_024 * 1_024

  private let executableLocator: any ContainerBuildWorkerExecutableLocating
  private let arguments: [String]
  private let environment: [String: String]
  private let terminationGracePeriod: Duration

  init(
    executableLocator: any ContainerBuildWorkerExecutableLocating =
      DefaultContainerBuildWorkerExecutableLocator(),
    arguments: [String] = [],
    environmentSource: [String: String] = ProcessInfo.processInfo.environment,
    terminationGracePeriod: Duration = .seconds(2)
  ) {
    self.executableLocator = executableLocator
    self.arguments = arguments
    self.environment = ContainerBuildWorkerEnvironment.sanitized(from: environmentSource)
    self.terminationGracePeriod = terminationGracePeriod
  }

  func run(
    _ request: ContainerBuildWorkerRequest,
    secrets: ContainerBuildSecretSourcePayload,
    onEvent: @escaping ContainerBuildWorkerEventHandler = { _ in }
  ) async throws -> ContainerBuildWorkerProcessOutput {
    try Task.checkCancellation()
    guard (request.build?.secretIDs ?? []) == secrets.ids else {
      throw ContainerBuildWorkerProcessError.secretPayloadMismatch
    }
    let requestFrame = try ContainerBuildWorkerFrameCodec.encode(request)
    let executableURL = try executableLocator.locateBuildWorker().standardizedFileURL
    try Self.validateExecutable(executableURL)

    let session = FoundationBuildWorkerSession(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment
    )
    do {
      try session.launch()
    } catch {
      session.closeAllParentHandles()
      throw ContainerBuildWorkerProcessError.launchFailed(error.localizedDescription)
    }

    return try await withTaskCancellationHandler {
      try await execute(
        session: session,
        request: request,
        requestFrame: requestFrame,
        secrets: secrets,
        onEvent: onEvent
      )
    } onCancel: {
      session.requestTermination(after: terminationGracePeriod)
    }
  }

  private func execute(
    session: FoundationBuildWorkerSession,
    request: ContainerBuildWorkerRequest,
    requestFrame: Data,
    secrets: ContainerBuildSecretSourcePayload,
    onEvent: @escaping ContainerBuildWorkerEventHandler
  ) async throws -> ContainerBuildWorkerProcessOutput {
    let stdoutReader = WorkerFileHandleReader(handle: session.standardOutput)
    let stderrReader = WorkerFileHandleReader(handle: session.standardError)
    let gracePeriod = terminationGracePeriod
    let suppressesDiagnostics = !secrets.isEmpty

    let stdoutTask = Task.detached(priority: .userInitiated) {
      do {
        return try await Self.readEvents(
          from: stdoutReader,
          suppressesFailureDiagnostics: suppressesDiagnostics,
          onEvent: onEvent
        )
      } catch {
        session.requestTermination(after: gracePeriod)
        throw error
      }
    }
    let stderrTask = Task.detached(priority: .utility) {
      do {
        return try Self.readStandardError(
          from: stderrReader,
          suppressesDiagnostics: suppressesDiagnostics
        )
      } catch {
        session.requestTermination(after: gracePeriod)
        throw error
      }
    }

    do {
      do {
        try session.writeRequest(requestFrame, secrets: secrets)
      } catch {
        throw ContainerBuildWorkerProcessError.requestWriteFailed(error.localizedDescription)
      }

      let exitStatus = await session.waitForExit()
      session.closeInputLease()
      let eventRead = try await stdoutTask.value
      let standardError = try await stderrTask.value
      session.closeOutputHandles()
      try Task.checkCancellation()
      return try Self.validate(
        request: request,
        eventRead: eventRead,
        standardError: standardError,
        exitStatus: exitStatus
      )
    } catch {
      session.requestTermination(after: terminationGracePeriod)
      session.closeInputLease()
      _ = await session.waitForExit()
      _ = try? await stdoutTask.value
      _ = try? await stderrTask.value
      session.closeOutputHandles()
      if Task.isCancelled {
        throw CancellationError()
      }
      throw error
    }
  }

  private static func validateExecutable(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw ContainerBuildWorkerProcessError.executableNotFound(path)
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw ContainerBuildWorkerProcessError.executableNotRunnable(path)
    }
  }

  private static func readEvents(
    from reader: WorkerFileHandleReader,
    suppressesFailureDiagnostics: Bool,
    onEvent: @escaping ContainerBuildWorkerEventHandler
  ) async throws -> EventReadResult {
    var decoder = ContainerBuildWorkerFrameDecoder<ContainerBuildWorkerEvent>()
    var events: [ContainerBuildWorkerEvent] = []
    var terminalEvent: ContainerBuildWorkerEvent?
    var receivedHello = false

    do {
      while let data = try reader.read(upToCount: readChunkBytes), !data.isEmpty {
        let newEvents: [ContainerBuildWorkerEvent]
        do {
          newEvents = try decoder.append(data)
        } catch let error as ContainerBuildWorkerFrameError {
          throw ContainerBuildWorkerProcessError.invalidOutputFrame(error)
        }

        for receivedEvent in newEvents {
          let event =
            suppressesFailureDiagnostics
            ? sanitizedSecretBuildEvent(receivedEvent)
            : receivedEvent
          if event.kind == .hello {
            guard !receivedHello, events.isEmpty else {
              throw ContainerBuildWorkerProcessError.duplicateHello
            }
            guard event.phase == nil, event.result == nil, event.failure == nil else {
              throw ContainerBuildWorkerProcessError.malformedHello
            }
            guard
              event.protocolVersion == ContainerBuildWorkerRequest.currentProtocolVersion
            else {
              throw ContainerBuildWorkerProcessError.incompatibleProtocolVersion(
                received: event.protocolVersion,
                expected: ContainerBuildWorkerRequest.currentProtocolVersion
              )
            }
            receivedHello = true
          } else {
            guard receivedHello else {
              throw ContainerBuildWorkerProcessError.missingHello
            }
            guard event.protocolVersion == nil else {
              throw ContainerBuildWorkerProcessError.protocolVersionOnNonHello(event.kind)
            }
          }

          if let terminalEvent {
            if event.kind.isTerminal {
              throw ContainerBuildWorkerProcessError.duplicateTerminalEvent(
                first: terminalEvent.kind,
                duplicate: event.kind
              )
            }
            throw ContainerBuildWorkerProcessError.eventAfterTerminal(event.kind)
          }
          if event.kind.isTerminal {
            terminalEvent = event
          }
          events.append(event)
          await onEvent(event)
        }
      }
      do {
        try decoder.finish()
      } catch let error as ContainerBuildWorkerFrameError {
        throw ContainerBuildWorkerProcessError.invalidOutputFrame(error)
      }
      guard receivedHello else {
        throw ContainerBuildWorkerProcessError.missingHello
      }
    } catch let error as ContainerBuildWorkerProcessError {
      throw error
    } catch {
      throw ContainerBuildWorkerProcessError.standardOutputReadFailed(error.localizedDescription)
    }

    return EventReadResult(events: events, terminalEvent: terminalEvent)
  }

  private static func sanitizedSecretBuildEvent(
    _ event: ContainerBuildWorkerEvent
  ) -> ContainerBuildWorkerEvent {
    guard event.kind == .failed, let failure = event.failure else { return event }
    let message = ContainerBuildWorkerDiagnostics.suppressedMessage
    return ContainerBuildWorkerEvent(
      kind: .failed,
      protocolVersion: nil,
      phase: nil,
      message: message,
      result: nil,
      failure: ContainerBuildWorkerFailure(
        code: failure.code,
        message: message,
        buildID: failure.buildID,
        partialImageDigest: failure.partialImageDigest
      )
    )
  }

  private static func readStandardError(
    from reader: WorkerFileHandleReader,
    suppressesDiagnostics: Bool
  ) throws -> ContainerBuildWorkerDiagnostics {
    var tail = BoundedUTF8Tail(maximumBytes: maximumStandardErrorBytes)
    do {
      while let data = try reader.read(upToCount: readChunkBytes), !data.isEmpty {
        if !suppressesDiagnostics {
          tail.append(data)
        }
      }
    } catch {
      throw ContainerBuildWorkerProcessError.standardErrorReadFailed(error.localizedDescription)
    }
    if suppressesDiagnostics {
      return .suppressed
    }
    let captured = tail.value
    return .captured(
      tail: captured.text,
      wasTruncated: captured.wasTruncated
    )
  }

  private static func validate(
    request: ContainerBuildWorkerRequest,
    eventRead: EventReadResult,
    standardError: ContainerBuildWorkerDiagnostics,
    exitStatus: Int32
  ) throws -> ContainerBuildWorkerProcessOutput {
    guard let terminalEvent = eventRead.terminalEvent else {
      throw ContainerBuildWorkerProcessError.missingTerminalEvent(
        exitStatus: exitStatus,
        standardErrorTail: standardError.tail
      )
    }

    switch terminalEvent.kind {
    case .failed:
      guard let failure = terminalEvent.failure, terminalEvent.result == nil else {
        throw ContainerBuildWorkerProcessError.malformedTerminalEvent(.failed)
      }
      throw ContainerBuildWorkerProcessError.workerFailed(
        failure: failure,
        exitStatus: exitStatus,
        standardErrorTail: standardError.tail
      )
    case .completed:
      guard terminalEvent.result != nil, terminalEvent.failure == nil else {
        throw ContainerBuildWorkerProcessError.malformedTerminalEvent(.completed)
      }
      guard request.operation == .build else {
        throw ContainerBuildWorkerProcessError.unexpectedTerminalEvent(
          operation: request.operation,
          event: terminalEvent.kind
        )
      }
    case .builderReady:
      guard terminalEvent.result == nil, terminalEvent.failure == nil else {
        throw ContainerBuildWorkerProcessError.malformedTerminalEvent(.builderReady)
      }
      guard request.operation == .startBuilder else {
        throw ContainerBuildWorkerProcessError.unexpectedTerminalEvent(
          operation: request.operation,
          event: terminalEvent.kind
        )
      }
    case .hello, .progress:
      throw ContainerBuildWorkerProcessError.malformedTerminalEvent(terminalEvent.kind)
    }

    guard exitStatus == EXIT_SUCCESS else {
      throw ContainerBuildWorkerProcessError.nonzeroExit(
        status: exitStatus,
        standardErrorTail: standardError.tail
      )
    }

    return ContainerBuildWorkerProcessOutput(
      events: eventRead.events,
      terminalEvent: terminalEvent,
      result: terminalEvent.result,
      diagnostics: standardError,
      exitStatus: exitStatus
    )
  }
}

extension ContainerBuildWorkerEventKind {
  fileprivate var isTerminal: Bool {
    switch self {
    case .builderReady, .completed, .failed: true
    case .hello, .progress: false
    }
  }
}

private struct EventReadResult: Sendable {
  let events: [ContainerBuildWorkerEvent]
  let terminalEvent: ContainerBuildWorkerEvent?
}

private struct StandardErrorTail: Sendable {
  let text: String
  let wasTruncated: Bool
}

private struct BoundedUTF8Tail {
  let maximumBytes: Int
  private var data = Data()
  private(set) var wasTruncated = false

  mutating func append(_ newData: Data) {
    guard !newData.isEmpty else { return }
    if newData.count >= maximumBytes {
      wasTruncated = wasTruncated || !data.isEmpty || newData.count > maximumBytes
      data = Data(newData.suffix(maximumBytes))
      return
    }

    let bytesToRemove = max(0, data.count + newData.count - maximumBytes)
    if bytesToRemove > 0 {
      data.removeFirst(bytesToRemove)
      wasTruncated = true
    }
    data.append(newData)
  }

  var value: StandardErrorTail {
    StandardErrorTail(text: utf8SafeString(from: data), wasTruncated: wasTruncated)
  }

  private func utf8SafeString(from data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }

    let maximumBoundaryBytes = min(3, data.count)
    for leadingBytes in 0...maximumBoundaryBytes {
      let remaining = data.count - leadingBytes
      for trailingBytes in 0...min(3, remaining) {
        let end = data.count - trailingBytes
        guard leadingBytes <= end else { continue }
        if let text = String(data: data[leadingBytes..<end], encoding: .utf8) {
          return text
        }
      }
    }
    return String(decoding: data, as: UTF8.self)
  }
}

private final class WorkerFileHandleReader: @unchecked Sendable {
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func read(upToCount count: Int) throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: count)
    while true {
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard readCount > 0 else { return Data() }
      return Data(buffer[0..<readCount])
    }
  }
}

private final class ProcessExitWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var exitStatus: Int32?
  private var continuations: [CheckedContinuation<Int32, Never>] = []

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      let completedStatus = lock.withLock { () -> Int32? in
        if let exitStatus { return exitStatus }
        continuations.append(continuation)
        return nil
      }
      if let completedStatus {
        continuation.resume(returning: completedStatus)
      }
    }
  }

  func complete(with status: Int32) {
    let pending = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
      guard exitStatus == nil else { return [] }
      exitStatus = status
      let pending = continuations
      continuations.removeAll(keepingCapacity: false)
      return pending
    }
    for continuation in pending {
      continuation.resume(returning: status)
    }
  }
}

private final class FoundationBuildWorkerSession: @unchecked Sendable {
  private struct State {
    var processID: pid_t?
    var hasExited = false
    var cancellationRequested = false
    var watchdogStarted = false
    var inputClosed = false
    var outputClosed = false
  }

  private let process: Process
  private let inputPipe = Pipe()
  private let outputPipe = Pipe()
  private let errorPipe = Pipe()
  private let stateLock = NSLock()
  private let exitWaiter = ProcessExitWaiter()
  private var state = State()

  var standardOutput: FileHandle { outputPipe.fileHandleForReading }
  var standardError: FileHandle { errorPipe.fileHandleForReading }

  init(executableURL: URL, arguments: [String], environment: [String: String]) {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    self.process = process
    _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
  }

  func launch() throws {
    process.terminationHandler = { [weak self] process in
      self?.didExit(with: process.terminationStatus)
    }
    try process.run()
    let shouldTerminate = stateLock.withLock { () -> Bool in
      state.processID = process.processIdentifier
      return state.cancellationRequested && !state.hasExited
    }
    closeChildEndsInParent()
    if shouldTerminate {
      requestTermination(after: .seconds(2))
    }
  }

  func writeRequest(
    _ data: Data,
    secrets: ContainerBuildSecretSourcePayload
  ) throws {
    let handle = inputPipe.fileHandleForWriting
    try handle.write(contentsOf: data)
    try ContainerBuildSecretWire.write(secrets, to: handle.fileDescriptor)
  }

  func waitForExit() async -> Int32 {
    await exitWaiter.wait()
  }

  func requestTermination(after gracePeriod: Duration) {
    let action = stateLock.withLock { () -> (pid_t?, Bool) in
      state.cancellationRequested = true
      guard let processID = state.processID, !state.hasExited else { return (nil, false) }
      let shouldStartWatchdog = !state.watchdogStarted
      state.watchdogStarted = true
      return (processID, shouldStartWatchdog)
    }
    guard let processID = action.0 else { return }
    _ = Darwin.kill(processID, SIGTERM)

    if action.1 {
      Task.detached(priority: .utility) { [self] in
        try? await Task.sleep(for: gracePeriod)
        forceKillIfRunning()
      }
    }
  }

  func closeInputLease() {
    let shouldClose = stateLock.withLock { () -> Bool in
      guard !state.inputClosed else { return false }
      state.inputClosed = true
      return true
    }
    if shouldClose {
      try? inputPipe.fileHandleForWriting.close()
    }
  }

  func closeOutputHandles() {
    let shouldClose = stateLock.withLock { () -> Bool in
      guard !state.outputClosed else { return false }
      state.outputClosed = true
      return true
    }
    if shouldClose {
      try? outputPipe.fileHandleForReading.close()
      try? errorPipe.fileHandleForReading.close()
    }
  }

  func closeAllParentHandles() {
    closeInputLease()
    closeOutputHandles()
    closeChildEndsInParent()
  }

  private func closeChildEndsInParent() {
    try? inputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
  }

  private func didExit(with status: Int32) {
    stateLock.withLock {
      state.hasExited = true
    }
    exitWaiter.complete(with: status)
  }

  private func forceKillIfRunning() {
    let processID = stateLock.withLock { () -> pid_t? in
      guard !state.hasExited else { return nil }
      return state.processID
    }
    if let processID {
      _ = Darwin.kill(processID, SIGKILL)
    }
  }
}
