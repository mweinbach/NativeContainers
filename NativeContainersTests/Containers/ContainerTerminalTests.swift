import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct ContainerTerminalTests {
  @Test
  func requestValidatesAndNormalizesTerminalInputs() throws {
    let variable = try ContainerEnvironmentVariable(key: " MODE ", value: "test")
    let size = try ContainerTerminalSize(columns: 132, rows: 43)
    let request = try ContainerTerminalRequest(
      executable: "  /bin/zsh  ",
      arguments: ["-l"],
      environment: [variable],
      workingDirectory: "  /workspace  ",
      initialSize: size,
      maximumRetainedOutputBytes: 4_096
    )

    #expect(request.executable == "/bin/zsh")
    #expect(request.environment == [variable])
    #expect(request.workingDirectory == "/workspace")
    #expect(request.initialSize == size)
    #expect(request.maximumRetainedOutputBytes == 4_096)

    #expect(throws: ContainerTerminalError.missingExecutable) {
      try ContainerTerminalRequest(executable: "  ")
    }
    #expect(throws: ContainerTerminalError.invalidWorkingDirectory("relative")) {
      try ContainerTerminalRequest(workingDirectory: "relative")
    }
    #expect(throws: ContainerTerminalError.duplicateEnvironmentKey) {
      try ContainerTerminalRequest(environment: [variable, variable])
    }
    #expect(throws: ContainerTerminalError.invalidSize(columns: 0, rows: 24)) {
      try ContainerTerminalSize(columns: 0, rows: 24)
    }
    #expect(throws: ContainerTerminalError.invalidRetentionLimit) {
      try ContainerTerminalRequest(maximumRetainedOutputBytes: 0)
    }
  }

  @Test
  func sessionStreamsIOAndOrchestratesProcessLifecycle() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer {
      try? remoteInput.close()
      try? remoteOutput.close()
    }

    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 8
    )
    try await session.start(initialSize: .standard)

    let outputTask = Task {
      var received = Data()
      for await data in session.output {
        received.append(data)
      }
      return received
    }
    let inputTask = Task.detached {
      try remoteInput.read(upToCount: 5) ?? Data()
    }

    try await session.sendInput(Data("hello".utf8))
    #expect(try await inputTask.value == Data("hello".utf8))

    try remoteOutput.write(contentsOf: Data("0123456789".utf8))
    try await waitForRetainedTerminalOutput(session, expected: "23456789")
    let resized = try ContainerTerminalSize(columns: 90, rows: 30)
    try await session.resize(to: resized)
    try await session.sendSignal(.interrupt)

    await process.complete(exitCode: 0)
    try remoteOutput.close()
    let exitCode = try await session.wait()
    let receivedOutput = await outputTask.value
    let snapshot = await session.snapshot()

    #expect(exitCode == 0)
    #expect(receivedOutput == Data("0123456789".utf8))
    #expect(snapshot.lifecycle == .exited(0))
    #expect(snapshot.retainedText == "23456789")
    #expect(snapshot.outputWasTruncated)
    #expect(await process.startCount == 1)
    #expect(await process.sizes == [.standard, resized])
    #expect(await process.signals == [SIGINT])
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func explicitCloseAllowsGracefulHangupAndClosesDescriptors() async throws {
    let process = MockTerminalProcess(exitsOnHangup: true)
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer {
      try? remoteInput.close()
      try? remoteOutput.close()
    }

    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)

    await session.close()

    #expect(await session.snapshot().lifecycle == .closed)
    #expect(await process.signals == [SIGHUP])
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func explicitCloseEscalatesToKillAfterGracePeriod() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer {
      try? remoteInput.close()
      try? remoteOutput.close()
    }

    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)

    await session.close()

    #expect(await session.snapshot().lifecycle == .closed)
    #expect(await process.signals == [SIGHUP, SIGKILL])
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func brokenInputReaderReturnsEPIPEWithoutTerminatingHost() async throws {
    let process = MockTerminalProcess(exitsOnHangup: true)
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer { try? remoteOutput.close() }
    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)
    try remoteInput.close()

    do {
      try await session.sendInput(Data("unread".utf8))
      Issue.record("Writing to a closed terminal input unexpectedly succeeded.")
    } catch let error as POSIXError {
      #expect(error.code == .EPIPE)
    } catch {
      Issue.record("Expected EPIPE from a closed terminal input, got \(error).")
    }

    await session.close()
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func closingSessionCancelsBackpressuredInput() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer {
      try? remoteInput.close()
      try? remoteOutput.close()
    }
    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)
    let writer = Task {
      try await session.sendInput(Data(repeating: 0x61, count: 2 * 1_024 * 1_024))
    }
    try await Task.sleep(for: .milliseconds(100))

    let clock = ContinuousClock()
    let startedAt = clock.now
    await session.close()
    let closeDuration = startedAt.duration(to: clock.now)
    do {
      try await writer.value
      Issue.record("A backpressured input write unexpectedly completed during close.")
    } catch {
      // Closing the input side must unblock the ordered writer.
    }

    #expect(closeDuration < .seconds(2))
    #expect(await process.signals == [SIGHUP, SIGKILL])
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func failedKillLeavesSessionFailedForRetry() async throws {
    let process = MockTerminalProcess(failedSignals: [SIGKILL])
    let transport = PipeContainerTerminalTransport()
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer { try? remoteOutput.close() }
    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)

    await session.close()

    guard case .failed(let message) = await session.snapshot().lifecycle else {
      Issue.record("An unconfirmed SIGKILL should leave the session failed.")
      return
    }
    #expect(message.contains("SIGKILL"))
    #expect(await process.signals == [SIGHUP, SIGKILL])
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func concurrentOutputAndCloseSerializeDescriptorLifetime() async throws {
    for _ in 0..<20 {
      let process = MockTerminalProcess(exitsOnHangup: true)
      let transport = PipeContainerTerminalTransport()
      let remoteOutput = try duplicate(transport.childStandardOutput)
      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: 1_024
      )
      try await session.start(initialSize: .standard)

      let closer = Task { await session.close() }
      try? remoteOutput.write(contentsOf: Data("racing-output".utf8))
      try? remoteOutput.close()
      await closer.value

      #expect(transport.allHandlesAreClosed)
    }
  }

  @Test
  func initialResizeFailureDoesNotFailStartedSession() async throws {
    let process = MockTerminalProcess(exitsOnHangup: true, failsResize: true)
    let transport = PipeContainerTerminalTransport()
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer { try? remoteOutput.close() }
    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )

    try await session.start(initialSize: .standard)

    #expect(await session.snapshot().lifecycle == .running)
    #expect(await process.startCount == 1)
    #expect(await process.sizes == [.standard])
    await session.close()
  }

  @Test
  func cancellingWaitKillsProcessAndSurfacesCancellation() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    let remoteInput = try duplicate(transport.childStandardInput)
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer {
      try? remoteInput.close()
      try? remoteOutput.close()
    }

    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)

    let waiter = Task {
      try await session.wait()
    }
    while await process.waitCount == 0 {
      await Task.yield()
    }
    waiter.cancel()

    do {
      _ = try await waiter.value
      Issue.record("A cancelled terminal wait unexpectedly succeeded.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("A cancelled terminal wait failed with \(error) instead of CancellationError.")
    }

    #expect(await process.signals.contains(SIGKILL))
    #expect(await session.snapshot().lifecycle == .closed)
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func streamBackpressurePreservesEveryByteForSlowConsumer() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer { try? remoteOutput.close() }
    let payload = Data(repeating: 0x61, count: 512 * 1_024)

    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024 * 1_024
    )
    try await session.start(initialSize: .standard)

    let consumer = Task {
      var received = Data()
      for await chunk in session.output {
        received.append(chunk)
        try? await Task.sleep(for: .milliseconds(2))
      }
      return received
    }
    let writer = Task.detached {
      try remoteOutput.write(contentsOf: payload)
      try remoteOutput.close()
    }
    try await writer.value
    await process.complete(exitCode: 0)
    _ = try await session.wait()
    let received = await consumer.value
    let snapshot = await session.snapshot()

    #expect(received == payload)
    #expect(snapshot.retainedOutput == payload)
    #expect(!snapshot.outputWasTruncated)
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func nonblockingXPCPipeWaitsForLateOutputInsteadOfTreatingItAsEOF() async throws {
    let process = MockTerminalProcess()
    let transport = PipeContainerTerminalTransport()
    try transport.setOutputNonBlocking()
    let remoteOutput = try duplicate(transport.childStandardOutput)
    defer { try? remoteOutput.close() }
    let session = AppleContainerTerminalSession(
      process: process,
      transport: transport,
      maximumRetainedOutputBytes: 1_024
    )
    try await session.start(initialSize: .standard)

    let consumer = Task {
      var received = Data()
      for await chunk in session.output {
        received.append(chunk)
      }
      return received
    }
    try await Task.sleep(for: .milliseconds(50))
    try remoteOutput.write(contentsOf: Data("late-output".utf8))
    try remoteOutput.close()
    await process.complete(exitCode: 0)

    _ = try await session.wait()
    #expect(await consumer.value == Data("late-output".utf8))
    #expect(transport.allHandlesAreClosed)
  }

  @Test
  func serviceUsesInjectedLauncherAndStartsReturnedSession() async throws {
    let process = MockTerminalProcess()
    let launcher = MockTerminalProcessLauncher(process: process)
    let service = AppleContainerService(terminalProcessLauncher: launcher)
    let request = try ContainerTerminalRequest(
      executable: "/bin/bash",
      arguments: ["-l"],
      initialSize: try ContainerTerminalSize(columns: 100, rows: 35)
    )

    let session = try await service.openTerminal(in: "  web  ", request: request)

    #expect(await launcher.containerIDs == ["web"])
    #expect(await launcher.requests == [request])
    #expect(await process.startCount == 1)
    #expect(await process.sizes == [request.initialSize])

    await session.close()
  }
}

