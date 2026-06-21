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
  func transferPlansDescribeExactPlatformAndConfirmationBoundaries() {
    let platform = OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    let plan = ImagePullPlan(
      normalizedReference: "registry.example/app:latest",
      registryHost: "registry.example",
      existingDigest: "sha256:old",
      platform: .all,
      requestedTransport: .automatic,
      resolvedTransport: .http,
      unpackAfterPull: true,
      maxConcurrentDownloads: 3,
      generatedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(platform.description == "linux/arm64/v8")
    #expect(ImagePlatformScope.specific(platform).description == "linux/arm64/v8")
    #expect(plan.requiresInsecureConfirmation)
    #expect(plan.replacesExistingReference)
    #expect(plan.requiresAllPlatformConfirmation)
  }

  @Test
  func pullExecutionSafetyRejectsTransportDriftStaleDigestAndInfrastructure() {
    let plan = makePullPlan(existingDigest: "sha256:reviewed")
    let authorization = ImagePullAuthorization(
      allowsInsecureTransport: true,
      allowsExistingReferenceReplacement: true,
      allowsAllPlatforms: false
    )

    #expect(throws: ImageManagementError.stalePlan("registry transport")) {
      try ImageTransferExecutionSafety.validatePull(
        plan: plan,
        authorization: authorization,
        resolvedRegistryHost: plan.registryHost,
        resolvedTransport: .http,
        currentDigest: plan.existingDigest,
        isInfrastructureImage: false
      )
    }
    #expect(throws: ImageManagementError.stalePlan("pull operation")) {
      try ImageTransferExecutionSafety.validatePull(
        plan: plan,
        authorization: authorization,
        resolvedRegistryHost: plan.registryHost,
        resolvedTransport: plan.resolvedTransport,
        currentDigest: "sha256:changed",
        isInfrastructureImage: false
      )
    }
    #expect(throws: ImageManagementError.infrastructureImage(plan.normalizedReference)) {
      try ImageTransferExecutionSafety.validatePull(
        plan: plan,
        authorization: authorization,
        resolvedRegistryHost: plan.registryHost,
        resolvedTransport: plan.resolvedTransport,
        currentDigest: plan.existingDigest,
        isInfrastructureImage: true
      )
    }
  }

  @Test
  func transferAuthorizationsFailClosed() {
    let pullPlan = ImagePullPlan(
      normalizedReference: "registry.example/app:latest",
      registryHost: "registry.example",
      existingDigest: "sha256:old",
      platform: .all,
      requestedTransport: .automatic,
      resolvedTransport: .http,
      unpackAfterPull: true,
      maxConcurrentDownloads: 3,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(
      throws: ImageManagementError.insecureTransportRequiresConfirmation(
        pullPlan.registryHost
      )
    ) {
      try ImageTransferExecutionSafety.validatePull(
        plan: pullPlan,
        authorization: .none,
        resolvedRegistryHost: pullPlan.registryHost,
        resolvedTransport: pullPlan.resolvedTransport,
        currentDigest: pullPlan.existingDigest,
        isInfrastructureImage: false
      )
    }
    #expect(throws: ImageManagementError.pullWouldReplace(pullPlan.normalizedReference)) {
      try ImageTransferExecutionSafety.validatePull(
        plan: pullPlan,
        authorization: ImagePullAuthorization(
          allowsInsecureTransport: true,
          allowsExistingReferenceReplacement: false,
          allowsAllPlatforms: false
        ),
        resolvedRegistryHost: pullPlan.registryHost,
        resolvedTransport: pullPlan.resolvedTransport,
        currentDigest: pullPlan.existingDigest,
        isInfrastructureImage: false
      )
    }
    #expect(throws: ImageManagementError.allPlatformPullRequiresConfirmation) {
      try ImageTransferExecutionSafety.validatePull(
        plan: pullPlan,
        authorization: ImagePullAuthorization(
          allowsInsecureTransport: true,
          allowsExistingReferenceReplacement: true,
          allowsAllPlatforms: false
        ),
        resolvedRegistryHost: pullPlan.registryHost,
        resolvedTransport: pullPlan.resolvedTransport,
        currentDigest: pullPlan.existingDigest,
        isInfrastructureImage: false
      )
    }

    let pushPlan = makePushPlan(resolvedTransport: .https)
    #expect(
      throws: ImageManagementError.remoteTagReplacementRequiresConfirmation(
        pushPlan.reference
      )
    ) {
      try ImageTransferExecutionSafety.validatePush(
        plan: pushPlan,
        authorization: .none,
        resolvedRegistryHost: pushPlan.registryHost,
        resolvedTransport: pushPlan.resolvedTransport,
        currentDigest: pushPlan.sourceDigest,
        isInfrastructureImage: false
      )
    }
    let insecurePushPlan = makePushPlan(resolvedTransport: .http)
    #expect(
      throws: ImageManagementError.insecureTransportRequiresConfirmation(
        insecurePushPlan.registryHost
      )
    ) {
      try ImageTransferExecutionSafety.validatePush(
        plan: insecurePushPlan,
        authorization: ImagePushAuthorization(
          allowsInsecureTransport: false,
          confirmsRemoteTagReplacement: true
        ),
        resolvedRegistryHost: insecurePushPlan.registryHost,
        resolvedTransport: insecurePushPlan.resolvedTransport,
        currentDigest: insecurePushPlan.sourceDigest,
        isInfrastructureImage: false
      )
    }
  }

  @Test
  func exactPushPlatformMustBePresent() {
    let requested = OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    let available = [OCIPlatformValue(os: "linux", architecture: "amd64", variant: nil)]

    #expect(
      throws: ImageManagementError.platformUnavailable(
        platform: requested.description,
        reference: "registry.example/app:latest"
      )
    ) {
      try ImageTransferExecutionSafety.validatePlatform(
        requested,
        available: available,
        reference: "registry.example/app:latest"
      )
    }
  }

  @Test
  func unpackOutcomeOnlyClaimsVerifiedCompleteSnapshots() {
    let arm64 = OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    let amd64 = OCIPlatformValue(os: "linux", architecture: "amd64", variant: nil)
    let complete = ImageUnpackOutcome(
      platforms: [
        ImagePlatformUnpackOutcome(platform: arm64, state: .alreadyPresent),
        ImagePlatformUnpackOutcome(platform: amd64, state: .created),
      ]
    )
    let partial = ImageUnpackOutcome(
      platforms: [
        ImagePlatformUnpackOutcome(platform: arm64, state: .created),
        ImagePlatformUnpackOutcome(platform: amd64, state: .failed("No unpacker")),
      ]
    )

    #expect(complete.isComplete)
    #expect(!partial.isComplete)
    #expect(!ImageUnpackOutcome(platforms: []).isComplete)
  }

  @Test
  func runtimeMutationCoordinatorSerializesSuspendingOperations() async throws {
    let coordinator = RuntimeMutationCoordinator()
    let probe = MutationProbe()

    let first = Task {
      try await coordinator.perform {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(30))
        await probe.leave()
      }
    }
    let second = Task {
      try await coordinator.perform {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(10))
        await probe.leave()
      }
    }

    try await first.value
    try await second.value
    #expect(await probe.maximumConcurrentOperations == 1)
    #expect(await probe.completedOperations == 2)
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
  func pushUsesCapturedReviewedAliasAndPublishesProgress() async {
    let plan = ImagePushPlan(
      reference: "ghcr.io/example/app:release",
      displayReference: "ghcr.io/example/app:release",
      sourceDigest: "sha256:source",
      registryHost: "ghcr.io",
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: .automatic,
      resolvedTransport: .https,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    let authorization = ImagePushAuthorization(
      allowsInsecureTransport: false,
      confirmsRemoteTagReplacement: true
    )
    let service = TestImageService(pushPlan: plan)
    let refreshes = TestImageRefreshRecorder()
    let model = ImageOperationsModel(sourceReference: plan.reference, service: service) {
      await refreshes.record()
    }

    _ = await model.preparePush(platform: .current, transport: .automatic)
    model.clearPlans()
    let succeeded = await model.pushReviewedImage(plan, authorization: authorization)

    #expect(succeeded)
    #expect(model.progress?.phase == .completed)
    #expect(
      await service.pushCalls == [TestImagePushCall(plan: plan, authorization: authorization)])
    #expect(await refreshes.count == 1)
  }

  @Test
  func cancelledPushWarnsThatRemoteStateIsUncertain() async {
    let plan = makePushPlan(resolvedTransport: .https)
    let service = TestImageService(pushPlan: plan, pushError: CancellationError())
    let refreshes = TestImageRefreshRecorder()
    let model = ImageOperationsModel(sourceReference: plan.reference, service: service) {
      await refreshes.record()
    }

    let succeeded = await model.pushReviewedImage(
      plan,
      authorization: ImagePushAuthorization(
        allowsInsecureTransport: false,
        confirmsRemoteTagReplacement: true
      )
    )

    #expect(!succeeded)
    #expect(model.errorMessage?.contains("remote tag may already have changed") == true)
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

private func makePullPlan(existingDigest: String?) -> ImagePullPlan {
  ImagePullPlan(
    normalizedReference: "registry.example/app:latest",
    registryHost: "registry.example",
    existingDigest: existingDigest,
    platform: .specific(
      OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    ),
    requestedTransport: .automatic,
    resolvedTransport: .https,
    unpackAfterPull: true,
    maxConcurrentDownloads: 3,
    generatedAt: Date(timeIntervalSince1970: 1)
  )
}

private func makePushPlan(resolvedTransport: RegistryTransport) -> ImagePushPlan {
  ImagePushPlan(
    reference: "registry.example/app:latest",
    displayReference: "registry.example/app:latest",
    sourceDigest: "sha256:source",
    registryHost: "registry.example",
    platform: .specific(
      OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    ),
    requestedTransport: .automatic,
    resolvedTransport: resolvedTransport,
    generatedAt: Date(timeIntervalSince1970: 1)
  )
}

private struct TestImageTagCall: Equatable, Sendable {
  let plan: ImageTagPlan
  let replacingExisting: Bool
}

private struct TestImagePushCall: Equatable, Sendable {
  let plan: ImagePushPlan
  let authorization: ImagePushAuthorization
}

private actor TestImageService: ImageManaging {
  private let inspection: ImageInspection
  private let tagPlan: ImageTagPlan
  private let deletionPlan: ImageDeletionPlan
  private let prunePlan: ImagePrunePlan
  private let cleanupResult: ImageCleanupResult
  private let pushPlan: ImagePushPlan
  private let pushError: (any Error)?

  private(set) var inspectedReferences: [String] = []
  private(set) var tagCalls: [TestImageTagCall] = []
  private(set) var deletedPlans: [ImageDeletionPlan] = []
  private(set) var prunedPlans: [ImagePrunePlan] = []
  private(set) var pushCalls: [TestImagePushCall] = []

  init(
    inspection: ImageInspection = makeInspection(),
    tagPlan: ImageTagPlan? = nil,
    deletionPlan: ImageDeletionPlan? = nil,
    prunePlan: ImagePrunePlan? = nil,
    cleanupResult: ImageCleanupResult? = nil,
    pushPlan: ImagePushPlan? = nil,
    pushError: (any Error)? = nil
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
    self.pushPlan =
      pushPlan
      ?? ImagePushPlan(
        reference: inspection.reference,
        displayReference: inspection.displayReference,
        sourceDigest: inspection.digest,
        registryHost: "example",
        platform: .all,
        requestedTransport: .https,
        resolvedTransport: .https,
        generatedAt: Date(timeIntervalSince1970: 1)
      )
    self.pushError = pushError
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

  func prepareImagePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    pushPlan
  }

  func pushImage(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    pushCalls.append(TestImagePushCall(plan: plan, authorization: authorization))
    await progress(ContainerOperationProgress(phase: .pushingImage, message: "Pushing"))
    if let pushError { throw pushError }
    await progress(ContainerOperationProgress(phase: .completed, message: "Image pushed"))
  }
}

private actor TestImageRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private actor MutationProbe {
  private var activeOperations = 0
  private(set) var maximumConcurrentOperations = 0
  private(set) var completedOperations = 0

  func enter() {
    activeOperations += 1
    maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
  }

  func leave() {
    activeOperations -= 1
    completedOperations += 1
  }
}
