import Foundation

struct VirtualMachineShutdownPolicy: Equatable, Sendable {
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

  static let standard = VirtualMachineShutdownPolicy(
    gracefulStopTimeout: .seconds(30),
    forceStopCapabilityTimeout: .seconds(5),
    forceStopPollInterval: .milliseconds(100)
  )
}

@MainActor
protocol VirtualMachineShutdownScheduling: Sendable {
  func schedule(
    after delay: Duration,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> VirtualMachineScheduledShutdown
}

final class VirtualMachineScheduledShutdown: @unchecked Sendable {
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

struct ContinuousClockVirtualMachineShutdownScheduler: VirtualMachineShutdownScheduling {
  func schedule(
    after delay: Duration,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> VirtualMachineScheduledShutdown {
    let task = Task { @MainActor in
      do {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      await operation()
    }
    return VirtualMachineScheduledShutdown {
      task.cancel()
    }
  }
}

typealias MacVirtualMachineShutdownPolicy = VirtualMachineShutdownPolicy
typealias MacVirtualMachineShutdownScheduling = VirtualMachineShutdownScheduling
typealias MacVirtualMachineScheduledShutdown = VirtualMachineScheduledShutdown
typealias ContinuousClockMacVirtualMachineShutdownScheduler =
  ContinuousClockVirtualMachineShutdownScheduler
