import Foundation

@MainActor
final class LinuxVirtualMachineRuntimeObservations {
  private let store = VirtualMachineRuntimeObservationStore<
    LinuxVirtualMachineRuntimeSnapshot
  > {
    LinuxVirtualMachineRuntimeSnapshot(machineID: $0)
  }

  func snapshot(for machineID: UUID) -> LinuxVirtualMachineRuntimeSnapshot {
    store.snapshot(for: machineID)
  }

  func updates(
    for machineID: UUID
  ) -> AsyncStream<LinuxVirtualMachineRuntimeSnapshot> {
    store.updates(for: machineID)
  }

  func publish(
    machineID: UUID,
    target: LinuxVirtualMachineRuntimeTarget? = nil,
    state: LinuxVirtualMachineRuntimeState,
    hasInstallationMedia: Bool? = nil,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    let current = snapshot(for: machineID)
    store.publish(
      LinuxVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        revision: current.revision + 1,
        target: target,
        state: state,
        hasInstallationMedia:
          hasInstallationMedia ?? current.hasInstallationMedia,
        isForceStopQueued: isForceStopQueued,
        isForceStopCompleteAwaitingCleanup:
          isForceStopCompleteAwaitingCleanup,
        errorMessage: errorMessage
      ),
      for: machineID
    )
  }
}
