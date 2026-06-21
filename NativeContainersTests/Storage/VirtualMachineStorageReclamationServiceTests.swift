import Foundation
import Testing

@testable import NativeContainers

@Suite("VM storage reclamation service")
struct VirtualMachineStorageReclamationServiceTests {
  @Test
  func composesSelectedServicePlansWithMeasurementProvenance() async throws {
    let fixture = VMReclamationServiceFixture()
    let request = VirtualMachineStorageReclamationRequest(
      source: fixture.source
    )

    let plan = try await fixture.service
      .prepareVirtualMachineStorageReclamation(request)

    #expect(plan.request == request)
    #expect(plan.generatedAt == Date(timeIntervalSince1970: 99))
    #expect(plan.savedStatePlan == fixture.savedStatePlan)
    #expect(plan.residuePlan == fixture.residuePlan)
  }

  @Test
  func executesReviewedCategoriesInDeterministicOrder() async throws {
    let fixture = VMReclamationServiceFixture()
    let plan = try await fixture.service.prepareVirtualMachineStorageReclamation(
      VirtualMachineStorageReclamationRequest(source: fixture.source)
    )

    let result = try await fixture.service.reclaimVirtualMachineStorage(plan)

    #expect(await fixture.double.events == ["saved-states", "residue"])
    #expect(result.removedCandidateCount == 2)
    #expect(result.removedAllocatedBytes == 30)
  }

  @Test
  func optInRestoreImagesExecuteAfterBundleScopedCategories() async throws {
    let fixture = VMReclamationServiceFixture()
    let plan = try await fixture.service.prepareVirtualMachineStorageReclamation(
      VirtualMachineStorageReclamationRequest(
        source: fixture.source,
        reclaimRestoreImages: true
      )
    )

    let result = try await fixture.service.reclaimVirtualMachineStorage(plan)

    #expect(plan.restoreImagePlan == fixture.restoreImagePlan)
    #expect(await fixture.double.events == ["saved-states", "residue", "restore-images"])
    #expect(result.removedCandidateCount == 3)
    #expect(result.restoreImageResult?.removedCandidateIDs == [fixture.restoreImageCandidate.id])
  }

  @Test
  func categoryFailureDoesNotExpandOrBlockTheLaterReviewedPlan() async throws {
    let fixture = VMReclamationServiceFixture(savedStateFailure: "busy")
    let plan = try await fixture.service.prepareVirtualMachineStorageReclamation(
      VirtualMachineStorageReclamationRequest(source: fixture.source)
    )

    let result = try await fixture.service.reclaimVirtualMachineStorage(plan)

    #expect(await fixture.double.events == ["saved-states", "residue"])
    #expect(result.savedStateResult == nil)
    #expect(result.residueResult?.removedCandidateIDs == [fixture.residueCandidate.id])
    #expect(result.categoryFailures.map(\.category) == [.savedStates])
  }

  @Test
  func partialCancellationPreservesCommittedResultsAndSkipsResidue() async throws {
    let partial = VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: ["saved-state:committed"],
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: 8
    )
    let fixture = VMReclamationServiceFixture(savedStatePartial: partial)
    let plan = try await fixture.service.prepareVirtualMachineStorageReclamation(
      VirtualMachineStorageReclamationRequest(source: fixture.source)
    )

    do {
      _ = try await fixture.service.reclaimVirtualMachineStorage(plan)
      Issue.record("Expected partial completion")
    } catch let error as VirtualMachineStorageReclamationPartialCompletionError {
      #expect(error.result.savedStateResult == partial)
      #expect(error.remainingCategories == [.savedStates, .interruptedResidue])
    }

