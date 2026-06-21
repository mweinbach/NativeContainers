import Foundation
import Observation

@MainActor
@Observable
final class DockerCompatibilityModel {
  private(set) var snapshot: DockerCompatibilitySnapshot?
  private(set) var isRefreshing = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?
  private(set) var composeConformance: ComposeBridgeConformanceReport
  private(set) var composeClient: DockerComposeClientSnapshot?

  private let service: any DockerCompatibilityManaging
  private let composeClientService: any DockerComposeClientInstalling

  init(
    service: any DockerCompatibilityManaging,
    composeConformance: any ComposeBridgeConformanceReporting =
      SocktainerComposeConformanceService(),
    composeClientService: any DockerComposeClientInstalling =
      UnavailableDockerComposeClientService()
  ) {
    self.service = service
    self.composeConformance = composeConformance.report()
    self.composeClientService = composeClientService
  }

  func load() async {
    guard !isRefreshing, !isWorking else { return }
    isRefreshing = true
    await refreshSnapshots()
    isRefreshing = false
  }

  func install() async {
    await perform {
      try await service.installPinnedBridge()
    }
  }

  func installComposeClient() async {
    await perform {
      try await composeClientService.install()
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
    await refreshSnapshots()
    isWorking = false
  }

  private func refreshSnapshots() async {
    async let compatibilitySnapshot = service.snapshot()
    async let composeClientSnapshot = composeClientService.snapshot()
    let refreshed = await (compatibilitySnapshot, composeClientSnapshot)
    snapshot = refreshed.0
    composeClient = refreshed.1
  }
}
