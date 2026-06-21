import ContainerAPIClient
import Darwin
import Foundation

protocol ContainerTerminalProcess: Sendable {
  func start() async throws
  func wait() async throws -> Int32
  func kill(_ signal: Int32) async throws
  func resize(to size: ContainerTerminalSize) async throws
}

protocol ContainerTerminalProcessLaunching: Sendable {
  func makeProcess(
    containerID: String,
    request: ContainerTerminalRequest,
    standardInput: FileHandle,
    standardOutput: FileHandle
  ) async throws -> any ContainerTerminalProcess
}

struct AppleContainerTerminalProcessLauncher: ContainerTerminalProcessLaunching {
  private let containerClient: ContainerClient
  private let processClient: any AppleRuntimeProcessCreating

  init(
    containerClient: ContainerClient = ContainerClient(),
    processClient: any AppleRuntimeProcessCreating = AppleContainerProcessXPCClient()
  ) {
    self.containerClient = containerClient
    self.processClient = processClient
  }

  func makeProcess(
    containerID: String,
    request: ContainerTerminalRequest,
    standardInput: FileHandle,
    standardOutput: FileHandle
  ) async throws -> any ContainerTerminalProcess {
    let snapshot = try await containerClient.get(id: containerID)
    guard snapshot.status == .running else {
      throw ContainerTerminalError.containerNotRunning(containerID)
    }

    var configuration = snapshot.configuration.initProcess
    configuration.executable = request.executable
    configuration.arguments = request.arguments
    configuration.environment = try Parser.allEnv(
      imageEnvs: configuration.environment,
      envFiles: [],
      envs: request.environment.map(\.entry)
    )
    configuration.terminal = true
    if let workingDirectory = request.workingDirectory {
      configuration.workingDirectory = workingDirectory
    }

    return try await processClient.createRuntimeProcess(
      containerID: containerID,
      processID: UUID().uuidString.lowercased(),
      configuration: configuration,
      standardIO: [standardInput, standardOutput, nil]
    )
  }
}

final class PipeContainerTerminalTransport: @unchecked Sendable {
  private enum End: Hashable {
    case childInput
    case input
    case childOutput
    case output
  }

  private enum ReadAttempt {
    case retry
    case end
    case data(Data)
  }

  private enum WriteAttempt {
    case retry
    case wrote(Int)
  }

  private let inputPipe: Pipe
  private let outputPipe: Pipe
  private let inputQueue = DispatchQueue(
    label: "com.nativecontainers.terminal-input",
    qos: .userInitiated
  )
  private let inputAccessLock = NSLock()
  private let outputAccessLock = NSLock()
  private let lock = NSLock()
  private let inputSetupError: POSIXError?
  private var closedEnds: Set<End> = []

  init() {
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    self.inputPipe = inputPipe
    self.outputPipe = outputPipe

    let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    var setupError: POSIXError?
    if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
      setupError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    } else if fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0 {
      setupError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    inputSetupError = setupError
  }

  var childStandardInput: FileHandle { inputPipe.fileHandleForReading }
  var childStandardOutput: FileHandle { outputPipe.fileHandleForWriting }

  var allHandlesAreClosed: Bool {
    lock.withLock { closedEnds.count == 4 }
  }

