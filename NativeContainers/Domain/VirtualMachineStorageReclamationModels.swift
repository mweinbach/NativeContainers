import Foundation

struct VirtualMachineStorageReclamationSource: Equatable, Sendable {
  let capturedAt: Date
  let measurementRevision: UInt64
  let libraryRevision: UInt64
  let measuredSavedStateMachineIDs: Set<UUID>
}

struct VirtualMachineStorageReclamationRequest: Equatable, Sendable {
  let source: VirtualMachineStorageReclamationSource
  let savedStateMachineIDs: Set<UUID>
  let reclaimInterruptedResidue: Bool
  let reclaimRestoreImages: Bool

  init(
    source: VirtualMachineStorageReclamationSource,
    savedStateMachineIDs: Set<UUID>? = nil,
    reclaimInterruptedResidue: Bool = true,
    reclaimRestoreImages: Bool = false
  ) {
    self.source = source
    self.savedStateMachineIDs =
      savedStateMachineIDs ?? source.measuredSavedStateMachineIDs
    self.reclaimInterruptedResidue = reclaimInterruptedResidue
    self.reclaimRestoreImages = reclaimRestoreImages
  }

  var categories: [VirtualMachineStorageReclamationCategory] {
    var categories: [VirtualMachineStorageReclamationCategory] = []
    if !savedStateMachineIDs.isEmpty {
      categories.append(.savedStates)
    }
    if reclaimInterruptedResidue {
      categories.append(.interruptedResidue)
    }
    if reclaimRestoreImages {
      categories.append(.restoreImages)
    }
    return categories
  }
}

enum VirtualMachineStorageReclamationCategory:
  String,
  CaseIterable,
  Equatable,
  Sendable,
  Identifiable
{
  case savedStates
  case interruptedResidue
  case restoreImages

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .savedStates:
      "Saved states"
    case .interruptedResidue:
      "Interrupted-operation residue"
    case .restoreImages:
      "Downloaded restore images"
    }
  }
}

enum VirtualMachineStorageArtifactFileType: String, Equatable, Sendable {
  case regularFile
  case directory
}

struct VirtualMachineStorageArtifactIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let fileType: VirtualMachineStorageArtifactFileType
  let ownerUserID: UInt32
  let linkCount: UInt64
  let logicalBytes: UInt64
  let allocatedBytes: UInt64
  let entryCount: Int
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let statusChangeSeconds: Int64
  let statusChangeNanoseconds: Int64
  let treeFingerprint: String
}

struct VirtualMachineSavedStateReclamationCandidate:
  Equatable,
  Sendable,
  Identifiable
{
  var id: String { "saved-state:\(machineID.uuidString.lowercased())" }

  let machineID: UUID
  let machineName: String
  let createdAt: Date
  let stateSizeBytes: UInt64
  let configurationFingerprint: String
  let artifactIdentity: VirtualMachineStorageArtifactIdentity

  var estimatedAllocatedBytes: UInt64 {
    artifactIdentity.allocatedBytes
  }
}

enum VirtualMachineStorageResidueKind: String, Equatable, Sendable {
  case deletionTombstone
  case cloneStaging
  case importStaging
  case draftStaging
  case installationStaging
  case platformStaging
  case savedStateTransaction
  case sharedDirectoriesStaging
  case orphanedInstalledMedia

  var title: LocalizedStringResource {
    switch self {
    case .deletionTombstone:
      "Interrupted deletion"
    case .cloneStaging:
      "Interrupted clone"
    case .importStaging:
      "Interrupted import"
    case .draftStaging:
      "Interrupted draft creation"
    case .installationStaging:
      "Interrupted installation"
    case .platformStaging:
      "Interrupted platform preparation"
    case .savedStateTransaction:
      "Interrupted saved-state operation"
    case .sharedDirectoriesStaging:
      "Interrupted shared-folder update"
    case .orphanedInstalledMedia:
      "Orphaned installation media"
    }
  }
}

struct VirtualMachineStorageResidueCandidate:
  Equatable,
  Sendable,
  Identifiable
{
  let id: String
  let kind: VirtualMachineStorageResidueKind
  let entryName: String
  let machineID: UUID?
  let machineName: String?
  let manifestFingerprint: String?
  let artifactIdentity: VirtualMachineStorageArtifactIdentity

  var estimatedAllocatedBytes: UInt64 {
    artifactIdentity.allocatedBytes
  }

  static func libraryID(entryName: String) -> String {
    "library-residue:\(entryName)"
  }

  static func machineID(machineID: UUID, entryName: String) -> String {
    "machine-residue:\(machineID.uuidString.lowercased()):\(entryName)"
  }
}

