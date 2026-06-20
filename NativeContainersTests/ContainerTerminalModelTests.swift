import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct ContainerTerminalModelTests {
  @Test
  func connectsForwardsRawOutputAndPublishesExit() async throws {
    let session = TestContainerTerminalSession(
      outputChunks: [Data([0x1B, 0x5B, 0x32, 0x4A]), Data("ready\r\n".utf8)],
      exitCode: 7
    )
    let recorder = TerminalOpenRecorder(session: session)
    let model = ContainerTerminalModel(containerID: "dev") { id, request in
      await recorder.open(id: id, request: request)
    }
    let outputTask = Task { () -> Data in
      var collected = Data()
      for await chunk in model.output {
        collected.append(chunk)
        if collected.count >= 11 { break }
      }
      return collected
    }

    await model.connect()
    let output = await outputTask.value
    try await waitUntilTerminal { model.lifecycle == .exited(7) }

    #expect(output == Data([0x1B, 0x5B, 0x32, 0x4A]) + Data("ready\r\n".utf8))
    #expect(model.errorMessage == nil)
    #expect(await recorder.containerIDs == ["dev"])
    #expect(await recorder.requests.first?.executable == "/bin/sh")
  }

  @Test
  func forwardsInputResizeAndSignalsToSession() async throws {
    let session = TestContainerTerminalSession(outputChunks: [], exitCode: 0, staysOpen: true)
    let model = ContainerTerminalModel(containerID: "dev") { _, _ in session }

    await model.connect()
    await model.sendInput(Data("echo hello\n".utf8))
    await model.sendInput(Data([0x03]))
    await model.sendInput(Data([0x04]))
    await model.resize(columns: 132, rows: 48)
    await model.sendSignal(.interrupt)

    #expect(
      await session.inputs == [
        Data("echo hello\n".utf8),
        Data([0x03]),
        Data([0x04]),
      ]
    )
    #expect(
      await session.sizes == [
        .standard,
        try ContainerTerminalSize(columns: 132, rows: 48),
      ]
    )
    #expect(await session.signals == [.interrupt])

    await model.close()
    #expect(model.lifecycle == .closed)
    #expect(await session.closeCount == 1)
  }

  @Test
  func usesLatestRenderedSizeForInitialSession() async throws {
    let session = TestContainerTerminalSession(outputChunks: [], exitCode: 0, staysOpen: true)
    let recorder = TerminalOpenRecorder(session: session)
    let model = ContainerTerminalModel(containerID: "dev") { id, request in
      await recorder.open(id: id, request: request)
    }

    await model.resize(columns: 148, rows: 52)
    await model.connect()

    #expect(
      await recorder.requests.first?.initialSize
        == (try ContainerTerminalSize(columns: 148, rows: 52))
    )
    #expect(await session.sizes == [try ContainerTerminalSize(columns: 148, rows: 52)])
    await model.close()
  }

  @Test
  func coalescesRapidRenderedSizeChanges() async throws {
    let session = TestContainerTerminalSession(outputChunks: [], exitCode: 0, staysOpen: true)
    let model = ContainerTerminalModel(containerID: "dev") { _, _ in session }
    await model.connect()

    model.scheduleResize(columns: 100, rows: 30)
    model.scheduleResize(columns: 110, rows: 35)
    model.scheduleResize(columns: 120, rows: 40)
    model.scheduleResize(columns: 132, rows: 44)
    try await waitUntilTerminalAsync { await session.sizes.count == 2 }
    #expect(
      await session.sizes == [.standard, try ContainerTerminalSize(columns: 132, rows: 44)]
    )
    await model.close()
  }

  @Test
  func queuedInputPreservesCallbackOrder() async throws {
    let session = TestContainerTerminalSession(outputChunks: [], exitCode: 0, staysOpen: true)
    let model = ContainerTerminalModel(containerID: "dev") { _, _ in session }
    await model.connect()

    model.enqueueInput(Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]))
    model.enqueueInput(Data("pasted text".utf8))
    model.enqueueInput(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
    try await waitUntilTerminalAsync { await session.inputs.count == 3 }

    #expect(
      await session.inputs == [
        Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]),
        Data("pasted text".utf8),
        Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]),
      ]
    )
    await model.close()
  }

  @Test
  func newShellPerformsFullEmulatorReset() async throws {
    let first = TestContainerTerminalSession(
      outputChunks: [Data("\u{1B}[?1049hfirst".utf8)],
      exitCode: 0
    )
    let second = TestContainerTerminalSession(outputChunks: [], exitCode: 0)
    let recorder = TerminalSequenceOpenRecorder(sessions: [first, second])
    let model = ContainerTerminalModel(containerID: "dev") { id, request in
      await recorder.open(id: id, request: request)
    }
    let reset = Data([0x1B, 0x63])
    let outputTask = Task { () -> Data in
      var collected = Data()
      for await chunk in model.output {
        collected.append(chunk)
        if collected.range(of: reset) != nil { return collected }
      }
      return collected
    }

    await model.connect()
    try await waitUntilTerminal { model.lifecycle == .exited(0) }
    await model.connect()
    let output = await outputTask.value

    #expect(output.range(of: reset) != nil)
    #expect(String(decoding: output, as: UTF8.self).contains("— new shell —"))
  }

  @Test
  func failedShutdownKeepsSessionVisibleForRetry() async {
    let session = TestContainerTerminalSession(
      outputChunks: [],
      exitCode: 0,
      staysOpen: true,
      closeFailure: "SIGKILL was not confirmed"
    )
    let model = ContainerTerminalModel(containerID: "dev") { _, _ in session }
    await model.connect()

    let closed = await model.close()

    #expect(!closed)
    #expect(model.hasActiveSession)
    #expect(model.lifecycle == .failed("SIGKILL was not confirmed"))
    #expect(model.errorMessage == "SIGKILL was not confirmed")
  }
}

