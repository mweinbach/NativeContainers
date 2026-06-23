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

protocol LinuxVirtualMachineSavedStateReclamationStoring: Sendable {
  func prepareSavedStateReclamation(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineSavedStateReclamationCandidate?

  func reclaimSavedState(
    _ candidate: VirtualMachineSavedStateReclamationCandidate,
    for lease: LinuxVirtualMachineRuntimeLease
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

extension LinuxVirtualMachineSavedStateStore:
  LinuxVirtualMachineSavedStateReclamationStoring
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

struct LinuxVirtualMachineSavedStateReclamationService:
  VirtualMachineSavedStateStorageReclaiming
{
  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let store: any LinuxVirtualMachineSavedStateReclamationStoring

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    store: any LinuxVirtualMachineSavedStateReclamationStoring
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
        let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
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
      candidates: candidates.sorted(by: Self.candidateOrder),
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
        let lease = try await leasingStore.acquireLinuxRuntime(
          id: candidate.machineID
        )
        defer { lease.release() }
        let removed = try await store.reclaimSavedState(
          candidate,
          for: lease
        )
        result = result.merging(
          VirtualMachineStorageReclamationBatchResult(
            removedCandidateIDs: removed ? [candidate.id] : [],
            staleCandidateIDs: removed ? [] : [candidate.id],
            failedCandidates: [],
            removedAllocatedBytes: removed
              ? candidate.estimatedAllocatedBytes : 0
          )
        )
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

  private static func candidateOrder(
    _ lhs: VirtualMachineSavedStateReclamationCandidate,
    _ rhs: VirtualMachineSavedStateReclamationCandidate
  ) -> Bool {
    let nameOrder = lhs.machineName.localizedStandardCompare(rhs.machineName)
    return nameOrder == .orderedSame
      ? lhs.machineID.uuidString < rhs.machineID.uuidString
      : nameOrder == .orderedAscending
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

struct GuestAwareVirtualMachineSavedStateReclamationService:
  VirtualMachineSavedStateStorageReclaiming
{
  private let inventory: any VirtualMachineInventoryLoading
  private let macOS: any VirtualMachineSavedStateStorageReclaiming
  private let linux: any VirtualMachineSavedStateStorageReclaiming

  init(
    inventory: any VirtualMachineInventoryLoading,
    macOS: any VirtualMachineSavedStateStorageReclaiming,
    linux: any VirtualMachineSavedStateStorageReclaiming
  ) {
    self.inventory = inventory
    self.macOS = macOS
    self.linux = linux
  }

  func prepareSavedStateReclamation(
    machineIDs: Set<UUID>
  ) async throws -> VirtualMachineSavedStateReclamationPlan {
    let manifests = Dictionary(
      uniqueKeysWithValues: try await inventory.list().map { ($0.id, $0) }
    )
    var macIDs: Set<UUID> = []
    var linuxIDs: Set<UUID> = []
    var issues: [VirtualMachineStorageReclamationPlanningIssue] = []

    for machineID in machineIDs {
      guard let manifest = manifests[machineID] else {
        issues.append(Self.missingMachineIssue(machineID))
        continue
      }
      switch manifest.guest {
      case .macOS:
        macIDs.insert(machineID)
      case .linux, .windows:
        linuxIDs.insert(machineID)
      }
    }

    let macPlan = try await macOS.prepareSavedStateReclamation(
      machineIDs: macIDs
    )
    try Task.checkCancellation()
    let linuxPlan = try await linux.prepareSavedStateReclamation(
      machineIDs: linuxIDs
    )
    return VirtualMachineSavedStateReclamationPlan(
      candidates: (macPlan.candidates + linuxPlan.candidates).sorted(
        by: Self.candidateOrder
      ),
      issues: issues + macPlan.issues + linuxPlan.issues
    )
  }

  func reclaimSavedStates(
    _ plan: VirtualMachineSavedStateReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    let manifests = Dictionary(
      uniqueKeysWithValues: try await inventory.list().map { ($0.id, $0) }
    )
    var macCandidates: [VirtualMachineSavedStateReclamationCandidate] = []
    var linuxCandidates: [VirtualMachineSavedStateReclamationCandidate] = []
    var result = VirtualMachineStorageReclamationBatchResult.empty

    for candidate in plan.candidates {
      guard let manifest = manifests[candidate.machineID] else {
        result = result.merging(
          VirtualMachineStorageReclamationBatchResult(
            removedCandidateIDs: [],
            staleCandidateIDs: [candidate.id],
            failedCandidates: [],
            removedAllocatedBytes: 0
          )
        )
        continue
      }
      switch manifest.guest {
      case .macOS:
        macCandidates.append(candidate)
      case .linux, .windows:
        linuxCandidates.append(candidate)
      }
    }

    result = try await reclaim(
      macCandidates,
      using: macOS,
      accumulating: result,
      laterCandidates: linuxCandidates
    )
    return try await reclaim(
      linuxCandidates,
      using: linux,
      accumulating: result,
      laterCandidates: []
    )
  }

  private func reclaim(
    _ candidates: [VirtualMachineSavedStateReclamationCandidate],
    using service: any VirtualMachineSavedStateStorageReclaiming,
    accumulating result: VirtualMachineStorageReclamationBatchResult,
    laterCandidates: [VirtualMachineSavedStateReclamationCandidate]
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    do {
      let next = try await service.reclaimSavedStates(
        VirtualMachineSavedStateReclamationPlan(
          candidates: candidates,
          issues: []
        )
      )
      return result.merging(next)
    } catch let partial as VirtualMachineStorageReclamationBatchPartialCompletionError {
      throw VirtualMachineStorageReclamationBatchPartialCompletionError(
        result: result.merging(partial.result),
        remainingCandidateIDs: partial.remainingCandidateIDs
          + laterCandidates.map(\.id)
      )
    }
  }

  private static func missingMachineIssue(
    _ machineID: UUID
  ) -> VirtualMachineStorageReclamationPlanningIssue {
    VirtualMachineStorageReclamationPlanningIssue(
      id: "saved-state:\(machineID.uuidString.lowercased())",
      category: .savedStates,
      machineID: machineID,
      message: "The virtual machine no longer exists."
    )
  }

  private static func candidateOrder(
    _ lhs: VirtualMachineSavedStateReclamationCandidate,
    _ rhs: VirtualMachineSavedStateReclamationCandidate
  ) -> Bool {
    let nameOrder = lhs.machineName.localizedStandardCompare(rhs.machineName)
    return nameOrder == .orderedSame
      ? lhs.machineID.uuidString < rhs.machineID.uuidString
      : nameOrder == .orderedAscending
  }
}
