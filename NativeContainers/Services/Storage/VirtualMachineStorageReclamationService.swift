import Foundation

protocol VirtualMachineStorageReclamationManaging: Sendable {
  func prepareVirtualMachineStorageReclamation(
    _ request: VirtualMachineStorageReclamationRequest
  ) async throws -> VirtualMachineStorageReclamationPlan

  func reclaimVirtualMachineStorage(
    _ plan: VirtualMachineStorageReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationResult
}

struct VirtualMachineStorageReclamationService:
  VirtualMachineStorageReclamationManaging
{
  private let savedStates: any VirtualMachineSavedStateStorageReclaiming
  private let residue: any VirtualMachineInterruptedResidueReclaiming
  private let restoreImages: any RestoreImageCacheStorageReclaiming
  private let executionCoordinator: RuntimeMutationCoordinator
  private let now: @Sendable () -> Date

  init(
    savedStates: any VirtualMachineSavedStateStorageReclaiming,
    residue: any VirtualMachineInterruptedResidueReclaiming,
    restoreImages: any RestoreImageCacheStorageReclaiming =
      UnavailableRestoreImageCacheReclamationService(),
    executionCoordinator: RuntimeMutationCoordinator =
      RuntimeMutationCoordinator(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.savedStates = savedStates
    self.residue = residue
    self.restoreImages = restoreImages
    self.executionCoordinator = executionCoordinator
    self.now = now
  }

  func prepareVirtualMachineStorageReclamation(
    _ request: VirtualMachineStorageReclamationRequest
  ) async throws -> VirtualMachineStorageReclamationPlan {
    guard !request.categories.isEmpty else {
      throw VirtualMachineStorageReclamationError.emptyScope
    }
    try Task.checkCancellation()

    let savedStatePlan: VirtualMachineSavedStateReclamationPlan?
    if request.savedStateMachineIDs.isEmpty {
      savedStatePlan = nil
    } else {
      savedStatePlan = try await savedStates.prepareSavedStateReclamation(
        machineIDs: request.savedStateMachineIDs
      )
    }
    try Task.checkCancellation()

    let residuePlan: VirtualMachineStorageResidueReclamationPlan?
    if request.reclaimInterruptedResidue {
      residuePlan = try await residue.prepareInterruptedResidueReclamation()
    } else {
      residuePlan = nil
    }
    try Task.checkCancellation()

    let restoreImagePlan: RestoreImageCacheReclamationPlan?
    if request.reclaimRestoreImages {
      restoreImagePlan = try await restoreImages.prepareRestoreImageReclamation()
    } else {
      restoreImagePlan = nil
    }
    try Task.checkCancellation()

    return VirtualMachineStorageReclamationPlan(
      request: request,
      generatedAt: now(),
      savedStatePlan: savedStatePlan,
      residuePlan: residuePlan,
      restoreImagePlan: restoreImagePlan
    )
  }

  func reclaimVirtualMachineStorage(
    _ plan: VirtualMachineStorageReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationResult {
    try await executionCoordinator.perform {
      try await reclaimSerially(plan)
    }
  }

  private func reclaimSerially(
    _ plan: VirtualMachineStorageReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationResult {
    guard isValid(plan) else {
      throw VirtualMachineStorageReclamationError.invalidPlan
    }

    var savedStateResult: VirtualMachineStorageReclamationBatchResult?
    var residueResult: VirtualMachineStorageReclamationBatchResult?
    var restoreImageResult: VirtualMachineStorageReclamationBatchResult?
    var categoryFailures: [VirtualMachineStorageReclamationCategoryFailure] = []

    func result() -> VirtualMachineStorageReclamationResult {
      VirtualMachineStorageReclamationResult(
        savedStateResult: savedStateResult,
        residueResult: residueResult,
        restoreImageResult: restoreImageResult,
        categoryFailures: categoryFailures
      )
    }

    func cancellation(
      remaining: [VirtualMachineStorageReclamationCategory]
    ) -> VirtualMachineStorageReclamationPartialCompletionError {
      VirtualMachineStorageReclamationPartialCompletionError(
        result: result(),
        remainingCategories: remaining.filter(plan.categories.contains)
      )
    }

    if let savedStatePlan = plan.savedStatePlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.savedStates, .interruptedResidue, .restoreImages])
      }
      do {
        savedStateResult = try await savedStates.reclaimSavedStates(
          savedStatePlan
        )
      } catch let partial as VirtualMachineStorageReclamationBatchPartialCompletionError {
        savedStateResult = partial.result
        throw cancellation(remaining: [.savedStates, .interruptedResidue, .restoreImages])
      } catch is CancellationError {
        throw cancellation(remaining: [.savedStates, .interruptedResidue, .restoreImages])
      } catch {
        categoryFailures.append(
          VirtualMachineStorageReclamationCategoryFailure(
            category: .savedStates,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.interruptedResidue, .restoreImages])
      }
    }

    if let residuePlan = plan.residuePlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.interruptedResidue, .restoreImages])
      }
      do {
        residueResult = try await residue.reclaimInterruptedResidue(
          residuePlan
        )
      } catch let partial as VirtualMachineStorageReclamationBatchPartialCompletionError {
        residueResult = partial.result
        throw cancellation(remaining: [.interruptedResidue, .restoreImages])
      } catch is CancellationError {
        throw cancellation(remaining: [.interruptedResidue, .restoreImages])
      } catch {
        categoryFailures.append(
          VirtualMachineStorageReclamationCategoryFailure(
            category: .interruptedResidue,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.restoreImages])
      }
    }

    if let restoreImagePlan = plan.restoreImagePlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.restoreImages])
      }
      do {
        restoreImageResult = try await restoreImages.reclaimRestoreImages(
          restoreImagePlan
        )
      } catch let partial as VirtualMachineStorageReclamationBatchPartialCompletionError {
        restoreImageResult = partial.result
        throw cancellation(remaining: [.restoreImages])
      } catch is CancellationError {
        throw cancellation(remaining: [.restoreImages])
      } catch {
        categoryFailures.append(
          VirtualMachineStorageReclamationCategoryFailure(
            category: .restoreImages,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [])
      }
    }

    return result()
  }

  private func isValid(
    _ plan: VirtualMachineStorageReclamationPlan
  ) -> Bool {
    guard
      !plan.categories.isEmpty,
      (plan.savedStatePlan != nil) == !plan.request.savedStateMachineIDs.isEmpty,
      (plan.residuePlan != nil) == plan.request.reclaimInterruptedResidue,
      (plan.restoreImagePlan != nil) == plan.request.reclaimRestoreImages
    else {
      return false
    }

    let savedStateCandidates = plan.savedStatePlan?.candidates ?? []
    guard
      savedStateCandidates.allSatisfy({
        plan.request.savedStateMachineIDs.contains($0.machineID)
      })
    else {
      return false
    }

    let ids =
      savedStateCandidates.map(\.id)
      + (plan.residuePlan?.candidates.map(\.id) ?? [])
      + (plan.restoreImagePlan?.candidates.map(\.id) ?? [])
    return Set(ids).count == ids.count
  }
}

struct UnavailableVirtualMachineStorageReclamationService:
  VirtualMachineStorageReclamationManaging
{
  func prepareVirtualMachineStorageReclamation(
    _ request: VirtualMachineStorageReclamationRequest
  ) async throws -> VirtualMachineStorageReclamationPlan {
    throw VirtualMachineStorageReclamationError.unavailable
  }

  func reclaimVirtualMachineStorage(
    _ plan: VirtualMachineStorageReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationResult {
    throw VirtualMachineStorageReclamationError.unavailable
  }
}
