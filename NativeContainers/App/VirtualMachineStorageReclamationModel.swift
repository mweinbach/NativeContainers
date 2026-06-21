import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineStorageReclamationModel {
  private(set) var plan: VirtualMachineStorageReclamationPlan?
  private(set) var result: VirtualMachineStorageReclamationResult?
  private(set) var errorMessage: String?
  private(set) var isPreparing = false
  private(set) var isReclaiming = false
  private(set) var isCancelling = false
  private(set) var reclaimSavedStates = true
  private(set) var reclaimInterruptedResidue = true

  private let service: any VirtualMachineStorageReclamationManaging
  private let currentSource: @MainActor @Sendable () -> VirtualMachineStorageReclamationSource?
  private let didMutate: @MainActor @Sendable () async -> Void

  @ObservationIgnored
  private var operationTask: Task<Void, Never>?

  @ObservationIgnored
  private var discardWhenFinished = false

  init(
    service: any VirtualMachineStorageReclamationManaging,
    currentSource:
      @escaping @MainActor @Sendable () -> VirtualMachineStorageReclamationSource? = {
        nil
      },
    plan: VirtualMachineStorageReclamationPlan? = nil,
    result: VirtualMachineStorageReclamationResult? = nil,
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
      reclaimSavedStates = !request.savedStateMachineIDs.isEmpty
      reclaimInterruptedResidue = request.reclaimInterruptedResidue
    }
  }

  var isWorking: Bool {
    isPreparing || isReclaiming
  }

  var hasSelectedScope: Bool {
    (reclaimSavedStates
      && currentSource()?.measuredSavedStateMachineIDs.isEmpty == false)
      || reclaimInterruptedResidue
  }

  var measuredSavedStateCount: Int {
    currentSource()?.measuredSavedStateMachineIDs.count ?? 0
  }

  func setReclaimSavedStates(_ enabled: Bool) {
    guard reclaimSavedStates != enabled else { return }
    reclaimSavedStates = enabled
    invalidateReview()
  }

  func setReclaimInterruptedResidue(_ enabled: Bool) {
    guard reclaimInterruptedResidue != enabled else { return }
    reclaimInterruptedResidue = enabled
    invalidateReview()
  }

  func startPreparing() {
    guard let source = currentSource() else {
      errorMessage =
        VirtualMachineStorageReclamationError.measurementRequired
        .localizedDescription
      return
    }
    let request = VirtualMachineStorageReclamationRequest(
      source: source,
      savedStateMachineIDs: reclaimSavedStates
        ? source.measuredSavedStateMachineIDs : [],
      reclaimInterruptedResidue: reclaimInterruptedResidue
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
    _ request: VirtualMachineStorageReclamationRequest
  ) async -> VirtualMachineStorageReclamationPlan? {
    guard !isWorking else { return nil }
    guard !request.categories.isEmpty else {
      errorMessage =
        VirtualMachineStorageReclamationError.emptyScope.localizedDescription
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
      let prepared =
        try await service
        .prepareVirtualMachineStorageReclamation(request)
      try Task.checkCancellation()
      guard prepared.request == request else {
        throw VirtualMachineStorageReclamationError.invalidPlan
      }
      guard request.source == currentSource() else {
        throw VirtualMachineStorageReclamationError.staleSource
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
      errorMessage =
        VirtualMachineStorageReclamationError.invalidPlan.localizedDescription
      return false
    }
    guard reviewedPlan.request.source == currentSource() else {
      plan = nil
      errorMessage =
        VirtualMachineStorageReclamationError.staleSource.localizedDescription
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
    var acceptedMutation = false
    do {
      let cleanup = try await service.reclaimVirtualMachineStorage(
        reviewedPlan
      )
      result = cleanup
      acceptedMutation = cleanup.hasRecordedWork
      if cleanup.failedCandidateCount == 0
        && cleanup.staleCandidateCount == 0
      {
        completedWithoutFailures = true
      } else {
        errorMessage =
          "Some reviewed VM storage changed or could not be reclaimed."
        completedWithoutFailures = false
      }
    } catch let partial as VirtualMachineStorageReclamationPartialCompletionError {
      result = partial.result
      acceptedMutation = partial.result.hasRecordedWork
      errorMessage = partial.localizedDescription
      completedWithoutFailures = false
    } catch is CancellationError {
      errorMessage =
        "VM storage reclamation was cancelled. Measure storage again before retrying."
      completedWithoutFailures = false
    } catch {
      errorMessage = error.localizedDescription
      completedWithoutFailures = false
    }

    if acceptedMutation {
      let didMutate = self.didMutate
      await Task.detached(priority: .userInitiated) {
        await didMutate()
      }.value
    }
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
    _ operation:
      @escaping @MainActor (VirtualMachineStorageReclamationModel) async -> Void
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
