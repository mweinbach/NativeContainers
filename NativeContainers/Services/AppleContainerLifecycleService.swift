import ContainerAPIClient
import ContainerResource
import Foundation

actor AppleContainerLifecycleService: ContainerLifecycleManaging {
  private let containerClient: ContainerClient
  private let attachmentService: any PublishedSocketWorkspaceManaging

  init(
    containerClient: ContainerClient = ContainerClient(),
    attachmentService: any PublishedSocketWorkspaceManaging =
      AppleContainerAttachmentService()
  ) {
    self.containerClient = containerClient
    self.attachmentService = attachmentService
  }

  func startContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status != .running else { return }

    if !snapshot.configuration.publishedSockets.isEmpty {
      guard
        let rawOperationID = snapshot.configuration.labels[
          AppleContainerOwnership.creationOperationLabel
        ],
        let operationID = UUID(uuidString: rawOperationID)
      else {
        throw ContainerLifecycleSafetyError.unownedPublishedSockets(id)
      }
      try await attachmentService.validatePublishedSocketsBeforeStart(
        snapshot.configuration.publishedSockets,
        operationID: operationID
      )
    }

    var environment: [String: String] = [:]
    if snapshot.configuration.ssh,
      let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    {
      environment["SSH_AUTH_SOCK"] = socket
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
    await attachmentService.cleanupPublishedSocketWorkspace(
      operationID: operationID
    )
  }
}

private enum ContainerLifecycleSafetyError: LocalizedError {
  case unownedPublishedSockets(String)

  var errorDescription: String? {
    switch self {
    case .unownedPublishedSockets(let id):
      "Container “\(id)” publishes sockets outside a verifiable NativeContainers operation."
    }
  }
}
