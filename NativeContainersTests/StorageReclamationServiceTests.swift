import Foundation
import Testing

@testable import NativeContainers

@Suite("Storage reclamation service")
struct StorageReclamationServiceTests {
  @Test
  func composesAllSelectedCategoryPlansWithSourceProvenance() async throws {
    let fixture = ReclamationServiceFixture()
    let request = StorageReclamationRequest(
      source: fixture.source,
      reclaimContainers: true
    )

    let plan = try await fixture.service.prepareStorageReclamation(request)

    #expect(plan.request == request)
    #expect(plan.generatedAt == Date(timeIntervalSince1970: 99))
    #expect(plan.containerPlan == fixture.containerPlan)
    #expect(plan.imagePlan == fixture.imagePlan)
    #expect(plan.volumePlan == fixture.volumePlan)
  }

  @Test
  func executesExactReviewedPlansInDeterministicOrder() async throws {
    let fixture = ReclamationServiceFixture()
    let request = StorageReclamationRequest(
      source: fixture.source,
      reclaimContainers: true
    )
    let plan = try await fixture.service.prepareStorageReclamation(request)

    let result = try await fixture.service.reclaimStorage(plan)

    #expect(
      await fixture.log.values
        == ["containers", "images", "volumes"]
    )
    #expect(await fixture.categories.receivedContainerPlans == [fixture.containerPlan])
    #expect(await fixture.categories.receivedImagePlans == [fixture.imagePlan])
    #expect(await fixture.categories.receivedVolumePlans == [fixture.volumePlan])
    #expect(result.removedCandidateCount == 3)
  }

  @Test
  func categoryFailureDoesNotBlockLaterReviewedCategories() async throws {
    let fixture = ReclamationServiceFixture(
      containerExecution: .failure("Container service failed")
    )
    let request = StorageReclamationRequest(
      source: fixture.source,
      reclaimContainers: true
    )
    let plan = try await fixture.service.prepareStorageReclamation(request)

    let result = try await fixture.service.reclaimStorage(plan)

    #expect(await fixture.log.values == ["containers", "images", "volumes"])
    #expect(result.containerResult == nil)
    #expect(result.imageResult != nil)
    #expect(result.volumeResult != nil)
    #expect(result.categoryFailures.map(\.category) == [.containers])
  }

  @Test
  func partialImageCancellationPreservesResultAndSkipsLaterCategory() async throws {
    let partial = ImageCleanupResult(
      removedReferences: ["old:image"],
      failedReferences: [
        ImageOperationFailure(
          reference: "remaining:image",
          message: "Not removed because image cleanup was cancelled."
        )
      ],
      removedBlobDigests: ["sha256:old"],
      reclaimedBytes: 123
    )
    let fixture = ReclamationServiceFixture(
      imageExecution: .partial(partial)
    )
    let request = StorageReclamationRequest(source: fixture.source)
    let plan = try await fixture.service.prepareStorageReclamation(request)

    do {
      _ = try await fixture.service.reclaimStorage(plan)
      Issue.record("Expected partial completion")
    } catch let error as StorageReclamationPartialCompletionError {
      #expect(error.result.imageResult == partial)
      #expect(error.remainingCategories == [.images, .volumes])
    }

    #expect(await fixture.log.values == ["images"])
  }

  @Test
  func cancellationObservedAfterUncooperativeCategoryStopsBeforeNextCategory() async throws {
    let fixture = ReclamationServiceFixture(
      imageExecution: .cancelAfterSuccess
    )
    let request = StorageReclamationRequest(source: fixture.source)
    let plan = try await fixture.service.prepareStorageReclamation(request)
    let operation = Task {
      try await fixture.service.reclaimStorage(plan)
    }

    do {
      _ = try await operation.value
      Issue.record("Expected partial completion")
    } catch let error as StorageReclamationPartialCompletionError {
      #expect(error.result.imageResult != nil)
      #expect(error.remainingCategories == [.volumes])
    }

    #expect(await fixture.log.values == ["images"])
  }

  @Test
  func rejectsMismatchedPlansAndEmptyScope() async throws {
    let fixture = ReclamationServiceFixture()
    await #expect(throws: StorageReclamationError.emptyScope) {
      try await fixture.service.prepareStorageReclamation(
        StorageReclamationRequest(
          source: fixture.source,
          reclaimContainers: false,
          reclaimImages: false,
          reclaimVolumes: false
        )
      )
    }

    let invalid = StorageReclamationPlan(
      request: StorageReclamationRequest(source: fixture.source),
      generatedAt: .now,
      containerPlan: nil,
      imagePlan: nil,
      volumePlan: fixture.volumePlan
    )
    await #expect(throws: StorageReclamationError.invalidPlan) {
      try await fixture.service.reclaimStorage(invalid)
    }
  }

  @Test
  func estimatesTrackUnknownValuesAndSaturateReportedTotals() {
    let fixture = ReclamationServiceFixture(volumeAllocatedBytes: nil)
    let plan = StorageReclamationPlan(
      request: StorageReclamationRequest(
        source: fixture.source,
        reclaimContainers: true
      ),
      generatedAt: .now,
      containerPlan: fixture.containerPlan,
      imagePlan: fixture.imagePlan,
      volumePlan: fixture.volumePlan
    )
    let result = StorageReclamationResult(
      containerResult: ContainerCleanupResult(
        removedContainerIDs: ["one"],
        failedContainers: [],
        removedAllocatedBytes: UInt64.max
      ),
      imageResult: ImageCleanupResult(
        removedReferences: ["image"],
        failedReferences: [],
        removedBlobDigests: [],
        reclaimedBytes: 1
      ),
      volumeResult: ResourceCleanupResult(
        removedResourceNames: ["volume"],
        failedResources: [],
        reclaimedBytes: 1
      ),
      categoryFailures: []
    )

    #expect(!plan.hasCompleteEstimate)
    #expect(result.reportedRemovedBytes == UInt64.max)
  }
}

