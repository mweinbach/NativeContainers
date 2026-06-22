import Foundation

@MainActor
final class LinuxVirtualMachineRuntimeObservations {
  private let store = VirtualMachineRuntimeObservationStore<
    LinuxVirtualMachineRuntimeSnapshot
  > {
    LinuxVirtualMachineRuntimeSnapshot(
      machineID: $0,
      state: .inspectingSavedState
    )
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
    savedStateStatus: LinuxVirtualMachineSavedStateStatus? = nil,
    saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport? = nil,
    memoryBalloon: VirtualMachineMemoryBalloonSnapshot? = nil,
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
        savedStateStatus:
          savedStateStatus ?? current.savedStateStatus,
        saveRestoreSupport:
          saveRestoreSupport ?? current.saveRestoreSupport,
        memoryBalloon: memoryBalloon,
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
