import Foundation
import Observation

@MainActor
@Observable
final class StorageReclamationModel {
  private(set) var plan: StorageReclamationPlan?
  private(set) var result: StorageReclamationResult?
  private(set) var errorMessage: String?
  private(set) var isPreparing = false
  private(set) var isReclaiming = false
  private(set) var isCancelling = false
  private(set) var reclaimContainers = false
  private(set) var reclaimImages = true
  private(set) var reclaimVolumes = true

  private let service: any StorageReclamationManaging
  private let currentSource: @MainActor @Sendable () -> StorageReclamationSource?
  private let didMutate: @MainActor @Sendable () async -> Void

  @ObservationIgnored
  private var operationTask: Task<Void, Never>?

  @ObservationIgnored
  private var discardWhenFinished = false

  init(
    service: any StorageReclamationManaging,
    currentSource: @escaping @MainActor @Sendable () -> StorageReclamationSource? = { nil },
    plan: StorageReclamationPlan? = nil,
    result: StorageReclamationResult? = nil,
    errorMessage: String? = nil,
    isPreparing: Bool = false,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.service = service
    self.currentSource = currentSource
    self.plan = plan
    self.result = result
    self.errorMessage = errorMessage
    self.isPreparing = isPreparing
    self.didMutate = didMutate
    if let request = plan?.request {
      reclaimContainers = request.reclaimContainers
      reclaimImages = request.reclaimImages
      reclaimVolumes = request.reclaimVolumes
    }
  }

  var isWorking: Bool {
    isPreparing || isReclaiming
  }

  var hasSelectedScope: Bool {
    reclaimContainers || reclaimImages || reclaimVolumes
  }

  func setReclaimContainers(_ enabled: Bool) {
    guard reclaimContainers != enabled else { return }
    reclaimContainers = enabled
    invalidateReview()
  }

  func setReclaimImages(_ enabled: Bool) {
    guard reclaimImages != enabled else { return }
    reclaimImages = enabled
    invalidateReview()
  }

  func setReclaimVolumes(_ enabled: Bool) {
    guard reclaimVolumes != enabled else { return }
    reclaimVolumes = enabled
    invalidateReview()
  }

  func startPreparing() {
    guard let source = currentSource() else {
      errorMessage = StorageReclamationError.measurementRequired.localizedDescription
      return
    }
    let request = StorageReclamationRequest(
      source: source,
      reclaimContainers: reclaimContainers,
      reclaimImages: reclaimImages,
      reclaimVolumes: reclaimVolumes
    )
    start { model in
      await model.prepare(request)
    }
  }

  func startReclaiming() {
    start { model in
      _ = await model.reclaimReviewedStorage()
    }
  }

  func cancelCurrentOperation() {
    guard operationTask != nil || isWorking else { return }
    isCancelling = true
    operationTask?.cancel()
  }

  @discardableResult
  func prepare(
    _ request: StorageReclamationRequest
  ) async -> StorageReclamationPlan? {
    guard !isWorking else { return nil }
    guard request.categories.isEmpty == false else {
      errorMessage = StorageReclamationError.emptyScope.localizedDescription
      return nil
    }
    isPreparing = true
    isCancelling = false
    plan = nil
    result = nil
    errorMessage = nil
    defer {
      isPreparing = false
      isCancelling = false
      finishDiscardIfNeeded()
    }

    do {
      let prepared = try await service.prepareStorageReclamation(request)
      try Task.checkCancellation()
      guard request.source == currentSource() else {
        throw StorageReclamationError.staleSource
      }
      plan = prepared
      return prepared
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func reclaimReviewedStorage() async -> Bool {
    guard !isWorking else { return false }
    guard let reviewedPlan = plan else {
      errorMessage = StorageReclamationError.invalidPlan.localizedDescription
      return false
    }
    guard reviewedPlan.request.source == currentSource() else {
      plan = nil
      errorMessage = StorageReclamationError.staleSource.localizedDescription
      return false
    }

    isReclaiming = true
    isCancelling = false
    result = nil
    errorMessage = nil
    defer {
      isReclaiming = false
      isCancelling = false
      plan = nil
      finishDiscardIfNeeded()
    }

    let completedWithoutFailures: Bool
    do {
      let cleanup = try await service.reclaimStorage(reviewedPlan)
      result = cleanup
      if cleanup.completedWithoutFailures {
        completedWithoutFailures = true
      } else {
        errorMessage = "Some reviewed storage changed or could not be reclaimed."
        completedWithoutFailures = false
      }
    } catch let partial as StorageReclamationPartialCompletionError {
      result = partial.result
      errorMessage = partial.localizedDescription
      completedWithoutFailures = false
    } catch is CancellationError {
      errorMessage =
        "Storage reclamation was cancelled. Measure storage again before retrying."
      completedWithoutFailures = false
    } catch {
      errorMessage = error.localizedDescription
      completedWithoutFailures = false
    }

    let didMutate = self.didMutate
    await Task.detached(priority: .userInitiated) {
      await didMutate()
    }.value
    return completedWithoutFailures
  }

  func invalidateReview() {
    if isWorking {
      discardWhenFinished = true
      if isPreparing {
        cancelCurrentOperation()
      }
      return
    }
    discardState()
  }

  func discardReview() {
    discardWhenFinished = isWorking
    cancelCurrentOperation()
    if !isWorking {
      discardState()
    }
  }

  private func start(
    _ operation: @escaping @MainActor (StorageReclamationModel) async -> Void
  ) {
    guard operationTask == nil else { return }
    operationTask = Task { [weak self] in
      guard let self else { return }
      await operation(self)
      operationTask = nil
    }
  }

  private func finishDiscardIfNeeded() {
    guard discardWhenFinished else { return }
    discardWhenFinished = false
    discardState()
  }

  private func discardState() {
    plan = nil
    result = nil
    errorMessage = nil
  }
}