struct VirtualMachineStorageReclamationPlanningIssue:
  Equatable,
  Sendable,
  Identifiable
{
  let id: String
  let category: VirtualMachineStorageReclamationCategory
  let machineID: UUID?
  let message: String
}

struct VirtualMachineSavedStateReclamationPlan: Equatable, Sendable {
  let candidates: [VirtualMachineSavedStateReclamationCandidate]
  let issues: [VirtualMachineStorageReclamationPlanningIssue]
}

struct VirtualMachineStorageResidueReclamationPlan: Equatable, Sendable {
  let candidates: [VirtualMachineStorageResidueCandidate]
  let issues: [VirtualMachineStorageReclamationPlanningIssue]
}

enum RestoreImageCacheReclamationKind: String, Equatable, Sendable {
  case completedImage
  case abandonedPartial

  var title: LocalizedStringResource {
    switch self {
    case .completedImage:
      "Downloaded restore image"
    case .abandonedPartial:
      "Abandoned partial download"
    }
  }
}

struct RestoreImageCacheReclamationCandidate:
  Equatable,
  Sendable,
  Identifiable
{
  let entryName: String
  let kind: RestoreImageCacheReclamationKind
  let modifiedAt: Date
  let artifactIdentity: VirtualMachineStorageArtifactIdentity

  var id: String { "restore-image:\(kind.rawValue):\(entryName)" }

  var estimatedAllocatedBytes: UInt64 {
    artifactIdentity.allocatedBytes
  }
}

struct RestoreImageCacheReclamationPlan: Equatable, Sendable {
  let candidates: [RestoreImageCacheReclamationCandidate]
  let issues: [VirtualMachineStorageReclamationPlanningIssue]
}

struct VirtualMachineStorageReclamationPlan: Equatable, Sendable {
  let request: VirtualMachineStorageReclamationRequest
  let generatedAt: Date
  let savedStatePlan: VirtualMachineSavedStateReclamationPlan?
  let residuePlan: VirtualMachineStorageResidueReclamationPlan?
  let restoreImagePlan: RestoreImageCacheReclamationPlan?

  init(
    request: VirtualMachineStorageReclamationRequest,
    generatedAt: Date,
    savedStatePlan: VirtualMachineSavedStateReclamationPlan?,
    residuePlan: VirtualMachineStorageResidueReclamationPlan?,
    restoreImagePlan: RestoreImageCacheReclamationPlan? = nil
  ) {
    self.request = request
    self.generatedAt = generatedAt
    self.savedStatePlan = savedStatePlan
    self.residuePlan = residuePlan
    self.restoreImagePlan = restoreImagePlan
  }

  var candidateCount: Int {
    (savedStatePlan?.candidates.count ?? 0)
      + (residuePlan?.candidates.count ?? 0)
      + (restoreImagePlan?.candidates.count ?? 0)
  }

  var isEmpty: Bool {
    candidateCount == 0
  }

  var estimatedAllocatedBytes: UInt64 {
    StorageByteMath.saturatingSum(
      (savedStatePlan?.candidates.map(\.estimatedAllocatedBytes) ?? [])
        + (residuePlan?.candidates.map(\.estimatedAllocatedBytes) ?? [])
        + (restoreImagePlan?.candidates.map(\.estimatedAllocatedBytes) ?? [])
    )
  }

  var issues: [VirtualMachineStorageReclamationPlanningIssue] {
    (savedStatePlan?.issues ?? [])
      + (residuePlan?.issues ?? [])
      + (restoreImagePlan?.issues ?? [])
  }

  var categories: [VirtualMachineStorageReclamationCategory] {
    request.categories
  }
}

struct VirtualMachineStorageReclamationCandidateFailure:
  Equatable,
  Sendable,
  Identifiable
{
  let candidateID: String
  let message: String

  var id: String { candidateID }
}

struct VirtualMachineStorageReclamationBatchResult: Equatable, Sendable {
  let removedCandidateIDs: [String]
  let staleCandidateIDs: [String]
  let failedCandidates: [VirtualMachineStorageReclamationCandidateFailure]
  let removedAllocatedBytes: UInt64

  static let empty = VirtualMachineStorageReclamationBatchResult(
    removedCandidateIDs: [],
    staleCandidateIDs: [],
    failedCandidates: [],
    removedAllocatedBytes: 0
  )

