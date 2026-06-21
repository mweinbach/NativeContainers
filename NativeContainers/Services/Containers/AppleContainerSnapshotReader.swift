import ContainerAPIClient
import ContainerResource

protocol ContainerSnapshotReading: Sendable {
  func list() async throws -> [ContainerSnapshot]
  func get(id: String) async throws -> ContainerSnapshot
}

struct AppleContainerSnapshotReader: ContainerSnapshotReading {
  private let client: ContainerClient

  init(client: ContainerClient = ContainerClient()) {
    self.client = client
  }

  func list() async throws -> [ContainerSnapshot] {
    try await client.list()
  }

  func get(id: String) async throws -> ContainerSnapshot {
    try await client.get(id: id)
  }
}
