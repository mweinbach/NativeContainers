import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation

struct AppleImageCleanupService: Sendable {
  private let containerReader: any ContainerSnapshotReading
  private let pruneTransport: any ImagePruneTransport
  private let policy: AppleImagePolicy

  init(
    containerReader: any ContainerSnapshotReading,
    pruneTransport: any ImagePruneTransport,
    policy: AppleImagePolicy
  ) {
    self.containerReader = containerReader
    self.pruneTransport = pruneTransport
    self.policy = policy
  }

  func prepareTag(source: String, target: String) async throws -> ImageTagPlan {
    let source = try policy.validatedReference(source)
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { throw ImageManagementError.missingTargetReference }

    let configuration = try await policy.loadSystemConfiguration()
    let sourceImage = try await ClientImage.get(
      reference: source,
      containerSystemConfig: configuration
    )
    try policy.ensureUserManaged(sourceImage, configuration: configuration)
    let targetReference = try ClientImage.normalizeReference(
      target,
      containerSystemConfig: configuration
    )
    try policy.ensureUserManaged(reference: targetReference, configuration: configuration)
    let existingTarget = try await ClientImage.list().first {
      $0.reference == targetReference
    }

    return ImageTagPlan(
      sourceReference: sourceImage.reference,
      sourceDigest: sourceImage.digest,
      targetReference: targetReference,
      displayTargetReference: try ClientImage.denormalizeReference(
        targetReference,
        containerSystemConfig: configuration
      ),
      replacedDigest: existingTarget?.digest
    )
  }

  func tag(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    let configuration = try await policy.loadSystemConfiguration()
    let sourceImage = try await ClientImage.get(
      reference: plan.sourceReference,
      containerSystemConfig: configuration
    )
    guard sourceImage.digest == plan.sourceDigest else {
      throw ImageManagementError.stalePlan("tag operation")
    }
    try policy.ensureUserManaged(sourceImage, configuration: configuration)
    try policy.ensureUserManaged(reference: plan.targetReference, configuration: configuration)

    let currentTarget = try await ClientImage.list().first {
      $0.reference == plan.targetReference
    }
    if let currentTarget, currentTarget.digest != sourceImage.digest {
      guard currentTarget.digest == plan.replacedDigest else {
        throw ImageManagementError.stalePlan("tag operation")
      }
      guard replacingExisting else {
        throw ImageManagementError.tagWouldReplace(reference: plan.displayTargetReference)
      }
    }
    if currentTarget?.digest == sourceImage.digest { return }
    _ = try await sourceImage.tag(new: plan.targetReference)
  }

  func prepareDeletion(reference: String) async throws -> ImageDeletionPlan {
    let reference = try policy.validatedReference(reference)
    async let configurationRequest = policy.loadSystemConfiguration()
    async let allImagesRequest = ClientImage.list()
    async let containersRequest = containerReader.list()
    let configuration = try await configurationRequest
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    let allImages = try await allImagesRequest
    let containers = try await containersRequest

    return ImageDeletionPlan(
      reference: image.reference,
      digest: image.digest,
      aliases: allImages.filter { $0.digest == image.digest && $0.reference != image.reference }
        .map(\.reference)
        .sorted(),
      usedByContainerIDs: policy.containerIDs(
        using: image.reference,
        among: containers,
        configuration: configuration
      ),
      isInfrastructureImage: Utility.isInfraImage(
        name: image.reference,
        builderImage: configuration.build.image,
        initImage: configuration.vminit.image
      )
    )
  }

  func delete(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    let current = try await prepareDeletion(reference: plan.reference)
    guard current.digest == plan.digest else {
      throw ImageManagementError.stalePlan("deletion")
    }
    guard !current.isInfrastructureImage else {
      throw ImageManagementError.infrastructureImage(current.reference)
    }
    guard current.usedByContainerIDs.isEmpty else {
      throw ImageManagementError.imageInUse(
        reference: current.reference,
        containerIDs: current.usedByContainerIDs
      )
    }
    let configuration = try await policy.loadSystemConfiguration()
    let image = try await ClientImage.get(
      reference: current.reference,
      containerSystemConfig: configuration
    )
    return try await removeImages([
      ImagePruneRecord(
        reference: image.reference,
        digest: image.digest,
        indexSizeBytes: image.descriptor.size
      )
    ])
  }

  func preparePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    let configuration = try await policy.loadSystemConfiguration()
    let selection = try await pruneCandidates(mode: mode, configuration: configuration)
    let estimate: UInt64?
    if mode == .allUnused {
      estimate = try await pruneTransport.calculateReclaimableBytes(
        activeReferences: selection.activeReferences
      )
    } else {
      estimate = nil
    }

