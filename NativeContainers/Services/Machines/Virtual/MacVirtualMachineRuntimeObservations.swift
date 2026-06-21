import Foundation

@MainActor
final class MacVirtualMachineRuntimeObservations {
  private let store = VirtualMachineRuntimeObservationStore<
    MacVirtualMachineRuntimeSnapshot
  > {
    MacVirtualMachineRuntimeSnapshot(
      machineID: $0,
      state: .inspectingSavedState
    )
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    store.snapshot(for: machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    store.updates(for: machineID)
  }

  func publish(
    machineID: UUID,
    target: MacVirtualMachineRuntimeTarget? = nil,
    state: MacVirtualMachineRuntimeState,
    savedStateStatus: MacVirtualMachineSavedStateStatus? = nil,
    saveRestoreSupport: MacVirtualMachineSaveRestoreSupport? = nil,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    let current = snapshot(for: machineID)
    store.publish(
      MacVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        revision: current.revision + 1,
        target: target,
        state: state,
        savedStateStatus: savedStateStatus ?? current.savedStateStatus,
        saveRestoreSupport: saveRestoreSupport ?? current.saveRestoreSupport,
        isForceStopQueued: isForceStopQueued,
        isForceStopCompleteAwaitingCleanup:
          isForceStopCompleteAwaitingCleanup,
        errorMessage: errorMessage
      ),
      for: machineID
    )
  }
}
