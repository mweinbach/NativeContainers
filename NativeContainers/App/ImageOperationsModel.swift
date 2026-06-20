import Foundation
import Observation

@MainActor
@Observable
final class ImageOperationsModel {
  let sourceReference: String?
  private(set) var isWorking = false
  private(set) var errorMessage: String?
  private(set) var tagPlan: ImageTagPlan?
  private(set) var deletionPlan: ImageDeletionPlan?
  private(set) var prunePlan: ImagePrunePlan?
  private(set) var pushPlan: ImagePushPlan?
  private(set) var cleanupResult: ImageCleanupResult?
  private(set) var progress: ContainerOperationProgress?

  private let service: any ImageManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    sourceReference: String? = nil,
    service: any ImageManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.sourceReference = sourceReference
    self.service = service
    self.didMutate = didMutate
  }

  func prepareTag(target: String) async -> ImageTagPlan? {
    guard let sourceReference else {
      errorMessage = ImageManagementError.missingReference.localizedDescription
      return nil
    }
    return await prepare {
      let plan = try await self.service.prepareImageTag(
        source: sourceReference,
        target: target
      )
      self.tagPlan = plan
      return plan
    }
  }

  func applyTag(replacingExisting: Bool) async -> Bool {
    guard let tagPlan else {
      errorMessage = ImageManagementError.stalePlan("tag operation").localizedDescription
      return false
    }
    let succeeded = await mutate {
      try await self.service.tagImage(tagPlan, replacingExisting: replacingExisting)
    }
    if succeeded { self.tagPlan = nil }
    return succeeded
  }

  func prepareDeletion() async -> ImageDeletionPlan? {
    guard let sourceReference else {
      errorMessage = ImageManagementError.missingReference.localizedDescription
      return nil
    }
    return await prepare {
      let plan = try await self.service.prepareImageDeletion(reference: sourceReference)
      self.deletionPlan = plan
      return plan
    }
  }

  func preparePush(
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async -> ImagePushPlan? {
    guard let sourceReference else {
      errorMessage = ImageManagementError.missingReference.localizedDescription
      return nil
    }
    return await prepare {
      let plan = try await self.service.prepareImagePush(
        reference: sourceReference,
        platform: platform,
        transport: transport
      )
      self.pushPlan = plan
      return plan
    }
  }

  func pushReviewedImage(
    _ reviewedPlan: ImagePushPlan? = nil,
    authorization: ImagePushAuthorization
  ) async -> Bool {
    guard let plan = reviewedPlan ?? pushPlan else {
      errorMessage = ImageManagementError.stalePlan("push operation").localizedDescription
      return false
    }
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    progress = nil
    defer { isWorking = false }
    do {
      try await self.service.pushImage(plan, authorization: authorization) { update in
        await self.receive(update)
      }
      pushPlan = nil
      await didMutate()
      return true
    } catch is CancellationError {
      errorMessage =
        "The push was cancelled. The remote tag may already have changed; inspect the registry before retrying."
      await didMutate()
      return false
    } catch {
      errorMessage =
        "\(error.localizedDescription) The remote tag may already have changed; inspect the registry before retrying."
      await didMutate()
      return false
    }
  }

  func deleteReviewedImage(_ reviewedPlan: ImageDeletionPlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? deletionPlan else {
      errorMessage = ImageManagementError.stalePlan("deletion").localizedDescription
      return false
    }
    guard plan.canDelete else {
      if plan.isInfrastructureImage {
        errorMessage =
          ImageManagementError.infrastructureImage(plan.reference)
          .localizedDescription
      } else {
        errorMessage =
          ImageManagementError.imageInUse(
            reference: plan.reference,
            containerIDs: plan.usedByContainerIDs
          ).localizedDescription
      }
      return false
    }

    let result = await mutateWithResult {
      try await self.service.deleteImage(plan)
    }
    guard let result else { return false }
    cleanupResult = result
    if let failure = result.failedReferences.first {
      errorMessage = "\(failure.reference): \(failure.message)"
    }
    return result.removedReferences.contains(plan.reference)
  }

  func preparePrune(mode: ImagePruneMode) async -> ImagePrunePlan? {
    await prepare {
      let plan = try await self.service.prepareImagePrune(mode: mode)
      self.prunePlan = plan
      self.cleanupResult = nil
      return plan
    }
  }

  func pruneReviewedImages() async -> Bool {
    guard let prunePlan else {
      errorMessage = ImageManagementError.stalePlan("prune operation").localizedDescription
      return false
    }
    let result = await mutateWithResult {
      try await self.service.pruneImages(prunePlan)
    }
    guard let result else { return false }
    cleanupResult = result
    self.prunePlan = nil
    if !result.failedReferences.isEmpty {
      errorMessage = "Some images were skipped or could not be removed."
    }
    return result.completedWithoutFailures
  }

  func clearError() {
    errorMessage = nil
  }

  func clearPlans() {
    tagPlan = nil
    deletionPlan = nil
    prunePlan = nil
    pushPlan = nil
  }

  func resetReview() {
    clearPlans()
    cleanupResult = nil
    progress = nil
    errorMessage = nil
  }

  private func prepare<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
  ) async -> T? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    progress = nil
    defer { isWorking = false }
    do {
      return try await operation()
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func mutate(
    _ operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    progress = nil
    defer { isWorking = false }
    do {
      try await operation()
      await didMutate()
      return true
    } catch is CancellationError {
      await didMutate()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await didMutate()
      return false
    }
  }

  private func mutateWithResult(
    _ operation: @escaping @MainActor @Sendable () async throws -> ImageCleanupResult
  ) async -> ImageCleanupResult? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    progress = nil
    defer { isWorking = false }
    do {
      let result = try await operation()
      await didMutate()
      return result
    } catch is CancellationError {
      await didMutate()
      return nil
    } catch {
      errorMessage = error.localizedDescription
      await didMutate()
      return nil
    }
  }

  private func receive(_ update: ContainerOperationProgress) {
    progress = update
  }
}