  func setOutputNonBlocking() throws {
    try outputAccessLock.withLock {
      guard !lock.withLock({ closedEnds.contains(.output) }) else {
        throw ContainerTerminalError.sessionNotRunning
      }
      let descriptor = outputPipe.fileHandleForReading.fileDescriptor
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  func writeInput(_ data: Data) async throws {
    guard !data.isEmpty else { return }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      inputQueue.async { [self] in
        do {
          try writeInputSynchronously(data)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func readOutput(maximumBytes: Int) throws -> Data? {
    while true {
      if Task.isCancelled { return nil }
      let attempt = try outputAccessLock.withLock { () throws -> ReadAttempt in
        guard !lock.withLock({ closedEnds.contains(.output) }) else { return .end }
        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        var event = pollfd(
          fd: descriptor,
          events: Int16(POLLIN | POLLHUP),
          revents: 0
        )
        let result = Darwin.poll(&event, 1, 250)
        if result == 0 { return .retry }
        if result < 0, errno == EINTR { return .retry }
        if result < 0 {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data(count: maximumBytes)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
          Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        if bytesRead > 0 {
          data.removeSubrange(bytesRead..<data.count)
          return .data(data)
        }
        if bytesRead == 0 { return .end }
        if errno == EINTR || errno == EAGAIN { return .retry }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }

      switch attempt {
      case .retry:
        continue
      case .end:
        return nil
      case .data(let data):
        return data
      }
    }
  }

  func closeChildEnds() {
    close(.childInput, handle: inputPipe.fileHandleForReading)
    close(.childOutput, handle: outputPipe.fileHandleForWriting)
  }

  func closeInput() {
    guard markClosed(.input) else { return }
    inputAccessLock.withLock {
      try? inputPipe.fileHandleForWriting.close()
    }
  }

  func closeOutput() {
    guard markClosed(.output) else { return }
    outputAccessLock.withLock {
      try? outputPipe.fileHandleForReading.close()
    }
  }

  func closeAll() {
    closeChildEnds()
    closeInput()
    closeOutput()
  }

  private func close(_ end: End, handle: FileHandle) {
    if markClosed(end) {
      try? handle.close()
    }
  }

  private func markClosed(_ end: End) -> Bool {
    lock.withLock { closedEnds.insert(end).inserted }
  }

  private func writeInputSynchronously(_ data: Data) throws {
    if let inputSetupError { throw inputSetupError }

    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let attempt = try inputAccessLock.withLock { () throws -> WriteAttempt in
          guard !lock.withLock({ closedEnds.contains(.input) }) else {
            throw ContainerTerminalError.sessionNotRunning
          }

          let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
          var event = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT | POLLHUP),
            revents: 0
          )
          let result = Darwin.poll(&event, 1, 50)
          if result == 0 { return .retry }
          if result < 0, errno == EINTR { return .retry }
          if result < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }

          let bytesWritten = writeWithoutSIGPIPE(
            descriptor: descriptor,
            buffer: buffer.baseAddress?.advanced(by: offset),
            count: buffer.count - offset
          )
          if bytesWritten > 0 { return .wrote(bytesWritten) }
          if bytesWritten < 0, errno == EINTR || errno == EAGAIN { return .retry }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        switch attempt {
        case .retry:
          continue
        case .wrote(let count):
          offset += count
        }
      }
    }
  }

  private func writeWithoutSIGPIPE(
    descriptor: Int32,
    buffer: UnsafeRawPointer?,
    count: Int
  ) -> Int {
    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    sigaddset(&blockedSignals, SIGPIPE)
    var previousSignals = sigset_t()
    let maskResult = pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals)

    let result = Darwin.write(descriptor, buffer, count)
    let writeError = errno

    if maskResult == 0 {
      if sigismember(&previousSignals, SIGPIPE) == 0 {
        var pendingSignals = sigset_t()
        sigpending(&pendingSignals)
        if sigismember(&pendingSignals, SIGPIPE) == 1 {
          var signal = Int32.zero
          _ = sigwait(&blockedSignals, &signal)
        }
      }
      _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil)
    }
    errno = writeError
    return result
  }

  deinit {
    closeAll()
  }
}

