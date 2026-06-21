import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Host command execution")
struct HostProcessServiceTests {
  private let executableURL = URL(filePath: "/usr/bin/true")

  @Test
  func readsTheStableHostBootSessionUUID() throws {
    let identifier = try DarwinHostBootSessionIdentifier()
      .currentBootIdentifier()

    #expect(UUID(uuidString: identifier) != nil)
  }

  @Test
  func timeoutEscalatesFromTermToKillAndConfirmsExit() async {
    let session = HostCommandSessionDouble(exitSignal: SIGKILL)
    let executor = FoundationHostCommandExecutor(
      launcher: HostCommandLauncherDouble(session: session),
      pollInterval: .milliseconds(1),
      terminationGracePeriod: .milliseconds(2),
      killConfirmationTimeout: .milliseconds(10)
    )

    await #expect(throws: HostProcessError.timedOut) {
      try await executor.execute(
        executableURL: executableURL,
        arguments: [],
        environment: nil,
        timeout: .milliseconds(1)
      )
    }

    #expect(session.receivedSignals == [SIGTERM, SIGKILL])
    #expect(!session.isRunning)
  }

  @Test
  func cancellationStillCompletesTermKillEscalation() async throws {
    let session = HostCommandSessionDouble(exitSignal: SIGKILL)
    let launcher = HostCommandLauncherDouble(session: session)
    let executor = FoundationHostCommandExecutor(
      launcher: launcher,
      pollInterval: .milliseconds(1),
      terminationGracePeriod: .milliseconds(2),
      killConfirmationTimeout: .milliseconds(10)
    )
    let operation = Task {
      try await executor.execute(
        executableURL: executableURL,
        arguments: [],
        environment: nil,
        timeout: .seconds(30)
      )
    }
    while launcher.launchCount == 0 {
      await Task.yield()
    }

    operation.cancel()

    do {
      _ = try await operation.value
      Issue.record("Expected cancellation after the owned process was terminated.")
    } catch is CancellationError {
      // Expected only after TERM -> KILL has completed.
    } catch {
      Issue.record("Expected CancellationError, received \(error).")
    }

    #expect(session.receivedSignals == [SIGTERM, SIGKILL])
    #expect(!session.isRunning)
  }

  @Test
  func failedKillConfirmationIsSurfaced() async {
    let session = HostCommandSessionDouble(exitSignal: nil)
    let executor = FoundationHostCommandExecutor(
      launcher: HostCommandLauncherDouble(session: session),
      pollInterval: .milliseconds(1),
      terminationGracePeriod: .milliseconds(1),
      killConfirmationTimeout: .milliseconds(2)
    )

    await #expect(throws: HostProcessError.didNotExitAfterKill) {
      try await executor.execute(
        executableURL: executableURL,
        arguments: [],
        environment: nil,
        timeout: .milliseconds(1)
      )
    }

    #expect(session.receivedSignals == [SIGTERM, SIGKILL])
  }

  @Test
  func failedTermSignalStillFallsThroughToConfirmedKill() async {
    let session = HostCommandSessionDouble(
      exitSignal: SIGKILL,
      failedSignals: [SIGTERM]
    )
    let executor = FoundationHostCommandExecutor(
      launcher: HostCommandLauncherDouble(session: session),
      pollInterval: .milliseconds(1),
      terminationGracePeriod: .milliseconds(1),
      killConfirmationTimeout: .milliseconds(10)
    )

    await #expect(throws: HostProcessError.timedOut) {
      try await executor.execute(
        executableURL: executableURL,
        arguments: [],
        environment: nil,
        timeout: .milliseconds(1)
      )
    }

    #expect(session.receivedSignals == [SIGTERM, SIGKILL])
    #expect(!session.isRunning)
  }
}

private final class HostCommandLauncherDouble: HostProcessLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let session: HostCommandSessionDouble
  private var storedLaunchCount = 0

  var launchCount: Int {
    lock.withLock { storedLaunchCount }
  }

  init(session: HostCommandSessionDouble) {
    self.session = session
  }

  func launch(_ configuration: HostProcessConfiguration) throws -> any HostProcessSession {
    lock.withLock {
      storedLaunchCount += 1
    }
    return session
  }
}

private final class HostCommandSessionDouble: HostProcessSession, @unchecked Sendable {
  private struct State {
    var isRunning = true
    var terminationStatus: Int32?
    var signals: [Int32] = []
  }

  private let lock = NSLock()
  private let exitSignal: Int32?
  private let failedSignals: Set<Int32>
  private var state = State()

  let processID: Int32 = 9_999

  var isRunning: Bool {
    lock.withLock { state.isRunning }
  }

  var terminationStatus: Int32? {
    lock.withLock { state.terminationStatus }
  }

  var receivedSignals: [Int32] {
    lock.withLock { state.signals }
  }

  init(exitSignal: Int32?, failedSignals: Set<Int32> = []) {
    self.exitSignal = exitSignal
    self.failedSignals = failedSignals
  }

  func send(signal: Int32) throws {
    try lock.withLock {
      state.signals.append(signal)
      if failedSignals.contains(signal) {
        throw HostProcessError.signalFailed(signal: signal, code: EPERM)
      }
      if signal == exitSignal {
        state.isRunning = false
        state.terminationStatus = signal == SIGKILL ? SIGKILL : 0
      }
    }
  }

  func capturedOutput() -> HostProcessOutput {
    HostProcessOutput(
      standardOutput: "",
      standardError: "",
      wasTruncated: false
    )
  }
}
