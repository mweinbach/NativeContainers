import Foundation

struct MacVirtualMachineShutdownPolicy: Equatable, Sendable {
  let gracefulStopTimeout: Duration

  static let standard = MacVirtualMachineShutdownPolicy(
    gracefulStopTimeout: .seconds(30)
  )
}

@MainActor
protocol MacVirtualMachineShutdownScheduling: Sendable {
  func schedule(
    after delay: Duration,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> MacVirtualMachineScheduledShutdown
}

final class MacVirtualMachineScheduledShutdown: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?

  init(cancellation: @escaping @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  func cancel() {
    let cancellation = lock.withLock {
      let cancellation = cancellation
      self.cancellation = nil
      return cancellation
    }
    cancellation?()
  }

  deinit {
    cancel()
  }
}

struct ContinuousClockMacVirtualMachineShutdownScheduler:
  MacVirtualMachineShutdownScheduling
{
  func schedule(
    after delay: Duration,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> MacVirtualMachineScheduledShutdown {
    let task = Task { @MainActor in
      do {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      await operation()
    }
    return MacVirtualMachineScheduledShutdown {
      task.cancel()
    }
  }
}
