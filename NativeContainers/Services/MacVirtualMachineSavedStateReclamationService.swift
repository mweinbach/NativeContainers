import Foundation

protocol MacVirtualMachineSavedStateReclamationStoring: Sendable {
  func prepareSavedStateReclamation(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineSavedStateReclamationCandidate?

  func reclaimSavedState(
    _ candidate: VirtualMachineSavedStateReclamationCandidate,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> Bool
}

protocol VirtualMachineSavedStateStorageReclaiming: Sendable {
  func prepareSavedStateReclamation(
    machineIDs: Set<UUID>
  ) async throws -> VirtualMachineSavedStateReclamationPlan

  func reclaimSavedStates(
    _ plan: VirtualMachineSavedStateReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult
}

extension MacVirtualMachineSavedStateStore:
  MacVirtualMachineSavedStateReclamationStoring
{}

struct MacVirtualMachineSavedStateReclamationService:
  VirtualMachineSavedStateStorageReclaiming
{
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let store: any MacVirtualMachineSavedStateReclamationStoring

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    store: any MacVirtualMachineSavedStateReclamationStoring
  ) {
    self.leasingStore = leasingStore
    self.store = store
  }

  func prepareSavedStateReclamation(
    machineIDs: Set<UUID>
  ) async throws -> VirtualMachineSavedStateReclamationPlan {
    var candidates: [VirtualMachineSavedStateReclamationCandidate] = []
    var issues: [VirtualMachineStorageReclamationPlanningIssue] = []

    for machineID in machineIDs.sorted(by: {
      $0.uuidString.localizedStandardCompare($1.uuidString) == .orderedAscending
    }) {
      try Task.checkCancellation()
      do {
        let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
        defer { lease.release() }
        if let candidate = try await store.prepareSavedStateReclamation(
          for: lease
        ) {
          candidates.append(candidate)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(
          VirtualMachineStorageReclamationPlanningIssue(
            id: "saved-state:\(machineID.uuidString.lowercased())",
            category: .savedStates,
            machineID: machineID,
            message: error.localizedDescription
          )
        )
      }
    }

    return VirtualMachineSavedStateReclamationPlan(
      candidates: candidates.sorted {
        let nameOrder = $0.machineName.localizedStandardCompare($1.machineName)
        return nameOrder == .orderedSame
          ? $0.machineID.uuidString < $1.machineID.uuidString
          : nameOrder == .orderedAscending
      },
      issues: issues
    )
  }

  func reclaimSavedStates(
    _ plan: VirtualMachineSavedStateReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    var result = VirtualMachineStorageReclamationBatchResult.empty

    for (index, candidate) in plan.candidates.enumerated() {
      guard !Task.isCancelled else {
        throw partial(result: result, remaining: plan.candidates[index...])
      }

      do {
        let lease = try await leasingStore.acquireMacOSRuntime(
          id: candidate.machineID
        )
        defer { lease.release() }
        let removed = try await store.reclaimSavedState(
          candidate,
          for: lease
        )
        if removed {
          result = result.merging(
            VirtualMachineStorageReclamationBatchResult(
              removedCandidateIDs: [candidate.id],
              staleCandidateIDs: [],
              failedCandidates: [],
              removedAllocatedBytes: candidate.estimatedAllocatedBytes
            )
          )
        } else {
          result = result.merging(
            VirtualMachineStorageReclamationBatchResult(
              removedCandidateIDs: [],
              staleCandidateIDs: [candidate.id],
              failedCandidates: [],
              removedAllocatedBytes: 0
            )
          )
        }
      } catch is CancellationError {
        throw partial(result: result, remaining: plan.candidates[index...])
      } catch {
        result = result.merging(
          VirtualMachineStorageReclamationBatchResult(
            removedCandidateIDs: [],
            staleCandidateIDs: [],
            failedCandidates: [
              VirtualMachineStorageReclamationCandidateFailure(
                candidateID: candidate.id,
                message: error.localizedDescription
              )
            ],
            removedAllocatedBytes: 0
          )
        )
      }

      guard !Task.isCancelled else {
        let next = plan.candidates.index(after: index)
        throw partial(result: result, remaining: plan.candidates[next...])
      }
    }
    return result
  }

  private func partial(
    result: VirtualMachineStorageReclamationBatchResult,
    remaining: ArraySlice<VirtualMachineSavedStateReclamationCandidate>
  ) -> VirtualMachineStorageReclamationBatchPartialCompletionError {
    VirtualMachineStorageReclamationBatchPartialCompletionError(
      result: result,
      remainingCandidateIDs: remaining.map(\.id)
    )
  }
}