  func merging(
    _ other: VirtualMachineStorageReclamationBatchResult
  ) -> VirtualMachineStorageReclamationBatchResult {
    VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: removedCandidateIDs + other.removedCandidateIDs,
      staleCandidateIDs: staleCandidateIDs + other.staleCandidateIDs,
      failedCandidates: failedCandidates + other.failedCandidates,
      removedAllocatedBytes: StorageByteMath.saturatingSum([
        removedAllocatedBytes,
        other.removedAllocatedBytes,
      ])
    )
  }
}

struct VirtualMachineStorageReclamationCategoryFailure:
  Equatable,
  Sendable,
  Identifiable
{
  let category: VirtualMachineStorageReclamationCategory
  let message: String

  var id: VirtualMachineStorageReclamationCategory { category }
}

struct VirtualMachineStorageReclamationResult: Equatable, Sendable {
  let savedStateResult: VirtualMachineStorageReclamationBatchResult?
  let residueResult: VirtualMachineStorageReclamationBatchResult?
  let restoreImageResult: VirtualMachineStorageReclamationBatchResult?
  let categoryFailures: [VirtualMachineStorageReclamationCategoryFailure]

  init(
    savedStateResult: VirtualMachineStorageReclamationBatchResult?,
    residueResult: VirtualMachineStorageReclamationBatchResult?,
    restoreImageResult: VirtualMachineStorageReclamationBatchResult? = nil,
    categoryFailures: [VirtualMachineStorageReclamationCategoryFailure]
  ) {
    self.savedStateResult = savedStateResult
    self.residueResult = residueResult
    self.restoreImageResult = restoreImageResult
    self.categoryFailures = categoryFailures
  }

  static let empty = VirtualMachineStorageReclamationResult(
    savedStateResult: nil,
    residueResult: nil,
    restoreImageResult: nil,
    categoryFailures: []
  )

  var removedCandidateCount: Int {
    (savedStateResult?.removedCandidateIDs.count ?? 0)
      + (residueResult?.removedCandidateIDs.count ?? 0)
      + (restoreImageResult?.removedCandidateIDs.count ?? 0)
  }

  var staleCandidateCount: Int {
    (savedStateResult?.staleCandidateIDs.count ?? 0)
      + (residueResult?.staleCandidateIDs.count ?? 0)
      + (restoreImageResult?.staleCandidateIDs.count ?? 0)
  }

  var failedCandidateCount: Int {
    (savedStateResult?.failedCandidates.count ?? 0)
      + (residueResult?.failedCandidates.count ?? 0)
      + (restoreImageResult?.failedCandidates.count ?? 0)
      + categoryFailures.count
  }

  var removedAllocatedBytes: UInt64 {
    StorageByteMath.saturatingSum([
      savedStateResult?.removedAllocatedBytes ?? 0,
      residueResult?.removedAllocatedBytes ?? 0,
      restoreImageResult?.removedAllocatedBytes ?? 0,
    ])
  }

  var hasRecordedWork: Bool {
    savedStateResult != nil || residueResult != nil
      || restoreImageResult != nil || !categoryFailures.isEmpty
  }
}

struct VirtualMachineStorageReclamationBatchPartialCompletionError:
  LocalizedError,
  Sendable
{
  let result: VirtualMachineStorageReclamationBatchResult
  let remainingCandidateIDs: [String]

  var errorDescription: String? {
    "VM storage reclamation was cancelled after removing \(result.removedCandidateIDs.count) reviewed item(s)."
  }
}

struct VirtualMachineStorageReclamationPartialCompletionError:
  LocalizedError,
  Sendable
{
  let result: VirtualMachineStorageReclamationResult
  let remainingCategories: [VirtualMachineStorageReclamationCategory]

  var errorDescription: String? {
    "VM storage reclamation was cancelled after removing \(result.removedCandidateCount) reviewed item(s). Review remaining items again before retrying."
  }
}

enum VirtualMachineStorageReclamationError:
  LocalizedError,
  Equatable,
  Sendable
{
  case emptyScope
  case invalidPlan
  case measurementRequired
  case staleSource
  case libraryInUse
  case unsafeArtifact(String)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .emptyScope:
      "Select at least one VM storage category."
    case .invalidPlan:
      "The reviewed VM storage reclamation plan is invalid. Scan again."
    case .measurementRequired:
      "Measure VM storage before reviewing reclamation."
    case .staleSource:
      "The VM library changed after this review. Measure and review again."
    case .libraryInUse:
      "The VM library is busy. Wait for the current operation and try again."
    case .unsafeArtifact(let reason):
      "A VM storage artifact is unsafe to reclaim: \(reason)"
    case .unavailable:
      "VM storage reclamation is unavailable."
    }
  }
}
