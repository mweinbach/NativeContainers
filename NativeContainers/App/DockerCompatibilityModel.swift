import Foundation
import Observation

@MainActor
@Observable
final class DockerCompatibilityModel {
  private(set) var snapshot: DockerCompatibilitySnapshot?
  private(set) var isRefreshing = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any DockerCompatibilityManaging

  init(service: any DockerCompatibilityManaging) {
    self.service = service
  }

  func load() async {
    guard !isRefreshing, !isWorking else { return }
    isRefreshing = true
    snapshot = await service.snapshot()
    isRefreshing = false
  }

  func install() async {
    await perform {
      try await service.installPinnedBridge()
    }
  }

  func start() async {
    await perform {
      try await service.startBridge()
    }
  }

  func stop() async {
    await perform {
      try await service.stopBridge()
    }
  }

  func forceStop() async {
    await perform {
      try await service.forceStopBridge()
    }
  }

  func removeStaleSocket() async {
    await perform {
      try await service.removeStaleSocket()
    }
  }

  func createOrRepairContext() async {
    await perform {
      try await service.createOrRepairDockerContext()
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func perform(
    _ operation: () async throws -> Void
  ) async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    do {
      try await operation()
    } catch is CancellationError {
      errorMessage = "The Docker compatibility operation was cancelled."
    } catch {
      errorMessage = error.localizedDescription
    }
    snapshot = await service.snapshot()
    isWorking = false
  }
}