    #expect(await fixture.double.events == ["saved-states"])
  }

  @Test
  func rejectsEmptyScopeAndCandidateExpansion() async throws {
    let fixture = VMReclamationServiceFixture()
    await #expect(throws: VirtualMachineStorageReclamationError.emptyScope) {
      try await fixture.service.prepareVirtualMachineStorageReclamation(
        VirtualMachineStorageReclamationRequest(
          source: fixture.source,
          savedStateMachineIDs: [],
          reclaimInterruptedResidue: false
        )
      )
    }

    let expanded = VirtualMachineStorageReclamationPlan(
      request: VirtualMachineStorageReclamationRequest(
        source: fixture.source,
        savedStateMachineIDs: []
      ),
      generatedAt: .now,
      savedStatePlan: nil,
      residuePlan: VirtualMachineStorageResidueReclamationPlan(
        candidates: [
          fixture.residueCandidate,
          VirtualMachineStorageResidueCandidate(
            id: fixture.residueCandidate.id,
            kind: .cloneStaging,
            entryName: ".Clone-extra.partial",
            machineID: nil,
            machineName: nil,
            manifestFingerprint: nil,
            artifactIdentity: fixture.identity
          ),
        ],
        issues: []
      )
    )

    await #expect(throws: VirtualMachineStorageReclamationError.invalidPlan) {
      try await fixture.service.reclaimVirtualMachineStorage(expanded)
    }
  }
}

private struct VMReclamationServiceFixture {
  let machineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
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
    treeFingerprint: "fingerprint"
  )
  let source: VirtualMachineStorageReclamationSource
  let savedStateCandidate: VirtualMachineSavedStateReclamationCandidate
  let residueCandidate: VirtualMachineStorageResidueCandidate
  let savedStatePlan: VirtualMachineSavedStateReclamationPlan
  let residuePlan: VirtualMachineStorageResidueReclamationPlan
  let restoreImageCandidate: RestoreImageCacheReclamationCandidate
  let restoreImagePlan: RestoreImageCacheReclamationPlan
  let double: VMReclamationCategoryDouble
  let service: VirtualMachineStorageReclamationService

  init(
    savedStateFailure: String? = nil,
    savedStatePartial: VirtualMachineStorageReclamationBatchResult? = nil
  ) {
    source = VirtualMachineStorageReclamationSource(
      capturedAt: Date(timeIntervalSince1970: 1),
      measurementRevision: 2,
      libraryRevision: 3,
      measuredSavedStateMachineIDs: [machineID]
    )
    savedStateCandidate = VirtualMachineSavedStateReclamationCandidate(
      machineID: machineID,
      machineName: "Build VM",
      createdAt: Date(timeIntervalSince1970: 4),
      stateSizeBytes: 10,
      configurationFingerprint: "configuration",
      artifactIdentity: identity
    )
    residueCandidate = VirtualMachineStorageResidueCandidate(
      id: VirtualMachineStorageResidueCandidate.libraryID(
        entryName: ".Clone-review.partial"
      ),
      kind: .cloneStaging,
      entryName: ".Clone-review.partial",
      machineID: nil,
      machineName: nil,
      manifestFingerprint: nil,
      artifactIdentity: VirtualMachineStorageArtifactIdentity(
        device: 1,
        inode: 7,
        fileType: .directory,
        ownerUserID: 501,
        linkCount: 2,
        logicalBytes: 20,
        allocatedBytes: 20,
        entryCount: 1,
        modificationSeconds: 3,
        modificationNanoseconds: 4,
        statusChangeSeconds: 5,
        statusChangeNanoseconds: 6,
        treeFingerprint: "residue"
      )
    )
    savedStatePlan = VirtualMachineSavedStateReclamationPlan(
      candidates: [savedStateCandidate],
      issues: []
    )
    residuePlan = VirtualMachineStorageResidueReclamationPlan(
      candidates: [residueCandidate],
      issues: []
    )
    let restoreIdentity = VirtualMachineStorageArtifactIdentity(
      device: 1,
      inode: 9,
      fileType: .regularFile,
      ownerUserID: 501,
      linkCount: 1,
      logicalBytes: 30,
      allocatedBytes: 30,
      entryCount: 1,
      modificationSeconds: 3,
      modificationNanoseconds: 4,
      statusChangeSeconds: 5,
      statusChangeNanoseconds: 6,
      treeFingerprint: "restore"
    )
    restoreImageCandidate = RestoreImageCacheReclamationCandidate(
      entryName: "Restore.ipsw",
      kind: .completedImage,
      modifiedAt: Date(timeIntervalSince1970: 3),
      artifactIdentity: restoreIdentity
    )
    restoreImagePlan = RestoreImageCacheReclamationPlan(
      candidates: [restoreImageCandidate],
      issues: []
    )
    double = VMReclamationCategoryDouble(
      savedStatePlan: savedStatePlan,
      residuePlan: residuePlan,
      restoreImagePlan: restoreImagePlan,
      savedStateFailure: savedStateFailure,
      savedStatePartial: savedStatePartial
    )
    service = VirtualMachineStorageReclamationService(
      savedStates: double,
      residue: double,
      restoreImages: double,
      now: { Date(timeIntervalSince1970: 99) }
    )
  }
}

