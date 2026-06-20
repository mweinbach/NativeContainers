import Foundation

protocol ContainerManaging: Sendable {
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
  func startMachine(id: String) async throws
  func stopMachine(id: String) async throws
  func deleteMachine(id: String) async throws
}
