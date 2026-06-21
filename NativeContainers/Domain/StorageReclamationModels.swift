import Foundation

struct StorageReclamationSource: Equatable, Sendable {
  let appleRuntimeCapturedAt: Date
  let appleRuntimeRevision: UInt64
  let inventoryRevision: UInt64
  let images: StorageResourceUsage
  let containers: StorageResourceUsage
  let volumes: StorageResourceUsage
}

enum StorageReclamationCategory: String, CaseIterable, Equatable, Sendable, Identifiable {
  case containers
  case images
  case volumes

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .containers:
      "Stopped app containers"
    case .images:
      "Unused images"
    case .volumes:
      "Unused volumes"
    }
  }
}

struct StorageReclamationRequest: Equatable, Sendable {
  let source: StorageReclamationSource
  let reclaimContainers: Bool
  let reclaimImages: Bool
  let imageMode: ImagePruneMode
  let reclaimVolumes: Bool

  init(
    source: StorageReclamationSource,
    reclaimContainers: Bool = false,
    reclaimImages: Bool = true,
    imageMode: ImagePruneMode = .allUnused,
    reclaimVolumes: Bool = true
  ) {
    self.source = source
    self.reclaimContainers = reclaimContainers
    self.reclaimImages = reclaimImages
    self.imageMode = imageMode
    self.reclaimVolumes = reclaimVolumes
  }

  var categories: [StorageReclamationCategory] {
    var categories: [StorageReclamationCategory] = []
    if reclaimContainers { categories.append(.containers) }
    if reclaimImages { categories.append(.images) }
    if reclaimVolumes { categories.append(.volumes) }
    return categories
  }
}

struct ContainerPruneCandidate: Equatable, Sendable, Identifiable {
  let id: String
  let ownershipID: UUID
  let createdAt: Date
  let imageReference: String
  let imageDigest: String
  let platform: String
  let configurationSeal: Data
  let allocatedBytes: UInt64?
  let hasPublishedSockets: Bool
}

struct ContainerPrunePlan: Equatable, Sendable {
  let candidates: [ContainerPruneCandidate]
  let generatedAt: Date

  var knownEstimatedReclaimableBytes: UInt64 {
    StorageByteMath.saturatingSum(candidates.compactMap(\.allocatedBytes))
  }

  var hasCompleteEstimate: Bool {
    candidates.allSatisfy { $0.allocatedBytes != nil }
  }
}

struct ContainerCleanupResult: Equatable, Sendable {
  let removedContainerIDs: [String]
  let failedContainers: [ResourceOperationFailure]
  let removedAllocatedBytes: UInt64

  var completedWithoutFailures: Bool { failedContainers.isEmpty }
}

struct ContainerCleanupPartialCompletionError: LocalizedError, Sendable {
  let result: ContainerCleanupResult

  var errorDescription: String? {
    let removed = result.removedContainerIDs.count
    let remaining = result.failedContainers.count
    return
      "Container reclamation was cancelled after removing \(removed) container(s); \(remaining) reviewed container(s) remain."
  }
}

struct StorageReclamationPlan: Equatable, Sendable {
  let request: StorageReclamationRequest
  let generatedAt: Date
  let containerPlan: ContainerPrunePlan?
  let imagePlan: ImagePrunePlan?
  let volumePlan: VolumePrunePlan?

  var containerCandidateCount: Int {
    containerPlan?.candidates.count ?? 0
  }

  var imageCandidateCount: Int {
    imagePlan?.candidates.count ?? 0
  }

  var volumeCandidateCount: Int {
    volumePlan?.candidates.count ?? 0
  }

  var candidateCount: Int {
    containerCandidateCount + imageCandidateCount + volumeCandidateCount
  }

  var isEmpty: Bool {
    candidateCount == 0
  }

  var knownEstimatedReclaimableBytes: UInt64 {
    StorageByteMath.saturatingSum([
      containerPlan?.knownEstimatedReclaimableBytes ?? 0,
      imagePlan?.estimatedReclaimableBytes ?? 0,
      volumePlan?.estimatedReclaimableBytes ?? 0,
    ])
  }

  var hasCompleteEstimate: Bool {
    let containersComplete = containerPlan?.hasCompleteEstimate ?? true
    let imagesComplete = imagePlan == nil || imagePlan?.estimatedReclaimableBytes != nil
    let volumesComplete =
      volumePlan?.candidates.allSatisfy { $0.volume.allocatedBytes != nil } ?? true
    return containersComplete && imagesComplete && volumesComplete
  }

  var categories: [StorageReclamationCategory] {
    request.categories
  }
}

struct StorageReclamationCategoryFailure: Equatable, Sendable, Identifiable {
  let category: StorageReclamationCategory
  let message: String

  var id: StorageReclamationCategory { category }
}

struct StorageReclamationResult: Equatable, Sendable {
  let containerResult: ContainerCleanupResult?
  let imageResult: ImageCleanupResult?
  let volumeResult: ResourceCleanupResult?
  let categoryFailures: [StorageReclamationCategoryFailure]

  static let empty = StorageReclamationResult(
    containerResult: nil,
    imageResult: nil,
    volumeResult: nil,
    categoryFailures: []
  )

  var removedCandidateCount: Int {
    (containerResult?.removedContainerIDs.count ?? 0)
      + (imageResult?.removedReferences.count ?? 0)
      + (volumeResult?.removedResourceNames.count ?? 0)
  }

  var failedCandidateCount: Int {
    (containerResult?.failedContainers.count ?? 0)
      + (imageResult?.failedReferences.count ?? 0)
      + (volumeResult?.failedResources.count ?? 0)
      + categoryFailures.count
  }

  var imageReclaimedBytes: UInt64 {
    imageResult?.reclaimedBytes ?? 0
  }

  var removedAllocatedBytes: UInt64 {
    StorageByteMath.saturatingSum([
      containerResult?.removedAllocatedBytes ?? 0,
      volumeResult?.reclaimedBytes ?? 0,
    ])
  }

  var reportedRemovedBytes: UInt64 {
    StorageByteMath.saturatingSum([
      imageReclaimedBytes,
      removedAllocatedBytes,
    ])
  }

  var completedWithoutFailures: Bool {
    failedCandidateCount == 0
  }

  var hasRecordedWork: Bool {
    containerResult != nil || imageResult != nil || volumeResult != nil
      || !categoryFailures.isEmpty
  }
}

struct StorageReclamationPartialCompletionError: LocalizedError, Sendable {
  let result: StorageReclamationResult
  let remainingCategories: [StorageReclamationCategory]

  var errorDescription: String? {
    let completed = result.removedCandidateCount
    let remaining =
      remainingCategories
      .map { String(localized: $0.title) }
      .formatted()
    if remaining.isEmpty {
      return "Storage reclamation was cancelled after removing \(completed) reviewed item(s)."
    }
    return
      "Storage reclamation was cancelled after removing \(completed) reviewed item(s). Review \(remaining) again before retrying."
  }
}

enum StorageReclamationError: LocalizedError, Equatable, Sendable {
  case emptyScope
  case invalidPlan
  case measurementRequired
  case staleSource
  case unavailable

  var errorDescription: String? {
    switch self {
    case .emptyScope:
      "Select at least one storage category."
    case .invalidPlan:
      "The reviewed storage reclamation plan is invalid. Scan again."
    case .measurementRequired:
      "Measure Apple runtime storage before reviewing reclamation."
    case .staleSource:
      "Storage or runtime inventory changed after this review. Measure and review again."
    case .unavailable:
      "Storage reclamation is unavailable."
    }
  }
}
