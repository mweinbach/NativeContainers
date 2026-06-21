import Foundation

protocol ContainerInventoryLoading: Sendable {
  func loadInventory() async throws -> ContainerInventory
}

protocol ContainerCreating: Sendable {
  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws
}

protocol ContainerInspecting: Sendable {
  func inspectContainer(id: String) async throws -> ContainerInspection
  func sampleContainer(id: String) async throws -> ContainerStatistics?
  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot
}

protocol ContainerLifecycleManaging: Sendable {
  func startContainer(id: String) async throws
  func stopContainer(id: String) async throws
  func restartContainer(id: String) async throws
  func forceStopContainer(id: String) async throws
  func deleteContainer(id: String) async throws
}

protocol ContainerTooling: Sendable {
  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult
  func copyIntoContainer(id: String, source: URL, destination: String) async throws
  func copyFromContainer(id: String, source: String, destination: URL) async throws
}

protocol ContainerTerminalOpening: Sendable {
  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession
}

protocol MachineLifecycleManaging: Sendable {
  func startMachine(id: String) async throws
  func stopMachine(id: String) async throws
  func deleteMachine(id: String) async throws
}
