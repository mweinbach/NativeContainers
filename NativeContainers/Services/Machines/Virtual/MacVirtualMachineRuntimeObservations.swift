import Foundation

@MainActor
final class MacVirtualMachineRuntimeObservations {
  private var snapshots: [UUID: MacVirtualMachineRuntimeSnapshot] = [:]
  private var subscribers:
    [UUID: [UUID: AsyncStream<MacVirtualMachineRuntimeSnapshot>.Continuation]] = [:]

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    snapshots[machineID]
      ?? MacVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        state: .inspectingSavedState
      )
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    let subscriptionID = UUID()
    let pair = AsyncStream.makeStream(
      of: MacVirtualMachineRuntimeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    subscribers[machineID, default: [:]][subscriptionID] = pair.continuation
    _ = pair.continuation.yield(snapshot(for: machineID))
    pair.continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeSubscriber(subscriptionID, for: machineID)
      }
    }
    return pair.stream
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
    let value = MacVirtualMachineRuntimeSnapshot(
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
    )
    snapshots[machineID] = value
    if let continuations = subscribers[machineID]?.values {
      for continuation in continuations {
        _ = continuation.yield(value)
      }
    }
  }

  private func removeSubscriber(_ subscriptionID: UUID, for machineID: UUID) {
    subscribers[machineID]?[subscriptionID] = nil
    if subscribers[machineID]?.isEmpty == true {
      subscribers[machineID] = nil
    }
  }
}