private actor VMReclamationCategoryDouble:
  VirtualMachineSavedStateStorageReclaiming,
  VirtualMachineInterruptedResidueReclaiming,
  RestoreImageCacheStorageReclaiming
{
  let savedStatePlan: VirtualMachineSavedStateReclamationPlan
  let residuePlan: VirtualMachineStorageResidueReclamationPlan
  let restoreImagePlan: RestoreImageCacheReclamationPlan
  let savedStateFailure: String?
  let savedStatePartial: VirtualMachineStorageReclamationBatchResult?
  private(set) var events: [String] = []

  init(
    savedStatePlan: VirtualMachineSavedStateReclamationPlan,
    residuePlan: VirtualMachineStorageResidueReclamationPlan,
    restoreImagePlan: RestoreImageCacheReclamationPlan,
    savedStateFailure: String?,
    savedStatePartial: VirtualMachineStorageReclamationBatchResult?
  ) {
    self.savedStatePlan = savedStatePlan
    self.residuePlan = residuePlan
    self.restoreImagePlan = restoreImagePlan
    self.savedStateFailure = savedStateFailure
    self.savedStatePartial = savedStatePartial
  }

  func prepareSavedStateReclamation(
    machineIDs: Set<UUID>
  ) -> VirtualMachineSavedStateReclamationPlan {
    savedStatePlan
  }

  func prepareInterruptedResidueReclamation()
    -> VirtualMachineStorageResidueReclamationPlan
  {
    residuePlan
  }

  func prepareRestoreImageReclamation() -> RestoreImageCacheReclamationPlan {
    restoreImagePlan
  }

  func reclaimSavedStates(
    _ plan: VirtualMachineSavedStateReclamationPlan
  ) throws -> VirtualMachineStorageReclamationBatchResult {
    events.append("saved-states")
    if let savedStatePartial {
      throw VirtualMachineStorageReclamationBatchPartialCompletionError(
        result: savedStatePartial,
        remainingCandidateIDs: plan.candidates.map(\.id)
      )
    }
    if let savedStateFailure {
      throw TestError(message: savedStateFailure)
    }
    return VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: plan.candidates.map(\.id),
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: StorageByteMath.saturatingSum(
        plan.candidates.map(\.estimatedAllocatedBytes)
      )
    )
  }

  func reclaimInterruptedResidue(
    _ plan: VirtualMachineStorageResidueReclamationPlan
  ) -> VirtualMachineStorageReclamationBatchResult {
    events.append("residue")
    return VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: plan.candidates.map(\.id),
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: StorageByteMath.saturatingSum(
        plan.candidates.map(\.estimatedAllocatedBytes)
      )
    )
  }

  func reclaimRestoreImages(
    _ plan: RestoreImageCacheReclamationPlan
  ) -> VirtualMachineStorageReclamationBatchResult {
    events.append("restore-images")
    return VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: plan.candidates.map(\.id),
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: StorageByteMath.saturatingSum(
        plan.candidates.map(\.estimatedAllocatedBytes)
      )
    )
  }
}

private struct TestError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
