import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container tool process waiter")
struct AppleContainerToolServiceTests {
  @Test
  func timeoutWinsWhenKillReleasesProcessWait() async {
    let process = KillReleasesWaitProcess()

    await #expect(throws: ContainerToolValidationError.commandTimedOut(5)) {
      try await AppleContainerToolProcessWaiter.wait(
        for: process,
        timeoutSeconds: 5,
        sleep: { _ in }
      )
    }

    #expect(await process.killSignals == [SIGKILL])
  }

  @Test
  func callerCancellationKillsWaitingProcess() async {
    for _ in 0..<25 {
      let process = KillReleasesWaitProcess()
      let operation = Task {
        try await AppleContainerToolProcessWaiter.wait(
          for: process,
          timeoutSeconds: 60
        )
      }
      while !(await process.hasStartedWaiting) {
        await Task.yield()
      }

      operation.cancel()

      await #expect(throws: CancellationError.self) {
        try await operation.value
      }
      while (await process.killSignals).isEmpty {
        await Task.yield()
      }
      #expect(await process.killSignals == [SIGKILL])
    }
  }
}

@Suite("Runtime process waiter")
struct RuntimeProcessWaiterTests {
  @Test
  func returnsCleanExitWithoutSendingKill() async throws {
    let process = ImmediateRuntimeProcess(exitCode: 0)

    let exitCode = try await RuntimeProcessWaiter.wait(
      for: process,
      timeoutSeconds: 5
    )

    #expect(exitCode == 0)
    #expect(await process.killSignals.isEmpty)
  }

  @Test
  func reportsKillFailureInsteadOfClaimingTimeoutRecovery() async {
    let process = RuntimeWaiterTestProcess(killBehavior: .fails)

    await #expect(throws: RuntimeProcessWaitError.killFailed("test KILL failure")) {
      try await RuntimeProcessWaiter.wait(
        for: process,
        timeoutSeconds: 5,
        sleep: { _ in },
        killConfirmationSleep: { _ in try await Task.sleep(for: .seconds(60)) }
      )
    }
  }

  @Test
  func boundsKillThatNeverReturns() async {
    let process = RuntimeWaiterTestProcess(killBehavior: .suspends)

    await #expect(throws: RuntimeProcessWaitError.killNotConfirmed(seconds: 2)) {
      try await RuntimeProcessWaiter.wait(
        for: process,
        timeoutSeconds: 5,
        sleep: { _ in },
        killConfirmationSleep: { _ in }
      )
    }
  }

  @Test
  func requiresExitConfirmationAfterSuccessfulKill() async {
    let process = RuntimeWaiterTestProcess(killBehavior: .returns)

    await #expect(throws: RuntimeProcessWaitError.killNotConfirmed(seconds: 2)) {
      try await RuntimeProcessWaiter.wait(
        for: process,
        timeoutSeconds: 5,
        sleep: { _ in },
        killConfirmationSleep: { _ in }
      )
    }
  }
}

private actor KillReleasesWaitProcess: ContainerCommandProcess {
  private var continuation: CheckedContinuation<Int32, any Error>?
  private var wasKilled = false
  private(set) var hasStartedWaiting = false
  private(set) var killSignals: [Int32] = []

  func wait() async throws -> Int32 {
    hasStartedWaiting = true
    if wasKilled {
      return 137
    }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func kill(_ signal: Int32) async throws {
    killSignals.append(signal)
    wasKilled = true
    continuation?.resume(returning: 137)
    continuation = nil
  }
}

private actor ImmediateRuntimeProcess: RuntimeManagedProcess {
  let exitCode: Int32
  private(set) var killSignals: [Int32] = []

  init(exitCode: Int32) {
    self.exitCode = exitCode
  }

  func wait() -> Int32 {
    exitCode
  }

  func kill(_ signal: Int32) {
    killSignals.append(signal)
  }
}

private enum RuntimeWaiterKillBehavior: Sendable {
  case fails
  case returns
  case suspends
}

private enum RuntimeWaiterTestError: LocalizedError {
  case killFailed

  var errorDescription: String? {
    "test KILL failure"
  }
}

private actor RuntimeWaiterTestProcess: RuntimeManagedProcess {
  private let killBehavior: RuntimeWaiterKillBehavior

  init(killBehavior: RuntimeWaiterKillBehavior) {
    self.killBehavior = killBehavior
  }

  func wait() async throws -> Int32 {
    try await Task.sleep(for: .seconds(60))
    return 0
  }

  func kill(_ signal: Int32) async throws {
    switch killBehavior {
    case .fails:
      throw RuntimeWaiterTestError.killFailed
    case .returns:
      return
    case .suspends:
      try await Task.sleep(for: .seconds(60))
    }
  }
}
