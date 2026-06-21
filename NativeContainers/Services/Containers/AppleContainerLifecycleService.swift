import ContainerAPIClient
import ContainerResource
import Foundation

actor AppleContainerLifecycleService: ContainerLifecycleManaging {
  private let containerClient: ContainerClient
  private let attachmentService: any ContainerAttachmentWorkspaceManaging
  private let sshAgentService: any ContainerSSHAgentForwardingManaging

  init(
    containerClient: ContainerClient = ContainerClient(),
    attachmentService: any ContainerAttachmentWorkspaceManaging =
      AppleContainerAttachmentService(),
    sshAgentService: any ContainerSSHAgentForwardingManaging =
      AppleContainerSSHAgentService()
  ) {
    self.containerClient = containerClient
    self.attachmentService = attachmentService
    self.sshAgentService = sshAgentService
  }

  func startContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status != .running else { return }

    let hasManagedAttachments =
      !snapshot.configuration.publishedSockets.isEmpty
      || snapshot.configuration.labels[AppleContainerOwnership.hostDirectoryAttachmentLabel]
        == "true"
    var hostDirectoryAccess: ContainerHostDirectoryAccess?
    defer { hostDirectoryAccess?.release() }
    if hasManagedAttachments {
      guard
        let rawOperationID = snapshot.configuration.labels[
          AppleContainerOwnership.creationOperationLabel
        ],
        let operationID = UUID(uuidString: rawOperationID)
      else {
        throw ContainerLifecycleSafetyError.unownedAttachments(id)
      }
      hostDirectoryAccess = try await attachmentService.validateAttachmentsBeforeStart(
        snapshot.configuration,
        operationID: operationID
      )
    }

    let environment: [String: String]
    if snapshot.configuration.ssh {
      environment = try sshAgentService.currentEnvironment()
    } else {
      environment = [:]
    }

    let process = try await containerClient.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: environment
    )
    try await process.start()
  }

  func stopContainer(id: String) async throws {
    try await containerClient.stop(
      id: id,
      opts: ContainerStopOptions(timeoutInSeconds: 5, signal: nil)
    )
  }

  func restartContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    if snapshot.status == .running {
      try await stopContainer(id: id)
    }
    try await startContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try await containerClient.kill(id: id, signal: "KILL")
  }

  func deleteContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    try await containerClient.delete(id: id)
    guard
      let rawOperationID = snapshot.configuration.labels[
        AppleContainerOwnership.creationOperationLabel
      ],
      let operationID = UUID(uuidString: rawOperationID)
    else {
      return
    }
    await attachmentService.cleanupAttachmentWorkspace(
      operationID: operationID
    )
  }
}

private enum ContainerLifecycleSafetyError: LocalizedError {
  case unownedAttachments(String)

  var errorDescription: String? {
    switch self {
    case .unownedAttachments(let id):
      "Container “\(id)” uses managed host attachments outside a verifiable NativeContainers operation."
    }
  }
}
