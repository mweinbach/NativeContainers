import Foundation

protocol ImageManaging: Sendable {
  func inspectImage(reference: String) async throws -> ImageInspection
  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan
  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws
  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan
  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult
  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan
  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult
}

extension ImageManaging {
  func inspectImage(reference: String) async throws -> ImageInspection {
    throw ImageManagementError.unsupported
  }

  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    throw ImageManagementError.unsupported
  }

  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    throw ImageManagementError.unsupported
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    throw ImageManagementError.unsupported
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    throw ImageManagementError.unsupported
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    throw ImageManagementError.unsupported
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    throw ImageManagementError.unsupported
  }
}

protocol ContainerManaging: ImageManaging {
  func loadInventory() async throws -> ContainerInventory
  func pullImage(
    reference: String,
    progress: @escaping ContainerProgressHandler
  ) async throws
  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws
  func inspectContainer(id: String) async throws -> ContainerInspection
  func sampleContainer(id: String) async throws -> ContainerStatistics?
  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot
  func startContainer(id: String) async throws
  func stopContainer(id: String) async throws
  func restartContainer(id: String) async throws
  func forceStopContainer(id: String) async throws
  func deleteContainer(id: String) async throws
  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult
  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession
  func copyIntoContainer(id: String, source: URL, destination: String) async throws
  func copyFromContainer(id: String, source: String, destination: URL) async throws
  func startMachine(id: String) async throws
  func stopMachine(id: String) async throws
  func deleteMachine(id: String) async throws
}

extension ContainerManaging {
  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    throw ContainerTerminalError.unsupported
  }
}
