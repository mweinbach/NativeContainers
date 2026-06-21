import Foundation
import Observation

@MainActor
@Observable
final class VolumeManagementModel {
  private(set) var isWorking = false
  private(set) var errorMessage: String?
  private(set) var creationPlan: VolumeCreationPlan?
  private(set) var deletionPlan: VolumeDeletionPlan?
  private(set) var prunePlan: VolumePrunePlan?
  private(set) var cleanupResult: ResourceCleanupResult?

  private let service: any VolumeManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any VolumeManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func prepareCreation(_ request: VolumeCreateRequest) async -> VolumeCreationPlan? {
    await prepare {
      let plan = try await self.service.prepareVolumeCreation(request)
      self.creationPlan = plan
      return plan
    }
  }

  func createReviewedVolume(_ reviewedPlan: VolumeCreationPlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? creationPlan else {
      errorMessage = ResourceManagementError.stalePlan("volume creation").localizedDescription
      return false
    }
    let result: VolumeRecord? = await mutate {
      try await self.service.createVolume(plan)
    }
    if result != nil { creationPlan = nil }
    return result != nil
  }

  func prepareDeletion(name: String) async -> VolumeDeletionPlan? {
    await prepare {
      let plan = try await self.service.prepareVolumeDeletion(name: name)
      self.deletionPlan = plan
      return plan
    }
  }

  func deleteReviewedVolume(_ reviewedPlan: VolumeDeletionPlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? deletionPlan else {
      errorMessage = ResourceManagementError.stalePlan("volume deletion").localizedDescription
      return false
    }
    guard plan.canDelete else {
      errorMessage =
        ResourceManagementError.volumeInUse(
          name: plan.volume.name,
          containerIDs: plan.volume.usedByContainerIDs
        ).localizedDescription
      return false
    }
    let succeeded =
      await mutate {
        try await self.service.deleteVolume(plan)
        return true
      } ?? false
    if succeeded { deletionPlan = nil }
    return succeeded
  }

  func preparePrune() async -> VolumePrunePlan? {
    await prepare {
      let plan = try await self.service.prepareVolumePrune()
      self.prunePlan = plan
      self.cleanupResult = nil
      return plan
    }
  }

  func pruneReviewedVolumes(_ reviewedPlan: VolumePrunePlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? prunePlan else {
      errorMessage = ResourceManagementError.stalePlan("volume prune").localizedDescription
      return false
    }
    guard
      let result: ResourceCleanupResult = await mutate({
        try await self.service.pruneVolumes(plan)
      })
    else {
      return false
    }
    cleanupResult = result
    prunePlan = nil
    if !result.failedResources.isEmpty, errorMessage == nil {
      errorMessage = "Some volumes changed or could not be removed."
    }
    return result.completedWithoutFailures
  }

  func clearReview() {
    creationPlan = nil
    deletionPlan = nil
    prunePlan = nil
    cleanupResult = nil
    errorMessage = nil
  }

  private func prepare<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
  ) async -> T? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      return try await operation()
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func mutate<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
  ) async -> T? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let result = try await operation()
      await refreshIgnoringCancellation()
      return result
    } catch let error as ResourceCleanupPartialCompletionError {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return error.result as? T
    } catch is CancellationError {
      await refreshIgnoringCancellation()
      return nil
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return nil
    }
  }

  private func refreshIgnoringCancellation() async {
    let didMutate = self.didMutate
    await Task.detached {
      await didMutate()
    }.value
  }
}

@MainActor
@Observable
final class NetworkManagementModel {
  private(set) var isWorking = false
  private(set) var errorMessage: String?
  private(set) var creationPlan: NetworkCreationPlan?
  private(set) var deletionPlan: NetworkDeletionPlan?
  private(set) var prunePlan: NetworkPrunePlan?
  private(set) var cleanupResult: ResourceCleanupResult?

  private let service: any NetworkManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any NetworkManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func prepareCreation(_ request: NetworkCreateRequest) async -> NetworkCreationPlan? {
    await prepare {
      let plan = try await self.service.prepareNetworkCreation(request)
      self.creationPlan = plan
      return plan
    }
  }

  func createReviewedNetwork(_ reviewedPlan: NetworkCreationPlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? creationPlan else {
      errorMessage = ResourceManagementError.stalePlan("network creation").localizedDescription
      return false
    }
    let result: NetworkRecord? = await mutate {
      try await self.service.createNetwork(plan)
    }
    if result != nil { creationPlan = nil }
    return result != nil
  }

  func prepareDeletion(id: String) async -> NetworkDeletionPlan? {
    await prepare {
      let plan = try await self.service.prepareNetworkDeletion(id: id)
      self.deletionPlan = plan
      return plan
    }
  }

  func deleteReviewedNetwork(_ reviewedPlan: NetworkDeletionPlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? deletionPlan else {
      errorMessage = ResourceManagementError.stalePlan("network deletion").localizedDescription
      return false
    }
    guard !plan.network.isBuiltin else {
      errorMessage = ResourceManagementError.builtinNetwork(plan.network.name).localizedDescription
      return false
    }
    guard plan.network.usedByContainerIDs.isEmpty else {
      errorMessage =
        ResourceManagementError.networkInUse(
          name: plan.network.name,
          containerIDs: plan.network.usedByContainerIDs
        ).localizedDescription
      return false
    }
    let succeeded =
      await mutate {
        try await self.service.deleteNetwork(plan)
        return true
      } ?? false
    if succeeded { deletionPlan = nil }
    return succeeded
  }

  func preparePrune() async -> NetworkPrunePlan? {
    await prepare {
      let plan = try await self.service.prepareNetworkPrune()
      self.prunePlan = plan
      self.cleanupResult = nil
      return plan
    }
  }

  func pruneReviewedNetworks(_ reviewedPlan: NetworkPrunePlan? = nil) async -> Bool {
    guard let plan = reviewedPlan ?? prunePlan else {
      errorMessage = ResourceManagementError.stalePlan("network prune").localizedDescription
      return false
    }
    guard
      let result: ResourceCleanupResult = await mutate({
        try await self.service.pruneNetworks(plan)
      })
    else {
      return false
    }
    cleanupResult = result
    prunePlan = nil
    if !result.failedResources.isEmpty, errorMessage == nil {
      errorMessage = "Some networks changed or could not be removed."
    }
    return result.completedWithoutFailures
  }

  func clearReview() {
    creationPlan = nil
    deletionPlan = nil
    prunePlan = nil
    cleanupResult = nil
    errorMessage = nil
  }

  private func prepare<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
  ) async -> T? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      return try await operation()
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func mutate<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> T
  ) async -> T? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let result = try await operation()
      await refreshIgnoringCancellation()
      return result
    } catch let error as ResourceCleanupPartialCompletionError {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return error.result as? T
    } catch is CancellationError {
      await refreshIgnoringCancellation()
      return nil
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return nil
    }
  }

  private func refreshIgnoringCancellation() async {
    let didMutate = self.didMutate
    await Task.detached {
      await didMutate()
    }.value
  }
}
