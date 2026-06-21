import Foundation

@MainActor
final class VirtualMachineRuntimeObservationStore<Snapshot: Sendable> {
  private let initialSnapshot: (UUID) -> Snapshot
  private var snapshots: [UUID: Snapshot] = [:]
  private var subscribers:
    [UUID: [UUID: AsyncStream<Snapshot>.Continuation]] = [:]

  init(initialSnapshot: @escaping (UUID) -> Snapshot) {
    self.initialSnapshot = initialSnapshot
  }

  func snapshot(for machineID: UUID) -> Snapshot {
    snapshots[machineID] ?? initialSnapshot(machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<Snapshot> {
    let subscriptionID = UUID()
    let pair = AsyncStream.makeStream(
      of: Snapshot.self,
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

  func publish(_ snapshot: Snapshot, for machineID: UUID) {
    snapshots[machineID] = snapshot
    if let continuations = subscribers[machineID]?.values {
      for continuation in continuations {
        _ = continuation.yield(snapshot)
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