private func waitForRetainedTerminalOutput(
  _ session: any ContainerTerminalSession,
  expected: String
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(1))
  while clock.now < deadline {
    if await session.snapshot().retainedText.contains(expected) { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record(
    "Terminal output was not published while its writer remained open: \(String(reflecting: await session.snapshot().retainedText))."
  )
}

private func duplicate(_ handle: FileHandle) throws -> FileHandle {
  let descriptor = Darwin.dup(handle.fileDescriptor)
  try #require(descriptor >= 0)
  return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private actor MockTerminalProcess: ContainerTerminalProcess {
  nonisolated let exitCodes: AsyncStream<Int32>

  private let exitContinuation: AsyncStream<Int32>.Continuation
  private let exitsOnHangup: Bool
  private let failsResize: Bool
  private let failedSignals: Set<Int32>
  private var exitDelivered = false
  private(set) var startCount = 0
  private(set) var waitCount = 0
  private(set) var signals: [Int32] = []
  private(set) var sizes: [ContainerTerminalSize] = []

  init(
    exitsOnHangup: Bool = false,
    failsResize: Bool = false,
    failedSignals: Set<Int32> = []
  ) {
    let pair = AsyncStream.makeStream(
      of: Int32.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    exitCodes = pair.stream
    exitContinuation = pair.continuation
    self.exitsOnHangup = exitsOnHangup
    self.failsResize = failsResize
    self.failedSignals = failedSignals
  }

  func start() async throws {
    startCount += 1
  }

  func wait() async throws -> Int32 {
    waitCount += 1
    for await exitCode in exitCodes {
      return exitCode
    }
    throw CancellationError()
  }

  func kill(_ signal: Int32) async throws {
    signals.append(signal)
    if failedSignals.contains(signal) {
      throw MockTerminalProcessError.signalFailed(signal)
    }
    if signal == SIGKILL || (signal == SIGHUP && exitsOnHangup) {
      deliver(exitCode: 128 + signal)
    }
  }

  func resize(to size: ContainerTerminalSize) async throws {
    sizes.append(size)
    if failsResize {
      throw MockTerminalProcessError.resizeFailed
    }
  }

  func complete(exitCode: Int32) {
    deliver(exitCode: exitCode)
  }

  private func deliver(exitCode: Int32) {
    guard !exitDelivered else { return }
    exitDelivered = true
    exitContinuation.yield(exitCode)
    exitContinuation.finish()
  }
}

private enum MockTerminalProcessError: Error {
  case resizeFailed
  case signalFailed(Int32)
}

private actor MockTerminalProcessLauncher: ContainerTerminalProcessLaunching {
  private let process: any ContainerTerminalProcess
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerTerminalRequest] = []

  init(process: any ContainerTerminalProcess) {
    self.process = process
  }

  func makeProcess(
    containerID: String,
    request: ContainerTerminalRequest,
    standardInput: FileHandle,
    standardOutput: FileHandle
  ) async throws -> any ContainerTerminalProcess {
    containerIDs.append(containerID)
    requests.append(request)
    return process
  }
}
