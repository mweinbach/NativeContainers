import Foundation
import Observation

@MainActor
@Observable
final class ContainerBuilderManagementModel {
  private(set) var inspection: ContainerBuilderInspection?
  private(set) var plan: ContainerBuilderManagementPlan?
  private(set) var result: ContainerBuilderManagementResult?
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var isWorking = false

  private let service: any ContainerBuilderManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any ContainerBuilderManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func load() async {
    guard !isBusy else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      inspection = try await service.loadBuilder()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func prepare(
    _ action: ContainerBuilderManagementAction
  ) async -> ContainerBuilderManagementPlan? {
    guard !isBusy else { return nil }
    isWorking = true
    errorMessage = nil
    result = nil
    plan = nil
    defer { isWorking = false }

    do {
      let prepared = try await service.prepareBuilderAction(action)
      try Task.checkCancellation()
      plan = prepared
      inspection = ContainerBuilderInspection(
        builder: prepared.builder,
        reviewedSnapshot: prepared.reviewedSnapshot,
        runtimeApplicationRoot: prepared.runtimeApplicationRoot
      )
      return prepared
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func execute(
    _ reviewedPlan: ContainerBuilderManagementPlan? = nil,
    authorization: ContainerBuilderManagementAuthorization
  ) async -> Bool {
    guard let reviewedPlan = reviewedPlan ?? plan, !isBusy else { return false }
    isWorking = true
    errorMessage = nil
    result = nil
    defer {
      isWorking = false
      plan = nil
    }

    do {
      let completed = try await service.performBuilderAction(
        reviewedPlan,
        authorization: authorization
      )
      result = completed
      inspection = completed.inspection
      await didMutate()
      return true
    } catch is CancellationError {
      errorMessage =
        "The operation was cancelled. Builder state was refreshed because the runtime may have already accepted it."
      await refreshAfterAttempt()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshAfterAttempt()
      return false
    }
  }

  func discardPlan() {
    guard !isWorking else { return }
    plan = nil
  }

  func clearResult() {
    result = nil
    errorMessage = nil
  }

  var isBusy: Bool { isLoading || isWorking }

  private func refreshAfterAttempt() async {
    do {
      inspection = try await service.loadBuilder()
      await didMutate()
    } catch {
      if errorMessage == nil {
        errorMessage = error.localizedDescription
      }
    }
  }
}
