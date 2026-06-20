import Foundation
import Observation

@MainActor
@Observable
final class ContainerProvisioningModel {
  private(set) var isWorking = false
  private(set) var progress: ContainerOperationProgress?
  private(set) var errorMessage: String?
  private(set) var pullPlan: ImagePullPlan?
  private(set) var pullResult: ImagePullResult?

  private let service: any ContainerManaging
  private let didComplete: @MainActor @Sendable () async -> Void

  init(
    service: any ContainerManaging,
    didComplete: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.service = service
    self.didComplete = didComplete
  }

  func createContainer(_ request: ContainerCreationRequest) async -> Bool {
    await perform { [self] in
      try await service.createContainer(request: request) { update in
        await self.receive(update)
      }
    }
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async -> ImagePullPlan? {
    guard !isWorking else { return nil }
    isWorking = true
    progress = nil
    errorMessage = nil
    pullResult = nil
    defer { isWorking = false }
    do {
      let plan = try await service.prepareImagePull(
        reference: reference,
        platform: platform,
        transport: transport,
        unpackAfterPull: unpackAfterPull,
        maxConcurrentDownloads: maxConcurrentDownloads
      )
      pullPlan = plan
      return plan
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func pullReviewedImage(
    _ reviewedPlan: ImagePullPlan? = nil,
    authorization: ImagePullAuthorization
  ) async -> Bool {
    guard let plan = reviewedPlan ?? pullPlan else {
      errorMessage = ImageManagementError.stalePlan("pull operation").localizedDescription
      return false
    }
    guard !isWorking else { return false }
    isWorking = true
    progress = nil
    errorMessage = nil
    pullResult = nil
    defer { isWorking = false }

    do {
      let result = try await service.pullImage(plan, authorization: authorization) { update in
        await self.receive(update)
      }
      pullResult = result
      pullPlan = nil
      await refreshIgnoringCancellation()
      return true
    } catch let error as ImagePullPartialCompletionError {
      pullResult = error.result
      pullPlan = nil
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    } catch is CancellationError {
      errorMessage = "The operation was cancelled."
      await refreshIgnoringCancellation()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    }
  }

  func clearPullPlan() {
    pullPlan = nil
  }

  func clearError() {
    errorMessage = nil
  }

  private func perform(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    progress = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      try await operation()
      await refreshIgnoringCancellation()
      return true
    } catch is CancellationError {
      errorMessage = "The operation was cancelled."
      await refreshIgnoringCancellation()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    }
  }

  private func refreshIgnoringCancellation() async {
    let didComplete = self.didComplete
    await Task.detached {
      await didComplete()
    }.value
  }

  private func receive(_ update: ContainerOperationProgress) {
    progress = update
  }
}
