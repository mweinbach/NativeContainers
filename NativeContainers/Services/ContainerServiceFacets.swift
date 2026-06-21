import ContainerResource
import Foundation

protocol ContainerInventoryLoading: Sendable {
  func loadInventory() async throws -> ContainerInventory
}

protocol LinuxMachineInventoryLoading: Sendable {
  func loadMachines() async throws -> [LinuxMachineRecord]
}

protocol BuiltinNetworkProviding: Sendable {
  func builtinNetworkResource() async throws -> NetworkResource?
}

struct ResolvedContainerAttachments: Sendable {
  let mounts: [Filesystem]
  let networks: [AttachmentConfiguration]
  let publishedSockets: [PublishSocket]
}

protocol ContainerAttachmentEnvironmentLoading: Sendable {
  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment
}

protocol ContainerAttachmentResolving: Sendable {
  func resolveAttachments(
    _ selection: ContainerAttachmentSelection,
    operationID: UUID,
    containerID: String,
    dnsDomain: String?
  ) async throws -> ResolvedContainerAttachments
}

protocol PublishedSocketWorkspaceManaging: Sendable {
  func validatePublishedSocketsBeforeStart(
    _ sockets: [PublishSocket],
    operationID: UUID
  ) async throws
  func cleanupPublishedSocketWorkspace(operationID: UUID) async
}

protocol ContainerAttachmentManaging:
  ContainerAttachmentEnvironmentLoading,
  ContainerAttachmentResolving,
  PublishedSocketWorkspaceManaging
{}

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

protocol MachineCreating: Sendable {
  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult
}

protocol MachineLifecycleManaging: Sendable {
  func startMachine(_ target: LinuxMachineIdentity) async throws
  func stopMachine(_ target: LinuxMachineIdentity) async throws
  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws
  func deleteMachine(_ target: LinuxMachineIdentity) async throws
}

protocol MachineManaging: MachineCreating, MachineLifecycleManaging {}
