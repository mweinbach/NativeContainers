import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import NativeContainers

@Suite("Owned container recovery")
struct OwnedContainerRecoveryServiceTests {
  @Test
  func runningOwnedContainerIsKilledForceDeletedAndVerifiedAbsent() async throws {
    let operationID = UUID()
    let transport = CleanupTransportDouble(
      listResults: [
        [.owned(id: "partial", operationID: operationID, status: .running)],
        [],
      ]
    )
    let service = AppleOwnedContainerRecoveryService(
      cleanupClient: transport,
      ownershipLabel: ownershipLabel
    )

    try await service.removeOwnedContainer(id: "partial", operationID: operationID)

    #expect(await transport.killedIDs == ["partial"])
    #expect(await transport.forceDeletedIDs == ["partial"])
    #expect(await transport.listCallCount == 2)
  }

  @Test
  func delayedOwnedContainerCommitIsStillKilledAndDeleted() async throws {
    let operationID = UUID()
    let transport = CleanupTransportDouble(
      listResults: [
        [],
        [.owned(id: "partial", operationID: operationID, status: .running)],
        [],
      ]
    )
    let service = AppleOwnedContainerRecoveryService(
      cleanupClient: transport,
      ownershipLabel: ownershipLabel
    )

    try await service.removeOwnedContainer(id: "partial", operationID: operationID)

    #expect(await transport.killedIDs == ["partial"])
    #expect(await transport.forceDeletedIDs == ["partial"])
    #expect(await transport.listCallCount == 3)
  }

  @Test
  func replacementContainerIsNeverKilledOrDeleted() async throws {
    let transport = CleanupTransportDouble(
      listResults: [
        [.owned(id: "partial", operationID: UUID(), status: .running)]
      ]
    )
    let service = AppleOwnedContainerRecoveryService(
      cleanupClient: transport,
      ownershipLabel: ownershipLabel
    )

    try await service.removeOwnedContainer(id: "partial", operationID: UUID())

    #expect(await transport.killedIDs.isEmpty)
    #expect(await transport.forceDeletedIDs.isEmpty)
  }

  private let ownershipLabel = "com.nativecontainers.creation-operation"
}

private actor CleanupTransportDouble: AppleContainerCleanupTransport {
  private var listResults: [[ContainerSnapshot]]
  private(set) var killedIDs: [String] = []
  private(set) var forceDeletedIDs: [String] = []
  private(set) var listCallCount = 0

  init(listResults: [[ContainerSnapshot]]) {
    self.listResults = listResults
  }

  func list(id: String) async throws -> [ContainerSnapshot] {
    listCallCount += 1
    guard !listResults.isEmpty else { return [] }
    return listResults.removeFirst()
  }

  func kill(id: String) async throws {
    killedIDs.append(id)
  }

  func forceDelete(id: String) async throws {
    forceDeletedIDs.append(id)
  }
}

extension ContainerSnapshot {
  fileprivate static func owned(
    id: String,
    operationID: UUID,
    status: RuntimeStatus
  ) -> ContainerSnapshot {
    let descriptor = Descriptor(
      mediaType: "application/vnd.oci.image.index.v1+json",
      digest: "sha256:" + String(repeating: "0", count: 64),
      size: 1
    )
    let image = ImageDescription(reference: "example.invalid/test:latest", descriptor: descriptor)
    let process = ProcessConfiguration(
      executable: "/bin/sh",
      arguments: [],
      environment: []
    )
    var configuration = ContainerConfiguration(id: id, image: image, process: process)
    configuration.labels = [
      "com.nativecontainers.creation-operation": operationID.uuidString
    ]
    configuration.creationDate = Date(timeIntervalSince1970: 1)
    return ContainerSnapshot(
      configuration: configuration,
      status: status,
      networks: []
    )
  }
}
