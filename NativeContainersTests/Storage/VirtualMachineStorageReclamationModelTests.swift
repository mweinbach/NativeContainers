import Foundation
import Testing

@testable import NativeContainers

@Suite("VM storage reclamation model")
@MainActor
struct VirtualMachineStorageReclamationModelTests {
  @Test
  func restoreImageCleanupIsAnExplicitOptInScope() {
    let fixture = VMReclamationModelFixture()
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { fixture.source }
    )

    #expect(model.reclaimRestoreImages == false)
    model.setReclaimSavedStates(false)
    model.setReclaimInterruptedResidue(false)
    #expect(model.hasSelectedScope == false)

    model.setReclaimRestoreImages(true)
    #expect(model.hasSelectedScope)
  }

  @Test
  func preparationStoresOnlyAPlanFromTheCurrentMeasurement() async {
    let fixture = VMReclamationModelFixture()
    var currentSource: VirtualMachineStorageReclamationSource? = fixture.source
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { currentSource }
    )

    let prepared = await model.prepare(fixture.plan.request)

    #expect(prepared == fixture.plan)
    #expect(model.plan == fixture.plan)
    #expect(model.errorMessage == nil)

    currentSource = fixture.newerSource
    let stale = await model.prepare(fixture.plan.request)
    #expect(stale == nil)
    #expect(model.plan == nil)
    #expect(
      model.errorMessage
        == VirtualMachineStorageReclamationError.staleSource.localizedDescription
    )
  }

  @Test
  func staleSourceBlocksExecutionBeforeTheServiceIsCalled() async {
    let fixture = VMReclamationModelFixture()
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { fixture.newerSource },
      plan: fixture.plan
    )

    #expect(await model.reclaimReviewedStorage() == false)
    #expect(await fixture.service.executionCount == 0)
    #expect(model.plan == nil)
  }

  @Test
  func acceptedMutationPublishesResultAndRefreshesOnce() async {
    let fixture = VMReclamationModelFixture()
    let recorder = VMReclamationMutationRecorder()
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { fixture.source },
      plan: fixture.plan
    ) {
      await recorder.record()
    }

    #expect(await model.reclaimReviewedStorage())
    #expect(model.result == fixture.result)
    #expect(model.plan == nil)
    #expect(await recorder.count == 1)
  }

  @Test
  func partialCompletionPreservesResultAndRefreshes() async {
    let fixture = VMReclamationModelFixture(execution: .partial)
    let recorder = VMReclamationMutationRecorder()
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { fixture.source },
      plan: fixture.plan
    ) {
      await recorder.record()
    }

    #expect(await model.reclaimReviewedStorage() == false)
    #expect(model.result == fixture.result)
    #expect(model.errorMessage?.contains("cancelled") == true)
    #expect(await recorder.count == 1)
  }

  @Test
  func discardDuringPreparationCancelsAndClearsReviewState() async {
    let fixture = VMReclamationModelFixture(preparationSuspends: true)
    let model = VirtualMachineStorageReclamationModel(
      service: fixture.service,
      currentSource: { fixture.source }
    )
    model.startPreparing()
    await fixture.service.waitUntilPreparationStarts()

    model.discardReview()
    await fixture.service.resumePreparation()
    await Task.yield()
    await Task.yield()

    #expect(model.plan == nil)
    #expect(model.result == nil)
  }
}

private struct VMReclamationModelFixture {
  enum Execution {
    case success
    case partial
  }

  let machineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  let source: VirtualMachineStorageReclamationSource
  let newerSource: VirtualMachineStorageReclamationSource
  let plan: VirtualMachineStorageReclamationPlan
  let result: VirtualMachineStorageReclamationResult
  let service: VMReclamationModelServiceDouble

  init(
    execution: Execution = .success,
    preparationSuspends: Bool = false
  ) {
    source = VirtualMachineStorageReclamationSource(
      capturedAt: Date(timeIntervalSince1970: 1),
      measurementRevision: 2,
      libraryRevision: 3,
      measuredSavedStateMachineIDs: [machineID]
    )
    newerSource = VirtualMachineStorageReclamationSource(
      capturedAt: Date(timeIntervalSince1970: 4),
      measurementRevision: 3,
      libraryRevision: 4,
      measuredSavedStateMachineIDs: [machineID]
    )
    let identity = VirtualMachineStorageArtifactIdentity(
      device: 1,
      inode: 2,
      fileType: .directory,
      ownerUserID: 501,
      linkCount: 2,
      logicalBytes: 10,
      allocatedBytes: 10,
      entryCount: 2,
      modificationSeconds: 3,
      modificationNanoseconds: 4,
      statusChangeSeconds: 5,
      statusChangeNanoseconds: 6,
      treeFingerprint: "tree"
    )
    let candidate = VirtualMachineSavedStateReclamationCandidate(
      machineID: machineID,
      machineName: "VM",
      createdAt: Date(timeIntervalSince1970: 5),
      stateSizeBytes: 10,
      configurationFingerprint: "configuration",
      artifactIdentity: identity
    )
    let request = VirtualMachineStorageReclamationRequest(
      source: source,
      reclaimInterruptedResidue: false
    )
    plan = VirtualMachineStorageReclamationPlan(
      request: request,
      generatedAt: Date(timeIntervalSince1970: 6),
      savedStatePlan: VirtualMachineSavedStateReclamationPlan(
        candidates: [candidate],
        issues: []
      ),
      residuePlan: nil
    )
    result = VirtualMachineStorageReclamationResult(
      savedStateResult: VirtualMachineStorageReclamationBatchResult(
        removedCandidateIDs: [candidate.id],
        staleCandidateIDs: [],
        failedCandidates: [],
        removedAllocatedBytes: 10
      ),
      residueResult: nil,
      categoryFailures: []
    )
    service = VMReclamationModelServiceDouble(
      plan: plan,
      result: result,
      partial: execution == .partial,
      preparationSuspends: preparationSuspends
    )
  }
}

private actor VMReclamationModelServiceDouble:
  VirtualMachineStorageReclamationManaging
{
  let plan: VirtualMachineStorageReclamationPlan
  let result: VirtualMachineStorageReclamationResult
  let partial: Bool
  let preparationSuspends: Bool
  private(set) var executionCount = 0
  private var preparationStarted = false
  private var preparationContinuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    plan: VirtualMachineStorageReclamationPlan,
    result: VirtualMachineStorageReclamationResult,
    partial: Bool,
    preparationSuspends: Bool
  ) {
    self.plan = plan
    self.result = result
    self.partial = partial
    self.preparationSuspends = preparationSuspends
  }

  func prepareVirtualMachineStorageReclamation(
    _ request: VirtualMachineStorageReclamationRequest
  ) async throws -> VirtualMachineStorageReclamationPlan {
    preparationStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if preparationSuspends {
      await withCheckedContinuation { continuation in
        preparationContinuation = continuation
      }
    }
    try Task.checkCancellation()
    return plan
  }

  func reclaimVirtualMachineStorage(
    _ plan: VirtualMachineStorageReclamationPlan
  ) throws -> VirtualMachineStorageReclamationResult {
    executionCount += 1
    if partial {
      throw VirtualMachineStorageReclamationPartialCompletionError(
        result: result,
        remainingCategories: [.savedStates]
      )
    }
    return result
  }

  func waitUntilPreparationStarts() async {
    guard !preparationStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resumePreparation() {
    preparationContinuation?.resume()
    preparationContinuation = nil
  }
}

private actor VMReclamationMutationRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
