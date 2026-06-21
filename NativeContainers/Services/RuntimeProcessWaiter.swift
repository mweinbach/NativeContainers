import Darwin
import Foundation

protocol RuntimeManagedProcess: Sendable {
  func wait() async throws -> Int32
  func kill(_ signal: Int32) async throws
}

enum RuntimeProcessWaitError: LocalizedError, Equatable {
  case timedOut(seconds: Int)
  case waitFailed(String)
  case killFailed(String)
  case killNotConfirmed(seconds: Int)

  var errorDescription: String? {
    switch self {
    case .timedOut(let seconds):
      "The process did not exit within \(seconds) seconds and was killed."
    case .waitFailed(let message):
      "Waiting for the process failed: \(message)"
    case .killFailed(let message):
      "KILL failed: \(message)"
    case .killNotConfirmed(let seconds):
      "The process did not confirm exit within \(seconds) seconds after KILL."
    }
  }
}

enum RuntimeProcessWaiter {
  private static let killConfirmationSeconds = 2

  private enum ExitOutcome: Sendable {
    case exited(Int32)
    case failed(String)
    case timedOut
  }

  private enum KillOutcome: Sendable {
    case sent
    case failed(String)
    case timedOut
  }

  static func wait(
    for process: any RuntimeManagedProcess,
    timeoutSeconds: Int,
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    killConfirmationSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) async throws -> Int32 {
    let exitGate = RuntimeOneShotGate<ExitOutcome>()
    let processWait = Task {
      do {
        await exitGate.resolve(.exited(try await process.wait()))
      } catch {
        await exitGate.resolve(.failed(error.localizedDescription))
      }
    }
    defer { processWait.cancel() }

    return try await withTaskCancellationHandler {
      let firstOutcome = try await raceExit(
        gate: exitGate,
        timeout: .seconds(timeoutSeconds),
        sleep: sleep
      )
      switch firstOutcome {
      case .exited(let exitCode):
        return exitCode
      case .failed(let message):
        throw RuntimeProcessWaitError.waitFailed(message)
      case .timedOut:
        break
      }

      switch try await sendKill(
        to: process,
        timeout: .seconds(Self.killConfirmationSeconds),
        sleep: killConfirmationSleep
      )
      {
      case .sent:
        break
      case .failed(let message):
        throw RuntimeProcessWaitError.killFailed(message)
      case .timedOut:
        throw RuntimeProcessWaitError.killNotConfirmed(
          seconds: Self.killConfirmationSeconds
        )
      }

      let finalOutcome = try await raceExit(
        gate: exitGate,
        timeout: .seconds(Self.killConfirmationSeconds),
        sleep: killConfirmationSleep
      )
      switch finalOutcome {
      case .exited:
        throw RuntimeProcessWaitError.timedOut(seconds: timeoutSeconds)
      case .failed, .timedOut:
        throw RuntimeProcessWaitError.killNotConfirmed(
          seconds: Self.killConfirmationSeconds
        )
      }
    } onCancel: {
      processWait.cancel()
      Task.detached {
        try? await process.kill(SIGKILL)
      }
    }
  }

  private static func raceExit(
    gate exitGate: RuntimeOneShotGate<ExitOutcome>,
    timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws -> ExitOutcome {
    let raceGate = RuntimeOneShotGate<ExitOutcome>()
    let exitWait = Task {
      do {
        await raceGate.resolve(try await exitGate.value())
      } catch {
        // Cancellation means another race participant won.
      }
    }
    let timer = Task {
      do {
        try await sleep(timeout)
        await raceGate.resolve(.timedOut)
      } catch {
        // Cancellation means the process outcome won.
      }
    }
    defer {
      exitWait.cancel()
      timer.cancel()
    }
    return try await raceGate.value()
  }

  private static func sendKill(
    to process: any RuntimeManagedProcess,
    timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async throws -> KillOutcome {
    let raceGate = RuntimeOneShotGate<KillOutcome>()
    let kill = Task {
      do {
        try await process.kill(SIGKILL)
        await raceGate.resolve(.sent)
      } catch {
        await raceGate.resolve(.failed(error.localizedDescription))
      }
    }
    let timer = Task {
      do {
        try await sleep(timeout)
        await raceGate.resolve(.timedOut)
      } catch {
        // Cancellation means KILL completed.
      }
    }
    defer {
      kill.cancel()
      timer.cancel()
    }
    return try await raceGate.value()
  }
}

private actor RuntimeOneShotGate<Value: Sendable> {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Value, any Error>
  }

  private var resolvedValue: Value?
  private var waiters: [Waiter] = []

  func resolve(_ value: Value) {
    guard resolvedValue == nil else { return }
    resolvedValue = value
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for waiter in pending {
      waiter.continuation.resume(returning: value)
    }
  }

  func value() async throws -> Value {
    try Task.checkCancellation()
    if let resolvedValue {
      return resolvedValue
    }

    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let resolvedValue {
          continuation.resume(returning: resolvedValue)
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  private func cancel(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}
