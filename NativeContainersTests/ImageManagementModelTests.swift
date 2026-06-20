import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct ImageManagementModelTests {
  @Test
  func imageIdentityRemainsStableWhenMutableTagMoves() {
    let first = ImageRecord(
      reference: "example/app:latest",
      digest: "sha256:first",
      mediaType: "index",
      indexSizeBytes: 100
    )
    let second = ImageRecord(
      reference: "example/app:latest",
      digest: "sha256:second",
      mediaType: "index",
      indexSizeBytes: 200
    )

    #expect(first.id == second.id)
    #expect(first.id == "example/app:latest")
    #expect(first.inspectionID != second.inspectionID)
  }

  @Test
  func inventoryRevisionReloadsSameDigestInspectionMetadata() {
    let image = ImageRecord(
      reference: "example/app:latest",
      digest: "sha256:source",
      mediaType: "index",
      indexSizeBytes: 100
    )
    let first = ImageInspectionRefreshID(
      image: image,
      inventoryRevision: Date(timeIntervalSince1970: 1)
    )
    let second = ImageInspectionRefreshID(
      image: image,
      inventoryRevision: Date(timeIntervalSince1970: 2)
    )

    #expect(first != second)
  }

  @Test
  func inspectorLoadsRichImageDetails() async {
    let inspection = makeInspection()
    let service = TestImageService(inspection: inspection)
    let model = ImageInspectorModel(reference: inspection.reference, service: service)

    await model.load()

    #expect(model.inspection == inspection)
    #expect(model.errorMessage == nil)
    #expect(await service.inspectedReferences == [inspection.reference])
  }

  @Test
  func tagReviewRequiresExplicitReplacementAndRefreshes() async {
    let plan = ImageTagPlan(
      sourceReference: "example/app:latest",
      sourceDigest: "sha256:source",
      targetReference: "registry.example/app:release",
      displayTargetReference: "registry.example/app:release",
      replacedDigest: "sha256:other"
    )
    let service = TestImageService(tagPlan: plan)
    let refreshes = TestImageRefreshRecorder()
    let model = ImageOperationsModel(sourceReference: plan.sourceReference, service: service) {
      await refreshes.record()
    }

    let reviewed = await model.prepareTag(target: "registry.example/app:release")
    let succeeded = await model.applyTag(replacingExisting: true)

    #expect(reviewed?.replacesDifferentImage == true)
    #expect(succeeded)
    #expect(await service.tagCalls == [TestImageTagCall(plan: plan, replacingExisting: true)])
    #expect(await refreshes.count == 1)
  }

  @Test
  func inUseDeletionNeverCallsDestructiveServiceMethod() async {
    let plan = ImageDeletionPlan(
      reference: "example/app:latest",
      digest: "sha256:source",
      aliases: [],
      usedByContainerIDs: ["api"],
      isInfrastructureImage: false
    )
    let service = TestImageService(deletionPlan: plan)
    let model = ImageOperationsModel(sourceReference: plan.reference, service: service) {}

    _ = await model.prepareDeletion()
    let succeeded = await model.deleteReviewedImage()

    #expect(!succeeded)
    #expect(model.errorMessage?.contains("api") == true)
    #expect(await service.deletedPlans.isEmpty)
  }

  @Test
  func confirmedDeletionUsesCapturedPlanAfterDialogStateClears() async {
    let plan = ImageDeletionPlan(
      reference: "example/app:latest",
      digest: "sha256:source",
      aliases: [],
      usedByContainerIDs: [],
      isInfrastructureImage: false
    )
    let result = ImageCleanupResult(
      removedReferences: [plan.reference],
      failedReferences: [],
      removedBlobDigests: [],
      reclaimedBytes: 0
    )
    let service = TestImageService(deletionPlan: plan, cleanupResult: result)
    let model = ImageOperationsModel(sourceReference: plan.reference, service: service) {}

    _ = await model.prepareDeletion()
    model.clearPlans()
    let succeeded = await model.deleteReviewedImage(plan)

    #expect(succeeded)
    #expect(await service.deletedPlans == [plan])
  }

  @Test
  func pruneUsesReviewedCandidatesAndPublishesActualCleanup() async {
    let plan = ImagePrunePlan(
      mode: .allUnused,
      generatedAt: Date(),
      candidates: [
        ImagePruneCandidate(
          reference: "example/old:latest",
          digest: "sha256:old",
          indexSizeBytes: 512
        )
      ],
      estimatedReclaimableBytes: 10_000
    )
    let result = ImageCleanupResult(
      removedReferences: ["example/old:latest"],
      failedReferences: [],
      removedBlobDigests: ["sha256:blob"],
      reclaimedBytes: 9_500
    )
    let service = TestImageService(prunePlan: plan, cleanupResult: result)
    let refreshes = TestImageRefreshRecorder()
    let model = ImageOperationsModel(service: service) {
      await refreshes.record()
    }

    let reviewed = await model.preparePrune(mode: .allUnused)
    let succeeded = await model.pruneReviewedImages()

    #expect(reviewed == plan)
    #expect(succeeded)
    #expect(model.cleanupResult == result)
    #expect(await service.prunedPlans == [plan])
    #expect(await refreshes.count == 1)
  }
}

