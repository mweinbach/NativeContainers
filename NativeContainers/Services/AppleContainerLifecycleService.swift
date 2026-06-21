import ContainerAPIClient
import ContainerResource
import Foundation

actor AppleContainerLifecycleService: ContainerLifecycleManaging {
  private let containerClient: ContainerClient

  init(containerClient: ContainerClient = ContainerClient()) {
    self.containerClient = containerClient
  }

  func startContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status != .running else { return }

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
    try await containerClient.delete(id: id)
  }
}
