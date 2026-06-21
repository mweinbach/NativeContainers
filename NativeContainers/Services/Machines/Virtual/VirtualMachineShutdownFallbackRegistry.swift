import Foundation

@MainActor
final class VirtualMachineShutdownFallbackRegistry {
  private struct Entry {
    let target: VirtualMachineRuntimeTarget
    let token: UUID
    let scheduledShutdown: VirtualMachineScheduledShutdown
  }

  private let timeout: Duration
  private let scheduler: any VirtualMachineShutdownScheduling
  private var entries: [UUID: Entry] = [:]

  init(
    timeout: Duration,
    scheduler: any VirtualMachineShutdownScheduling
  ) {
    self.timeout = timeout
    self.scheduler = scheduler
  }

  func schedule(
    for target: VirtualMachineRuntimeTarget,
    operation: @escaping @MainActor @Sendable (UUID) async -> Void
  ) {
    cancel(machineID: target.machineID)
    let token = UUID()
    let scheduledShutdown = scheduler.schedule(after: timeout) {
      await operation(token)
    }
    entries[target.machineID] = Entry(
      target: target,
      token: token,
      scheduledShutdown: scheduledShutdown
    )
  }

  func isScheduled(
    for target: VirtualMachineRuntimeTarget,
    token: UUID
  ) -> Bool {
    guard let entry = entries[target.machineID] else { return false }
    return entry.target == target && entry.token == token
  }

  func consume(
    target: VirtualMachineRuntimeTarget,
    token: UUID
  ) {
    guard isScheduled(for: target, token: token) else { return }
    entries[target.machineID] = nil
  }

  func cancel(for target: VirtualMachineRuntimeTarget) {
    guard entries[target.machineID]?.target == target else { return }
    cancel(machineID: target.machineID)
  }

  func cancel(machineID: UUID) {
    entries.removeValue(forKey: machineID)?.scheduledShutdown.cancel()
  }
}

typealias MacVirtualMachineShutdownFallbackRegistry =
  VirtualMachineShutdownFallbackRegistry
