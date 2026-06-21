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
  let hostDirectoryAccess: ContainerHostDirectoryAccess?

  init(
    mounts: [Filesystem],
    networks: [AttachmentConfiguration],
    publishedSockets: [PublishSocket],
    hostDirectoryAccess: ContainerHostDirectoryAccess? = nil
  ) {
    self.mounts = mounts
    self.networks = networks
    self.publishedSockets = publishedSockets
    self.hostDirectoryAccess = hostDirectoryAccess
  }
}

protocol ContainerAttachmentEnvironmentLoading: Sendable {
  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment
}

protocol ContainerHostDirectoryReviewing: Sendable {
  func reviewHostDirectory(
    _ request: ContainerHostDirectoryReviewRequest
  ) throws -> ContainerHostDirectoryMount
}

protocol ContainerAttachmentPreparing:
  ContainerAttachmentEnvironmentLoading,
  ContainerHostDirectoryReviewing
{}

protocol ContainerHostDirectoryManaging: ContainerHostDirectoryReviewing {
  func prepare(
    _ mounts: [ContainerHostDirectoryMount],
    operationID: UUID
  ) throws -> ContainerHostDirectoryAccess?
  func validateBeforeStart(
    _ configuredMounts: [Filesystem],
    operationID: UUID
  ) throws -> ContainerHostDirectoryAccess
  func cleanup(operationID: UUID)
}

protocol ContainerSSHAgentForwardingManaging: Sendable {
  func availability() -> ContainerSSHAgentAvailability
  func environment(
    for reviewedConfiguration: ContainerSSHAgentConfiguration
  ) throws -> [String: String]
  func currentEnvironment() throws -> [String: String]
}

protocol ContainerAttachmentResolving: Sendable {
  func resolveAttachments(
    _ selection: ContainerAttachmentSelection,
    operationID: UUID,
    containerID: String,
    dnsDomain: String?
  ) async throws -> ResolvedContainerAttachments
}

protocol ContainerAttachmentWorkspaceManaging: Sendable {
  func validateAttachmentsBeforeStart(
    _ configuration: ContainerConfiguration,
    operationID: UUID
  ) async throws -> ContainerHostDirectoryAccess?
  func cleanupAttachmentWorkspace(operationID: UUID) async
}

protocol ContainerAttachmentManaging:
  ContainerAttachmentPreparing,
  ContainerAttachmentResolving,
  ContainerAttachmentWorkspaceManaging
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

protocol ContainerCommandRunning: Sendable {
  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult
}

protocol ContainerFileTransferring: Sendable {
  func copyIntoContainer(id: String, source: URL, destination: String) async throws
  func copyFromContainer(id: String, source: String, destination: URL) async throws
}

protocol ContainerShellDiscovering: Sendable {
  func discoverShell(in id: String) async throws -> ContainerShell
}

struct UnavailableContainerShellService: ContainerShellDiscovering {
  func discoverShell(in id: String) async throws -> ContainerShell {
    throw ContainerShellDiscoveryError.unavailable(id)
  }
}

protocol ContainerTooling:
  ContainerCommandRunning,
  ContainerFileTransferring
{}

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

protocol MachineConfigurationManaging: Sendable {
  func updateConfiguration(
    for target: LinuxMachineIdentity,
    request: LinuxMachineConfigurationUpdateRequest
  ) async throws -> LinuxMachineConfigurationUpdateResult
}

struct UnavailableLinuxMachineConfigurationService: MachineConfigurationManaging {
  func updateConfiguration(
    for target: LinuxMachineIdentity,
    request: LinuxMachineConfigurationUpdateRequest
  ) async throws -> LinuxMachineConfigurationUpdateResult {
    throw LinuxMachineConfigurationError.unavailable
  }
}

protocol MachineCommandRunning: Sendable {
  func executeCommand(
    in target: LinuxMachineIdentity,
    request: LinuxMachineCommandRequest
  ) async throws -> ContainerCommandResult
}

protocol MachineTerminalOpening: Sendable {
  func openTerminal(
    in target: LinuxMachineIdentity,
    request: LinuxMachineTerminalRequest
  ) async throws -> any ContainerTerminalSession
}

struct UnavailableLinuxMachineToolService: MachineCommandRunning, MachineTerminalOpening {
  func executeCommand(
    in target: LinuxMachineIdentity,
    request: LinuxMachineCommandRequest
  ) async throws -> ContainerCommandResult {
    throw LinuxMachineToolError.unavailable
  }

  func openTerminal(
    in target: LinuxMachineIdentity,
    request: LinuxMachineTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    throw LinuxMachineToolError.unavailable
  }
}
