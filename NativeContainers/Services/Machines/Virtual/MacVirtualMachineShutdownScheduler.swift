import Foundation

struct MacVirtualMachineShutdownPolicy: Equatable, Sendable {
  let gracefulStopTimeout: Duration
  let forceStopCapabilityTimeout: Duration
  let forceStopPollInterval: Duration

  init(
    gracefulStopTimeout: Duration,
    forceStopCapabilityTimeout: Duration = .seconds(5),
    forceStopPollInterval: Duration = .milliseconds(100)
  ) {
    self.gracefulStopTimeout = gracefulStopTimeout
    self.forceStopCapabilityTimeout = forceStopCapabilityTimeout
    self.forceStopPollInterval = forceStopPollInterval
  }

  static let standard = MacVirtualMachineShutdownPolicy(
    gracefulStopTimeout: .seconds(30),
    forceStopCapabilityTimeout: .seconds(5),
    forceStopPollInterval: .milliseconds(100)
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