private struct ReclamationServiceFixture {
  let source: StorageReclamationSource
  let containerPlan: ContainerPrunePlan
  let imagePlan: ImagePrunePlan
  let volumePlan: VolumePrunePlan
  let log = ReclamationExecutionLog()
  let categories: ReclamationCategoryDouble
  let service: StorageReclamationService

  init(
    containerExecution: ReclamationExecution<ContainerCleanupResult> = .success(
      ContainerCleanupResult(
        removedContainerIDs: ["old-container"],
        failedContainers: [],
        removedAllocatedBytes: 10
      )
    ),
    imageExecution: ReclamationExecution<ImageCleanupResult> = .success(
      ImageCleanupResult(
        removedReferences: ["old:image"],
        failedReferences: [],
        removedBlobDigests: ["sha256:old"],
        reclaimedBytes: 20
      )
    ),
    volumeExecution: ReclamationExecution<ResourceCleanupResult> = .success(
      ResourceCleanupResult(
        removedResourceNames: ["old-volume"],
        failedResources: [],
        reclaimedBytes: 30
      )
    ),
    volumeAllocatedBytes: UInt64? = 30
  ) {
    source = makeReclamationSource()
    containerPlan = makeContainerPlan()
    imagePlan = makeImagePlan()
    volumePlan = makeVolumePlan(allocatedBytes: volumeAllocatedBytes)
    categories = ReclamationCategoryDouble(
      containerPlan: containerPlan,
      imagePlan: imagePlan,
      volumePlan: volumePlan,
      containerExecution: containerExecution,
      imageExecution: imageExecution,
      volumeExecution: volumeExecution,
      log: log
    )
    service = StorageReclamationService(
      containers: categories,
      images: categories,
      volumes: categories,
      executionCoordinator: RuntimeMutationCoordinator(),
      now: { Date(timeIntervalSince1970: 99) }
    )
  }
}

private enum ReclamationExecution<Value: Sendable>: Sendable {
  case success(Value)
  case failure(String)
  case partial(Value)
  case cancelAfterSuccess
}