actor AppleContainerTerminalSession: ContainerTerminalSession {
  nonisolated let output: AsyncStream<Data>

  private static let outputChunkBytes = 64 * 1_024
  private static let outputRetryDelay = Duration.milliseconds(1)
  private static let outputDrainGracePeriod = Duration.seconds(3)
  private static let closeGracePeriod = Duration.milliseconds(250)
  private static let killConfirmationPeriod = Duration.seconds(1)
  private static let closePollInterval = Duration.milliseconds(10)

  private let processLifetime: ContainerTerminalProcessLifetime
  private let transport: PipeContainerTerminalTransport
  private let maximumRetainedOutputBytes: Int
  private let streamCancellationRelay = TerminalStreamCancellationRelay()
  private var outputContinuation: AsyncStream<Data>.Continuation?
  private var outputReaderTask: Task<Void, Never>?
  private var waitTask: Task<Int32, any Error>?
  private var processMonitorTask: Task<Void, Never>?
  private var lifecycle = ContainerTerminalLifecycle.starting
  private var retainedOutput = Data()
  private var outputWasTruncated = false

  init(
    process: any ContainerTerminalProcess,
    transport: PipeContainerTerminalTransport,
    maximumRetainedOutputBytes: Int
  ) {
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    let continuation = pair.continuation
    let relay = streamCancellationRelay
    continuation.onTermination = { termination in
      if case .cancelled = termination {
        relay.cancel()
      }
    }

    output = pair.stream
    outputContinuation = continuation
    processLifetime = ContainerTerminalProcessLifetime(process: process)
    self.transport = transport
    self.maximumRetainedOutputBytes = maximumRetainedOutputBytes
  }

  func start(initialSize: ContainerTerminalSize) async throws {
    guard lifecycle == .starting else {
      throw ContainerTerminalError.sessionNotRunning
    }
    streamCancellationRelay.install { [weak self] in
      Task {
        await self?.close()
      }
    }
    guard lifecycle == .starting else {
      throw CancellationError()
    }
    startOutputReader()

    do {
      try await withTaskCancellationHandler {
        try await processLifetime.start()
      } onCancel: {
        Task {
          try? await self.processLifetime.killIfNeeded()
        }
      }
      try Task.checkCancellation()
      // Match Apple's ProcessIO lifecycle: the XPC service owns duplicated descriptors after
      // start succeeds, so the app closes its child-side copies at this point.
      transport.closeChildEnds()
      lifecycle = .running

      let waitTask = Task.detached { [processLifetime] in
        try await processLifetime.wait()
      }
      self.waitTask = waitTask
      processMonitorTask = Task { [weak self] in
        do {
          let exitCode = try await waitTask.value
          await self?.processExited(exitCode)
        } catch {
          await self?.processWaitFailed(error)
        }
      }

      // A short-lived command can exit between start and resize. Apple ProcessIO treats that
      // race as nonfatal, so opening the session must not fail solely because resize lost it.
      try? await processLifetime.resize(to: initialSize)
    } catch {
      await fail(error)
      throw error
    }
  }

  func sendInput(_ data: Data) async throws {
    guard lifecycle == .running else {
      throw ContainerTerminalError.sessionNotRunning
    }
    guard !data.isEmpty else { return }
    try await transport.writeInput(data)
  }

  func resize(to size: ContainerTerminalSize) async throws {
    guard lifecycle == .running else {
      throw ContainerTerminalError.sessionNotRunning
    }
    try await processLifetime.resize(to: size)
  }

  func sendSignal(_ signal: ContainerTerminalSignal) async throws {
    guard lifecycle == .running else {
      throw ContainerTerminalError.sessionNotRunning
    }
    try await processLifetime.kill(signal.rawValue)
  }

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: lifecycle,
      retainedOutput: retainedOutput,
      outputWasTruncated: outputWasTruncated
    )
  }

  func wait() async throws -> Int32 {
    guard let waitTask else {
      throw ContainerTerminalError.sessionNotRunning
    }
    let outputReaderTask = self.outputReaderTask
    let transport = self.transport

    let exitCode = try await withTaskCancellationHandler {
      let exitCode = try await waitTask.value
      processExited(exitCode)
      if let outputReaderTask {
        let drainDeadline = Task {
          do {
            try await Task.sleep(for: Self.outputDrainGracePeriod)
            outputReaderTask.cancel()
            transport.closeOutput()
          } catch {}
        }
        await outputReaderTask.value
        drainDeadline.cancel()
      }
      try Task.checkCancellation()
      return exitCode
    } onCancel: {
      Task {
        await self.close()
      }
    }

    if case .failed(let message) = lifecycle {
      throw ContainerTerminalError.sessionFailed(message)
    }
    return exitCode
  }

  func close() async {
    guard lifecycle != .closed else { return }
    let shouldKill: Bool
    switch lifecycle {
    case .exited:
      shouldKill = false
    case .starting, .running, .failed:
      shouldKill = !processLifetime.isFinished
    case .closed:
      return
    }

    // Prevent descriptor shutdown from being misreported as a read failure while cleanup runs.
    lifecycle = .closed
    var shutdownFailure: String?
    if shouldKill {
      transport.closeInput()
      try? await processLifetime.kill(SIGHUP)
      if !(await waitForProcessExit(timeout: Self.closeGracePeriod)) {
        do {
          try await processLifetime.killIfNeeded()
        } catch {
          shutdownFailure = error.localizedDescription
        }
        if !(await waitForProcessExit(timeout: Self.killConfirmationPeriod)) {
          let detail = shutdownFailure.map { ": \($0)" } ?? ""
          shutdownFailure = "The terminal process did not confirm exit after SIGKILL\(detail)"
        }
      }
    }
    outputReaderTask?.cancel()
    transport.closeAll()
    finishOutputStream()
    if let shutdownFailure {
      lifecycle = .failed(shutdownFailure)
    } else {
      lifecycle = .closed
    }
  }

  private func startOutputReader() {
    let transport = self.transport
    outputReaderTask = Task.detached(priority: .utility) { [weak self] in
      do {
        while !Task.isCancelled,
          let data = try transport.readOutput(maximumBytes: Self.outputChunkBytes),
          !data.isEmpty
        {
          await self?.receivedOutput(data)
        }
        await self?.outputReachedEnd()
      } catch {
        await self?.outputReadFailed(error)
      }
    }
  }

  private func receivedOutput(_ data: Data) async {
    guard lifecycle != .closed else { return }

    if data.count >= maximumRetainedOutputBytes {
      retainedOutput = Data(data.suffix(maximumRetainedOutputBytes))
      outputWasTruncated = true
    } else {
      let excess = retainedOutput.count + data.count - maximumRetainedOutputBytes
      if excess > 0 {
        retainedOutput.removeFirst(excess)
        outputWasTruncated = true
      }
      retainedOutput.append(data)
    }
    guard let outputContinuation else { return }
    while !Task.isCancelled {
      switch outputContinuation.yield(data) {
      case .enqueued, .terminated:
        return
      case .dropped:
        do {
          try await Task.sleep(for: Self.outputRetryDelay)
        } catch {
          return
        }
      @unknown default:
        return
      }
    }
  }

  private func outputReachedEnd() {
    transport.closeOutput()
    finishOutputStream()
  }

  private func outputReadFailed(_ error: any Error) async {
    switch lifecycle {
    case .closed, .exited:
      finishOutputStream()
    case .starting, .running, .failed:
      await fail(error)
    }
  }

  private func processExited(_ exitCode: Int32) {
    processLifetime.markFinished()
    transport.closeInput()
    switch lifecycle {
    case .starting, .running:
      lifecycle = .exited(exitCode)
    case .closed, .exited, .failed:
      break
    }
  }

  private func processWaitFailed(_ error: any Error) async {
    guard lifecycle != .closed else { return }
    await fail(error)
  }

  private func fail(_ error: any Error) async {
    guard lifecycle != .closed else { return }
    lifecycle = .failed(error.localizedDescription)
    outputReaderTask?.cancel()
    transport.closeAll()
    finishOutputStream()
    try? await processLifetime.killIfNeeded()
  }

  private func waitForProcessExit(timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !processLifetime.isFinished, clock.now < deadline {
      do {
        try await Task.sleep(for: Self.closePollInterval)
      } catch {
        break
      }
    }
    return processLifetime.isFinished
  }

  private func finishOutputStream() {
    outputContinuation?.finish()
    outputContinuation = nil
    streamCancellationRelay.clear()
  }
}

