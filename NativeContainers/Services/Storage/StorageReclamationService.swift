import Foundation

protocol ImageStorageReclaiming: Sendable {
  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan
  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult
}

protocol VolumeStorageReclaiming: Sendable {
  func prepareVolumePrune() async throws -> VolumePrunePlan
  func pruneVolumes(_ plan: VolumePrunePlan) async throws -> ResourceCleanupResult
}

protocol StorageReclamationManaging: Sendable {
  func prepareStorageReclamation(
    _ request: StorageReclamationRequest
  ) async throws -> StorageReclamationPlan

  func reclaimStorage(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult
}

extension AppleImageService: ImageStorageReclaiming {}
extension AppleInfrastructureService: VolumeStorageReclaiming {}

struct StorageReclamationService: StorageReclamationManaging {
  private let containers: any ContainerStorageReclaiming
  private let images: any ImageStorageReclaiming
  private let volumes: any VolumeStorageReclaiming
  private let executionCoordinator: RuntimeMutationCoordinator
  private let now: @Sendable () -> Date

  init(
    containers: any ContainerStorageReclaiming,
    images: any ImageStorageReclaiming,
    volumes: any VolumeStorageReclaiming,
    executionCoordinator: RuntimeMutationCoordinator = RuntimeMutationCoordinator(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.containers = containers
    self.images = images
    self.volumes = volumes
    self.executionCoordinator = executionCoordinator
    self.now = now
  }

  func prepareStorageReclamation(
    _ request: StorageReclamationRequest
  ) async throws -> StorageReclamationPlan {
    guard !request.categories.isEmpty else {
      throw StorageReclamationError.emptyScope
    }
    try Task.checkCancellation()

    async let containerPlan = prepareContainers(for: request)
    async let imagePlan = prepareImages(for: request)
    async let volumePlan = prepareVolumes(for: request)
    let plans = try await (containerPlan, imagePlan, volumePlan)
    try Task.checkCancellation()

    return StorageReclamationPlan(
      request: request,
      generatedAt: now(),
      containerPlan: plans.0,
      imagePlan: plans.1,
      volumePlan: plans.2
    )
  }

  func reclaimStorage(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult {
    try await executionCoordinator.perform {
      try await self.reclaimStorageSerially(plan)
    }
  }

  private func reclaimStorageSerially(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult {
    guard
      plan.request.reclaimContainers == (plan.containerPlan != nil),
      plan.request.reclaimImages == (plan.imagePlan != nil),
      plan.request.reclaimVolumes == (plan.volumePlan != nil),
      !plan.categories.isEmpty
    else {
      throw StorageReclamationError.invalidPlan
    }

    var containerResult: ContainerCleanupResult?
    var imageResult: ImageCleanupResult?
    var volumeResult: ResourceCleanupResult?
    var categoryFailures: [StorageReclamationCategoryFailure] = []

    func result() -> StorageReclamationResult {
      StorageReclamationResult(
        containerResult: containerResult,
        imageResult: imageResult,
        volumeResult: volumeResult,
        categoryFailures: categoryFailures
      )
    }

    func cancellation(
      remaining: [StorageReclamationCategory]
    ) -> StorageReclamationPartialCompletionError {
      StorageReclamationPartialCompletionError(
        result: result(),
        remainingCategories: remaining.filter(plan.categories.contains)
      )
    }

    if let plan = plan.containerPlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.containers, .images, .volumes])
      }
      do {
        containerResult = try await containers.pruneContainers(plan)
      } catch let partial as ContainerCleanupPartialCompletionError {
        containerResult = partial.result
        throw cancellation(remaining: [.containers, .images, .volumes])
      } catch is CancellationError {
        throw cancellation(remaining: [.containers, .images, .volumes])
      } catch {
        categoryFailures.append(
          StorageReclamationCategoryFailure(
            category: .containers,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.images, .volumes])
      }
    }

    if let plan = plan.imagePlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.images, .volumes])
      }
      do {
        imageResult = try await images.pruneImages(plan)
      } catch let partial as ImageCleanupPartialCompletionError {
        imageResult = partial.result
        throw cancellation(remaining: [.images, .volumes])
      } catch is CancellationError {
        throw cancellation(remaining: [.images, .volumes])
      } catch {
        categoryFailures.append(
          StorageReclamationCategoryFailure(
            category: .images,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.volumes])
      }
    }

    if let plan = plan.volumePlan {
      guard !Task.isCancelled else {
        throw cancellation(remaining: [.volumes])
      }
      do {
        volumeResult = try await volumes.pruneVolumes(plan)
      } catch let partial as ResourceCleanupPartialCompletionError {
        volumeResult = partial.result
        throw cancellation(remaining: [.volumes])
      } catch is CancellationError {
        throw cancellation(remaining: [.volumes])
      } catch {
        categoryFailures.append(
          StorageReclamationCategoryFailure(
            category: .volumes,
            message: error.localizedDescription
          )
        )
      }
      guard !Task.isCancelled else {
        throw cancellation(remaining: [])
      }
    }

    return result()
  }

  private func prepareContainers(
    for request: StorageReclamationRequest
  ) async throws -> ContainerPrunePlan? {
    guard request.reclaimContainers else { return nil }
    return try await containers.prepareContainerPrune()
  }

  private func prepareImages(
    for request: StorageReclamationRequest
  ) async throws -> ImagePrunePlan? {
    guard request.reclaimImages else { return nil }
    return try await images.prepareImagePrune(mode: request.imageMode)
  }

  private func prepareVolumes(
    for request: StorageReclamationRequest
  ) async throws -> VolumePrunePlan? {
    guard request.reclaimVolumes else { return nil }
    return try await volumes.prepareVolumePrune()
  }
}

struct UnavailableStorageReclamationService: StorageReclamationManaging {
  func prepareStorageReclamation(
    _ request: StorageReclamationRequest
  ) async throws -> StorageReclamationPlan {
    throw StorageReclamationError.unavailable
  }

  func reclaimStorage(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult {
    throw StorageReclamationError.unavailable
  }
}
