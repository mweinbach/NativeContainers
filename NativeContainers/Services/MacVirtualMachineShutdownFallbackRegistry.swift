import Foundation

@MainActor
final class MacVirtualMachineShutdownFallbackRegistry {
  private struct Entry {
    let target: MacVirtualMachineRuntimeTarget
    let token: UUID
    let scheduledShutdown: MacVirtualMachineScheduledShutdown
  }

  private let timeout: Duration
  private let scheduler: any MacVirtualMachineShutdownScheduling
  private var entries: [UUID: Entry] = [:]

  init(
    timeout: Duration,
    scheduler: any MacVirtualMachineShutdownScheduling
  ) {
    self.timeout = timeout
    self.scheduler = scheduler
  }

  func schedule(
    for target: MacVirtualMachineRuntimeTarget,
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
    for target: MacVirtualMachineRuntimeTarget,
    token: UUID
  ) -> Bool {
    guard let entry = entries[target.machineID] else { return false }
    return entry.target == target && entry.token == token
  }

  func consume(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID
  ) {
    guard isScheduled(for: target, token: token) else { return }
    entries[target.machineID] = nil
  }

  func cancel(for target: MacVirtualMachineRuntimeTarget) {
    guard entries[target.machineID]?.target == target else { return }
    cancel(machineID: target.machineID)
  }

  func cancel(machineID: UUID) {
    entries.removeValue(forKey: machineID)?.scheduledShutdown.cancel()
  }
}
