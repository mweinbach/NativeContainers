import ContainerResource
import Foundation

actor AppleImageService: ImageManaging {
  private let transferService: AppleImageTransferService
  private let inspectionService: AppleImageInspectionService
  private let cleanupService: AppleImageCleanupService
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    containerReader: any ContainerSnapshotReading = AppleContainerSnapshotReader(),
    pruneTransport: any ImagePruneTransport = AppleImagePruneClient(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    let policy = AppleImagePolicy()
    transferService = AppleImageTransferService(policy: policy)
    inspectionService = AppleImageInspectionService(
      containerReader: containerReader,
      policy: policy
    )
    cleanupService = AppleImageCleanupService(
      containerReader: containerReader,
      pruneTransport: pruneTransport,
      policy: policy
    )
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    try await transferService.preparePull(
      reference: reference,
      platform: platform,
      transport: transport,
      unpackAfterPull: unpackAfterPull,
      maxConcurrentDownloads: maxConcurrentDownloads
    )
  }

  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    let transferService = transferService
    return try await runtimeMutationCoordinator.perform {
      try await transferService.pull(
        plan,
        authorization: authorization,
        progress: progress
      )
    }
  }

  func inspectImage(reference: String) async throws -> ImageInspection {
    try await inspectionService.inspect(reference: reference)
  }

  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    try await cleanupService.prepareTag(source: source, target: target)
  }

  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    let cleanupService = cleanupService
    try await runtimeMutationCoordinator.perform {
      try await cleanupService.tag(plan, replacingExisting: replacingExisting)
    }
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    try await cleanupService.prepareDeletion(reference: reference)
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    let cleanupService = cleanupService
    return try await runtimeMutationCoordinator.perform {
      try await cleanupService.delete(plan)
    }
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    try await cleanupService.preparePrune(mode: mode)
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    let cleanupService = cleanupService
    do {
      return try await runtimeMutationCoordinator.perform {
        try await cleanupService.prune(plan)
      }
    } catch let partial as ImageCleanupPartialCompletionError {
      throw partial
    } catch is CancellationError {
      throw ImageCleanupPartialCompletionError(
        result: ImageCleanupResult(
          removedReferences: [],
          failedReferences: plan.candidates.map {
            ImageOperationFailure(
              reference: $0.reference,
              message: "Not removed because image cleanup was cancelled."
            )
          },
          removedBlobDigests: [],
          reclaimedBytes: 0
        )
      )
    }
  }

  func prepareImagePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    try await transferService.preparePush(
      reference: reference,
      platform: platform,
      transport: transport
    )
  }

  func pushImage(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let transferService = transferService
    try await runtimeMutationCoordinator.perform {
      try await transferService.push(
        plan,
        authorization: authorization,
        progress: progress
      )
    }
  }
}
