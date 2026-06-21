import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Storage reclamation model")
struct StorageReclamationModelTests {
  @Test
  func remainsIdleUntilExplicitPreparation() async {
    let source = modelTestSource()
    let service = StorageReclamationServiceDouble(
      plan: modelTestPlan(source: source)
    )
    let model = StorageReclamationModel(
      service: service,
      currentSource: { source }
    )

    #expect(model.plan == nil)
    #expect(!model.isWorking)
    #expect(await service.prepareCount == 0)
    #expect(await service.reclaimCount == 0)
  }

  @Test
  func preparesAndPublishesExactPlan() async {
    let source = modelTestSource()
    let expected = modelTestPlan(source: source)
    let service = StorageReclamationServiceDouble(plan: expected)
    let model = StorageReclamationModel(
      service: service,
      currentSource: { source }
    )
    let request = expected.request

    let prepared = await model.prepare(request)

    #expect(prepared == expected)
    #expect(model.plan == expected)
    #expect(model.errorMessage == nil)
    #expect(await service.receivedRequests == [request])
  }

  @Test
  func staleAccountingOrInventorySourceRejectsExecution() async {
    let original = modelTestSource()
    let box = ReclamationSourceBox(source: original)
    let plan = modelTestPlan(source: original)
    let service = StorageReclamationServiceDouble(plan: plan)
    let model = StorageReclamationModel(
      service: service,
      currentSource: { box.source },
      plan: plan
    )
    box.source = StorageReclamationSource(
      appleRuntimeCapturedAt: original.appleRuntimeCapturedAt,
      appleRuntimeRevision: original.appleRuntimeRevision,
      inventoryRevision: original.inventoryRevision + 1,
      images: original.images,
      containers: original.containers,
      volumes: original.volumes
    )

    let completed = await model.reclaimReviewedStorage()

    #expect(!completed)
    #expect(model.plan == nil)
    #expect(
      model.errorMessage
        == StorageReclamationError.staleSource.localizedDescription
    )
    #expect(await service.reclaimCount == 0)
  }

  @Test
  func partialCompletionRetainsResultAndRunsPostMutationReconciliation() async {
    let source = modelTestSource()
    let plan = modelTestPlan(source: source)
    let partialResult = StorageReclamationResult(
      containerResult: nil,
      imageResult: ImageCleanupResult(
        removedReferences: ["old:image"],
        failedReferences: [
          ImageOperationFailure(
            reference: "remaining:image",
            message: "Cancelled"
          )
        ],
        removedBlobDigests: [],
        reclaimedBytes: 10
      ),
      volumeResult: nil,
      categoryFailures: []
    )
    let service = StorageReclamationServiceDouble(
      plan: plan,
      reclaimOutcome: .partial(partialResult)
    )
    let refresh = MutationRefreshRecorder()
    let model = StorageReclamationModel(
      service: service,
      currentSource: { source },
      plan: plan
    ) {
      await refresh.record()
    }

    let completed = await model.reclaimReviewedStorage()

    #expect(!completed)
    #expect(model.result == partialResult)
    #expect(model.plan == nil)
    #expect(model.errorMessage != nil)
    #expect(await refresh.count == 1)
  }

  @Test
  func cancelScanClearsLoadingWithoutPublishingAnError() async {
    let source = modelTestSource()
    let service = StorageReclamationServiceDouble(
      plan: modelTestPlan(source: source),
      blocksPreparation: true
    )
    let model = StorageReclamationModel(
      service: service,
      currentSource: { source }
    )
    model.startPreparing()
    while !(await service.prepareStarted) {
      await Task.yield()
    }

    model.cancelCurrentOperation()
    while model.isWorking {
      await Task.yield()
    }

    #expect(model.plan == nil)
    #expect(model.errorMessage == nil)
    #expect(!model.isCancelling)
    #expect(await service.observedPrepareCancellation)
  }

  @Test
  func scopeChangesDiscardAnUncommittedReview() {
    let source = modelTestSource()
    let plan = modelTestPlan(source: source)
    let model = StorageReclamationModel(
      service: StorageReclamationServiceDouble(plan: plan),
      currentSource: { source },
      plan: plan
    )

    model.setReclaimImages(false)

    #expect(model.plan == nil)
    #expect(!model.reclaimImages)
    #expect(model.reclaimVolumes)
  }
}