    return ImagePrunePlan(
      mode: mode,
      generatedAt: Date(),
      candidates: selection.images.map {
        ImagePruneCandidate(
          reference: $0.reference,
          digest: $0.digest,
          indexSizeBytes: $0.indexSizeBytes
        )
      }.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending },
      estimatedReclaimableBytes: estimate
    )
  }

  func prune(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    let configuration = try await policy.loadSystemConfiguration()
    let current = try await pruneCandidates(mode: plan.mode, configuration: configuration)
    let currentByReference = Dictionary(
      uniqueKeysWithValues: current.images.map { ($0.reference, $0) })
    var images: [ImagePruneRecord] = []
    var staleFailures: [ImageOperationFailure] = []

    for candidate in plan.candidates {
      guard let image = currentByReference[candidate.reference], image.digest == candidate.digest
      else {
        staleFailures.append(
          ImageOperationFailure(
            reference: candidate.reference,
            message: "Changed or became active after review; skipped."
          )
        )
        continue
      }
      images.append(image)
    }

    let result = try await removeImages(images)
    return ImageCleanupResult(
      removedReferences: result.removedReferences,
      failedReferences: staleFailures + result.failedReferences,
      removedBlobDigests: result.removedBlobDigests,
      reclaimedBytes: result.reclaimedBytes
    )
  }

  private func pruneCandidates(
    mode: ImagePruneMode,
    configuration: ContainerSystemConfig
  ) async throws -> (images: [ImagePruneRecord], activeReferences: Set<String>) {
    async let imagesRequest = pruneTransport.list()
    async let containersRequest = containerReader.list()
    let (allImages, containers) = try await (imagesRequest, containersRequest)
    var activeReferences = Set<String>()
    for container in containers {
      let reference = container.configuration.image.reference
      activeReferences.insert(reference)
      if let normalized = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      ) {
        activeReferences.insert(normalized)
      }
    }
    for reference in [configuration.build.image, configuration.vminit.image] {
      activeReferences.insert(reference)
      if let normalized = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      ) {
        activeReferences.insert(normalized)
      }
    }

    let userImages = allImages.filter {
      !Utility.isInfraImage(
        name: $0.reference,
        builderImage: configuration.build.image,
        initImage: configuration.vminit.image
      )
    }
    let candidates = userImages.filter { image in
      guard !activeReferences.contains(image.reference) else { return false }
      switch mode {
      case .dangling:
        guard let reference = try? Reference.parse(image.reference) else { return true }
        return reference.tag?.isEmpty != false
      case .allUnused:
        return true
      }
    }
    return (candidates, activeReferences)
  }

  private func removeImages(_ images: [ImagePruneRecord]) async throws -> ImageCleanupResult {
    var removedReferences: [String] = []
    var failures: [ImageOperationFailure] = []

    func cancellationResult(
      through index: Int
    ) async -> ImageCleanupResult {
      let currentReferences = await uncancelledImageReferences()
      let reconciled = images.prefix(index + 1).compactMap { image in
        currentReferences.map { references in
          references.contains(image.reference) ? nil : image.reference
        } ?? (removedReferences.contains(image.reference) ? image.reference : nil)
      }
      let confirmedRemoved = Set(removedReferences).union(reconciled)
      let attemptedFailures = Set(failures.map(\.reference))
      let pending =
        images
        .filter {
          !confirmedRemoved.contains($0.reference)
            && !attemptedFailures.contains($0.reference)
        }
        .map {
          ImageOperationFailure(
            reference: $0.reference,
            message: "Not removed because image cleanup was cancelled."
          )
        }
      let cleanup = await uncancelledOrphanCleanup()
      return ImageCleanupResult(
        removedReferences: confirmedRemoved.sorted(),
        failedReferences: failures + pending,
        removedBlobDigests: cleanup?.deletedDigests.sorted() ?? [],
        reclaimedBytes: cleanup?.reclaimedBytes ?? 0
      )
    }

    for (index, image) in images.enumerated() {
      guard !Task.isCancelled else {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      }
      do {
        try await pruneTransport.delete(reference: image.reference)
        removedReferences.append(image.reference)
      } catch is CancellationError {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      } catch {
        failures.append(
          ImageOperationFailure(
            reference: image.reference,
            message: error.localizedDescription
          )
        )
      }
      if Task.isCancelled {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      }
    }

    var removedBlobDigests: [String] = []
    var reclaimedBytes: UInt64 = 0
    do {
      let cleanup = try await pruneTransport.cleanUpOrphanedBlobs()
      removedBlobDigests = cleanup.deletedDigests
      reclaimedBytes = cleanup.reclaimedBytes
    } catch is CancellationError {
      let cleanup = await uncancelledOrphanCleanup()
      throw ImageCleanupPartialCompletionError(
        result: ImageCleanupResult(
          removedReferences: removedReferences.sorted(),
          failedReferences: failures,
          removedBlobDigests: cleanup?.deletedDigests.sorted() ?? [],
          reclaimedBytes: cleanup?.reclaimedBytes ?? 0
        )
      )
    } catch {
      failures.append(
        ImageOperationFailure(
          reference: "Content store cleanup",
          message: error.localizedDescription
        )
      )
    }

    return ImageCleanupResult(
      removedReferences: removedReferences.sorted(),
      failedReferences: failures,
      removedBlobDigests: removedBlobDigests.sorted(),
      reclaimedBytes: reclaimedBytes
    )
  }

  private func uncancelledImageReferences() async -> Set<String>? {
    let pruneTransport = pruneTransport
    return await Task.detached {
      var latest: Set<String>?
      for attempt in 0..<3 {
        do {
          latest = Set(try await pruneTransport.list().map(\.reference))
        } catch {
          if attempt == 2 { return latest }
        }
        if attempt < 2 {
          try? await Task.sleep(for: .milliseconds(150))
        }
      }
      return latest
    }.value
  }

  private func uncancelledOrphanCleanup() async -> (
    deletedDigests: [String],
    reclaimedBytes: UInt64
  )? {
    let pruneTransport = pruneTransport
    return await Task.detached {
      try? await pruneTransport.cleanUpOrphanedBlobs()
    }.value
  }
}