private func makeInspection() -> ImageInspection {
  ImageInspection(
    reference: "example/app:latest",
    displayReference: "example/app:latest",
    digest: "sha256:source",
    mediaType: "application/vnd.oci.image.index.v1+json",
    indexSizeBytes: 512,
    createdAt: Date(timeIntervalSince1970: 1_000),
    variants: [
      ImageVariantInspection(
        platform: "linux/arm64",
        os: "linux",
        architecture: "arm64",
        variant: nil,
        manifestDigest: "sha256:manifest",
        sizeBytes: 1_000,
        createdAt: Date(timeIntervalSince1970: 1_000),
        author: nil,
        user: "1000",
        workingDirectory: "/app",
        entrypoint: ["/app/server"],
        command: [],
        environment: ["PORT=8080"],
        labels: [:],
        layerCount: 2
      )
    ],
    aliases: [],
    usedByContainerIDs: [],
    warnings: []
  )
}

private struct TestImageTagCall: Equatable, Sendable {
  let plan: ImageTagPlan
  let replacingExisting: Bool
}

private actor TestImageService: ImageManaging {
  private let inspection: ImageInspection
  private let tagPlan: ImageTagPlan
  private let deletionPlan: ImageDeletionPlan
  private let prunePlan: ImagePrunePlan
  private let cleanupResult: ImageCleanupResult

  private(set) var inspectedReferences: [String] = []
  private(set) var tagCalls: [TestImageTagCall] = []
  private(set) var deletedPlans: [ImageDeletionPlan] = []
  private(set) var prunedPlans: [ImagePrunePlan] = []

  init(
    inspection: ImageInspection = makeInspection(),
    tagPlan: ImageTagPlan? = nil,
    deletionPlan: ImageDeletionPlan? = nil,
    prunePlan: ImagePrunePlan? = nil,
    cleanupResult: ImageCleanupResult? = nil
  ) {
    self.inspection = inspection
    self.tagPlan =
      tagPlan
      ?? ImageTagPlan(
        sourceReference: inspection.reference,
        sourceDigest: inspection.digest,
        targetReference: "example/app:other",
        displayTargetReference: "example/app:other",
        replacedDigest: nil
      )
    self.deletionPlan =
      deletionPlan
      ?? ImageDeletionPlan(
        reference: inspection.reference,
        digest: inspection.digest,
        aliases: inspection.aliases,
        usedByContainerIDs: inspection.usedByContainerIDs,
        isInfrastructureImage: false
      )
    self.prunePlan =
      prunePlan
      ?? ImagePrunePlan(
        mode: .dangling,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        candidates: [],
        estimatedReclaimableBytes: nil
      )
    self.cleanupResult =
      cleanupResult
      ?? ImageCleanupResult(
        removedReferences: [inspection.reference],
        failedReferences: [],
        removedBlobDigests: [],
        reclaimedBytes: 0
      )
  }

  func inspectImage(reference: String) async throws -> ImageInspection {
    inspectedReferences.append(reference)
    return inspection
  }

  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    tagPlan
  }

  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    tagCalls.append(TestImageTagCall(plan: plan, replacingExisting: replacingExisting))
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    deletionPlan
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    deletedPlans.append(plan)
    return cleanupResult
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    prunePlan
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    prunedPlans.append(plan)
    return cleanupResult
  }
}

private actor TestImageRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
