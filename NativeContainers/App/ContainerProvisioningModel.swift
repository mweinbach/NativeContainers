import Foundation
import Observation

@MainActor
@Observable
final class ContainerProvisioningModel {
  private(set) var isWorking = false
  private(set) var progress: ContainerOperationProgress?
  private(set) var errorMessage: String?

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
    await perform {
      try await self.service.createContainer(request: request) { [weak self] update in
        await self?.receive(update)
      }
    }
  }

  func pullImage(reference: String) async -> Bool {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else {
      errorMessage = ContainerCreationValidationError.missingImageReference.localizedDescription
      return false
    }
    return await perform {
      try await self.service.pullImage(reference: reference) { [weak self] update in
        await self?.receive(update)
      }
    }
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
      await didComplete()
      return true
    } catch is CancellationError {
      errorMessage = "The operation was cancelled."
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func receive(_ update: ContainerOperationProgress) {
    progress = update
  }
}