private actor TerminalOpenRecorder {
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerTerminalRequest] = []
  let session: any ContainerTerminalSession

  init(session: any ContainerTerminalSession) {
    self.session = session
  }

  func open(
    id: String,
    request: ContainerTerminalRequest
  ) -> any ContainerTerminalSession {
    containerIDs.append(id)
    requests.append(request)
    return session
  }
}

private actor TerminalSequenceOpenRecorder {
  private var sessions: [any ContainerTerminalSession]

  init(sessions: [any ContainerTerminalSession]) {
    self.sessions = sessions
  }

  func open(
    id: String,
    request: ContainerTerminalRequest
  ) -> any ContainerTerminalSession {
    sessions.removeFirst()
  }
}

private actor TestContainerTerminalSession: ContainerTerminalSession {
  nonisolated let output: AsyncStream<Data>

  private let exitCode: Int32
  private let closeFailure: String?
  private var lifecycle: ContainerTerminalLifecycle = .running
  private(set) var inputs: [Data] = []
  private(set) var sizes: [ContainerTerminalSize] = []
  private(set) var signals: [ContainerTerminalSignal] = []
  private(set) var closeCount = 0

  init(
    outputChunks: [Data],
    exitCode: Int32,
    staysOpen: Bool = false,
    closeFailure: String? = nil
  ) {
    self.exitCode = exitCode
    self.closeFailure = closeFailure
    output = AsyncStream { continuation in
      for chunk in outputChunks {
        continuation.yield(chunk)
      }
      if !staysOpen {
        continuation.finish()
      }
    }
  }

  func sendInput(_ data: Data) {
    inputs.append(data)
  }

  func resize(to size: ContainerTerminalSize) {
    sizes.append(size)
  }

  func sendSignal(_ signal: ContainerTerminalSignal) {
    signals.append(signal)
  }

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: lifecycle,
      retainedOutput: Data(),
      outputWasTruncated: false
    )
  }

  func wait() -> Int32 {
    lifecycle = .exited(exitCode)
    return exitCode
  }

  func close() {
    closeCount += 1
    if let closeFailure {
      lifecycle = .failed(closeFailure)
    } else {
      lifecycle = .closed
    }
  }
}

@MainActor
private func waitUntilTerminal(
  timeout: Duration = .seconds(2),
  condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw TerminalTestWaitError.timedOut
}

private func waitUntilTerminalAsync(
  timeout: Duration = .seconds(2),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw TerminalTestWaitError.timedOut
}

private enum TerminalTestWaitError: Error {
  case timedOut
}