private struct ReclamationTestError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private actor ReclamationExecutionLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor ReclamationCategoryDouble:
  ContainerStorageReclaiming,
  ImageStorageReclaiming,
  VolumeStorageReclaiming
{
  let containerPlan: ContainerPrunePlan
  let imagePlan: ImagePrunePlan
  let volumePlan: VolumePrunePlan
  let containerExecution: ReclamationExecution<ContainerCleanupResult>
  let imageExecution: ReclamationExecution<ImageCleanupResult>
  let volumeExecution: ReclamationExecution<ResourceCleanupResult>
  let log: ReclamationExecutionLog

  private(set) var receivedContainerPlans: [ContainerPrunePlan] = []
  private(set) var receivedImagePlans: [ImagePrunePlan] = []
  private(set) var receivedVolumePlans: [VolumePrunePlan] = []

  init(
    containerPlan: ContainerPrunePlan,
    imagePlan: ImagePrunePlan,
    volumePlan: VolumePrunePlan,
    containerExecution: ReclamationExecution<ContainerCleanupResult>,
    imageExecution: ReclamationExecution<ImageCleanupResult>,
    volumeExecution: ReclamationExecution<ResourceCleanupResult>,
    log: ReclamationExecutionLog
  ) {
    self.containerPlan = containerPlan
    self.imagePlan = imagePlan
    self.volumePlan = volumePlan
    self.containerExecution = containerExecution
    self.imageExecution = imageExecution
    self.volumeExecution = volumeExecution
    self.log = log
  }

  func prepareContainerPrune() async throws -> ContainerPrunePlan {
    containerPlan
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    imagePlan
  }

  func prepareVolumePrune() async throws -> VolumePrunePlan {
    volumePlan
  }

  func pruneContainers(
    _ plan: ContainerPrunePlan
  ) async throws -> ContainerCleanupResult {
    receivedContainerPlans.append(plan)
    await log.append("containers")
    switch containerExecution {
    case .success(let result):
      return result
    case .failure(let message):
      throw ReclamationTestError(message: message)
    case .partial(let result):
      throw ContainerCleanupPartialCompletionError(result: result)
    case .cancelAfterSuccess:
      withUnsafeCurrentTask { $0?.cancel() }
      return ContainerCleanupResult(
        removedContainerIDs: [],
        failedContainers: [],
        removedAllocatedBytes: 0
      )
    }
  }

  func pruneImages(
    _ plan: ImagePrunePlan
  ) async throws -> ImageCleanupResult {
    receivedImagePlans.append(plan)
    await log.append("images")
    switch imageExecution {
    case .success(let result):
      return result
    case .failure(let message):
      throw ReclamationTestError(message: message)
    case .partial(let result):
      throw ImageCleanupPartialCompletionError(result: result)
    case .cancelAfterSuccess:
      withUnsafeCurrentTask { $0?.cancel() }
      return ImageCleanupResult(
        removedReferences: ["old:image"],
        failedReferences: [],
        removedBlobDigests: [],
        reclaimedBytes: 20
      )
    }
  }

  func pruneVolumes(
    _ plan: VolumePrunePlan
  ) async throws -> ResourceCleanupResult {
    receivedVolumePlans.append(plan)
    await log.append("volumes")
    switch volumeExecution {
    case .success(let result):
      return result
    case .failure(let message):
      throw ReclamationTestError(message: message)
    case .partial(let result):
      throw ResourceCleanupPartialCompletionError(
        operation: "Volume pruning",
        result: result
      )
    case .cancelAfterSuccess:
      withUnsafeCurrentTask { $0?.cancel() }
      return ResourceCleanupResult(
        removedResourceNames: [],
        failedResources: [],
        reclaimedBytes: 0
      )
    }
  }
}

private func makeReclamationSource() -> StorageReclamationSource {
  StorageReclamationSource(
    appleRuntimeCapturedAt: Date(timeIntervalSince1970: 1),
    appleRuntimeRevision: 2,
    inventoryRevision: 3,
    images: StorageResourceUsage(
      totalCount: 2,
      activeCount: 1,
      allocatedBytes: 100,
      reclaimableBytes: 20
    ),
    containers: StorageResourceUsage(
      totalCount: 2,
      activeCount: 1,
      allocatedBytes: 100,
      reclaimableBytes: 10
    ),
    volumes: StorageResourceUsage(
      totalCount: 2,
      activeCount: 1,
      allocatedBytes: 100,
      reclaimableBytes: 30
    )
  )
}

private func makeContainerPlan() -> ContainerPrunePlan {
  ContainerPrunePlan(
    candidates: [
      ContainerPruneCandidate(
        id: "old-container",
        ownershipID: UUID(),
        createdAt: Date(timeIntervalSince1970: 1),
        imageReference: "old:image",
        imageDigest: "sha256:old",
        platform: "linux/arm64",
        configurationSeal: Data("seal".utf8),
        allocatedBytes: 10,
        hasPublishedSockets: false
      )
    ],
    generatedAt: Date(timeIntervalSince1970: 4)
  )
}

private func makeImagePlan() -> ImagePrunePlan {
  ImagePrunePlan(
    mode: .allUnused,
    generatedAt: Date(timeIntervalSince1970: 5),
    candidates: [
      ImagePruneCandidate(
        reference: "old:image",
        digest: "sha256:old",
        indexSizeBytes: 1
      )
    ],
    estimatedReclaimableBytes: 20
  )
}

private func makeVolumePlan(
  allocatedBytes: UInt64?
) -> VolumePrunePlan {
  let volume = VolumeRecord(
    id: "volume-id",
    name: "old-volume",
    driver: "local",
    format: "ext4",
    source: "/tmp/old-volume",
    createdAt: Date(timeIntervalSince1970: 1),
    sizeBytes: 100,
    allocatedBytes: allocatedBytes,
    labels: [:],
    options: [:],
    isAnonymous: false,
    usedByContainerIDs: []
  )
  return VolumePrunePlan(
    candidates: [
      VolumeDeletionPlan(
        volume: volume,
        identity: volume.configurationIdentity,
        generatedAt: Date(timeIntervalSince1970: 6)
      )
    ],
    generatedAt: Date(timeIntervalSince1970: 6)
  )
}