@MainActor
private final class ReclamationSourceBox {
  var source: StorageReclamationSource

  init(source: StorageReclamationSource) {
    self.source = source
  }
}

private enum ModelReclaimOutcome: Sendable {
  case success(StorageReclamationResult)
  case partial(StorageReclamationResult)
  case failure(String)
}

private actor StorageReclamationServiceDouble:
  StorageReclamationManaging
{
  let plan: StorageReclamationPlan
  let reclaimOutcome: ModelReclaimOutcome
  let blocksPreparation: Bool

  private(set) var receivedRequests: [StorageReclamationRequest] = []
  private(set) var prepareCount = 0
  private(set) var reclaimCount = 0
  private(set) var prepareStarted = false
  private(set) var observedPrepareCancellation = false

  init(
    plan: StorageReclamationPlan,
    reclaimOutcome: ModelReclaimOutcome = .success(.empty),
    blocksPreparation: Bool = false
  ) {
    self.plan = plan
    self.reclaimOutcome = reclaimOutcome
    self.blocksPreparation = blocksPreparation
  }

  func prepareStorageReclamation(
    _ request: StorageReclamationRequest
  ) async throws -> StorageReclamationPlan {
    prepareCount += 1
    prepareStarted = true
    receivedRequests.append(request)
    if blocksPreparation {
      do {
        try await Task.sleep(for: .seconds(60))
      } catch is CancellationError {
        observedPrepareCancellation = true
        throw CancellationError()
      }
    }
    return plan
  }

  func reclaimStorage(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult {
    reclaimCount += 1
    switch reclaimOutcome {
    case .success(let result):
      return result
    case .partial(let result):
      throw StorageReclamationPartialCompletionError(
        result: result,
        remainingCategories: [.images, .volumes]
      )
    case .failure(let message):
      throw ModelTestError(message: message)
    }
  }
}

private actor MutationRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private struct ModelTestError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private func modelTestSource() -> StorageReclamationSource {
  StorageReclamationSource(
    appleRuntimeCapturedAt: Date(timeIntervalSince1970: 1),
    appleRuntimeRevision: 1,
    inventoryRevision: 1,
    images: StorageResourceUsage(
      totalCount: 1,
      activeCount: 0,
      allocatedBytes: 100,
      reclaimableBytes: 100
    ),
    containers: StorageResourceUsage(
      totalCount: 0,
      activeCount: 0,
      allocatedBytes: 0,
      reclaimableBytes: 0
    ),
    volumes: StorageResourceUsage(
      totalCount: 0,
      activeCount: 0,
      allocatedBytes: 0,
      reclaimableBytes: 0
    )
  )
}

private func modelTestPlan(
  source: StorageReclamationSource
) -> StorageReclamationPlan {
  StorageReclamationPlan(
    request: StorageReclamationRequest(source: source),
    generatedAt: Date(timeIntervalSince1970: 2),
    containerPlan: nil,
    imagePlan: ImagePrunePlan(
      mode: .allUnused,
      generatedAt: Date(timeIntervalSince1970: 2),
      candidates: [
        ImagePruneCandidate(
          reference: "old:image",
          digest: "sha256:old",
          indexSizeBytes: 1
        )
      ],
      estimatedReclaimableBytes: 100
    ),
    volumePlan: VolumePrunePlan(
      candidates: [],
      generatedAt: Date(timeIntervalSince1970: 2)
    )
  )
}