private final class ContainerTerminalProcessLifetime: @unchecked Sendable {
  private let process: any ContainerTerminalProcess
  private let lock = NSLock()
  private var processFinished = false

  init(process: any ContainerTerminalProcess) {
    self.process = process
  }

  func start() async throws {
    try await process.start()
  }

  func wait() async throws -> Int32 {
    try await process.wait()
  }

  func kill(_ signal: Int32) async throws {
    try await process.kill(signal)
  }

  func resize(to size: ContainerTerminalSize) async throws {
    try await process.resize(to: size)
  }

  func markFinished() {
    lock.withLock {
      processFinished = true
    }
  }

  var isFinished: Bool {
    lock.withLock { processFinished }
  }

  func killIfNeeded() async throws {
    guard !isFinished else { return }
    try await process.kill(SIGKILL)
  }

  deinit {
    guard !isFinished else { return }
    let process = self.process
    Task.detached {
      try? await process.kill(SIGKILL)
    }
  }
}

private final class TerminalStreamCancellationRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  private var cancellationReceived = false

  func install(_ handler: @escaping @Sendable () -> Void) {
    let shouldRun = lock.withLock {
      guard !cancellationReceived else { return true }
      self.handler = handler
      return false
    }
    if shouldRun {
      handler()
    }
  }

  func cancel() {
    let handler = lock.withLock {
      cancellationReceived = true
      defer { self.handler = nil }
      return self.handler
    }
    handler?()
  }

  func clear() {
    lock.withLock {
      handler = nil
    }
  }
}
