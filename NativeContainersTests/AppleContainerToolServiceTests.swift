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
