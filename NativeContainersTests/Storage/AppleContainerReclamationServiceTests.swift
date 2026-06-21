import ContainerResource
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import NativeContainers

@Suite("Apple container reclamation service")
struct AppleContainerReclamationServiceTests {
  @Test
  func preparationIncludesOnlyStoppedOwnedOrdinaryContainers() async throws {
    let owned = UUID()
    let snapshots = [
      try makeSnapshot(id: "eligible", operationID: owned),
      try makeSnapshot(id: "running", operationID: owned, status: .running),
      try makeSnapshot(id: "stopping", operationID: owned, status: .stopping),
      try makeSnapshot(id: "unknown", operationID: owned, status: .unknown),
      try makeSnapshot(id: "unowned", operationID: nil),
      try makeSnapshot(
        id: "compose",
        operationID: owned,
        extraLabels: [ComposeLabelKey.project: "demo"]
      ),
      try makeSnapshot(
        id: "machine",
        operationID: owned,
        extraLabels: [ResourceOperationLabel.applePluginKey: "machine"]
      ),
      try makeSnapshot(
        id: "role",
        operationID: owned,
        extraLabels: [ResourceOperationLabel.appleResourceRoleKey: "system"]
      ),
      try makeSnapshot(id: ContainerBuilderRecord.containerID, operationID: owned),
    ]
    let transport = ContainerReclamationTransportDouble(snapshots: snapshots)
    let service = makeService(transport: transport)

    let plan = try await service.prepareContainerPrune()

    #expect(plan.candidates.map(\.id) == ["eligible"])
    #expect(plan.candidates.first?.allocatedBytes == 512)
  }

  @Test
  func configurationDriftAndRunningTransitionAreSkippedWithoutDeletion() async throws {
    let operationID = UUID()
    let transport = ContainerReclamationTransportDouble(
      snapshots: [
        try makeSnapshot(id: "drifted", operationID: operationID),
        try makeSnapshot(id: "started", operationID: operationID),
      ]
    )
    let service = makeService(transport: transport)
    let plan = try await service.prepareContainerPrune()

    await transport.addLabel(id: "drifted", key: "example.changed", value: "yes")
    await transport.setStatus(id: "started", status: .running)
    let result = try await service.pruneContainers(plan)

    #expect(result.removedContainerIDs.isEmpty)
    #expect(result.failedContainers.map(\.resource).sorted() == ["drifted", "started"])
    #expect(await transport.deletedIDs.isEmpty)
  }

  @Test
  func confirmedDeletionReportsMeasuredBytesAndCleansOwnedSocketWorkspace() async throws {
    let operationID = UUID()
    let snapshot = try makeSnapshot(
      id: "socket-app",
      operationID: operationID,
      publishesSocket: true
    )
    let transport = ContainerReclamationTransportDouble(
      snapshots: [snapshot],
      diskUsage: 4_096
    )
    let sockets = PublishedSocketWorkspaceDouble()
    let service = makeService(
      transport: transport,
      attachmentService: sockets
    )
    let plan = try await service.prepareContainerPrune()

    let result = try await service.pruneContainers(plan)

    #expect(result.removedContainerIDs == ["socket-app"])
    #expect(result.removedAllocatedBytes == 4_096)
    #expect(await transport.deletedIDs == ["socket-app"])
    #expect(await sockets.cleanedOperationIDs == [operationID])
  }

  @Test
  func cancellationAfterCommittedDeletionPreservesPartialResult() async throws {
    let operationID = UUID()
    let transport = ContainerReclamationTransportDouble(
      snapshots: [
        try makeSnapshot(id: "first", operationID: operationID),
        try makeSnapshot(id: "second", operationID: operationID),
      ],
      deleteOutcome: .cancellationAfterCommit
    )
    let service = makeService(transport: transport)
    let plan = try await service.prepareContainerPrune()

    do {
      _ = try await service.pruneContainers(plan)
      Issue.record("Expected partial completion")
    } catch let partial as ContainerCleanupPartialCompletionError {
      #expect(partial.result.removedContainerIDs == ["first"])
      #expect(partial.result.failedContainers.map(\.resource) == ["second"])
    }

    #expect(await transport.deletedIDs == ["first"])
    #expect(await transport.remainingIDs == ["second"])
  }

  @Test
  func timeoutAfterCommittedDeletionReconcilesAsSuccess() async throws {
    let operationID = UUID()
    let transport = ContainerReclamationTransportDouble(
      snapshots: [try makeSnapshot(id: "timed-out", operationID: operationID)],
      deleteOutcome: .timeoutAfterCommit
    )
    let service = makeService(transport: transport)
    let plan = try await service.prepareContainerPrune()

    let result = try await service.pruneContainers(plan)

    #expect(result.removedContainerIDs == ["timed-out"])
    #expect(result.failedContainers.isEmpty)
  }

  private func makeService(
    transport: ContainerReclamationTransportDouble,
    attachmentService: PublishedSocketWorkspaceDouble = PublishedSocketWorkspaceDouble()
  ) -> AppleContainerReclamationService {
    AppleContainerReclamationService(
      transport: transport,
      attachmentService: attachmentService,
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      now: { Date(timeIntervalSince1970: 10) },
      reconciliationAttempts: 1,
      sleep: { _ in }
    )
  }

  private func makeSnapshot(
    id: String,
    operationID: UUID?,
    status: RuntimeStatus = .stopped,
    extraLabels: [String: String] = [:],
    publishesSocket: Bool = false
  ) throws -> ContainerSnapshot {
    let descriptor = Descriptor(
      mediaType: "application/vnd.oci.image.index.v1+json",
      digest: "sha256:" + String(repeating: "a", count: 64),
      size: 1
    )
    let image = ImageDescription(
      reference: "example.invalid/\(id):latest",
      descriptor: descriptor
    )
    let process = ProcessConfiguration(
      executable: "/bin/sh",
      arguments: [],
      environment: []
    )
    var configuration = ContainerConfiguration(
      id: id,
      image: image,
      process: process
    )
    if let operationID {
      configuration.labels[AppleContainerOwnership.creationOperationLabel] =
        operationID.uuidString
    }
    configuration.labels.merge(extraLabels) { _, new in new }
    configuration.creationDate = Date(timeIntervalSince1970: 1)
    if publishesSocket {
      configuration.publishedSockets = [
        try PublishSocket(
          containerPath: FilePath("/run/app.sock"),
          hostPath: FilePath("/tmp/\(id).sock")
        )
      ]
    }
    return ContainerSnapshot(
      configuration: configuration,
      status: status,
      networks: []
    )
  }
}

private enum ContainerDeleteOutcome: Sendable {
  case success
  case cancellationAfterCommit
  case timeoutAfterCommit
}

private actor ContainerReclamationTransportDouble:
  ContainerReclamationTransport
{
  private var snapshots: [ContainerSnapshot]
  private let diskUsageValue: UInt64
  private let deleteOutcome: ContainerDeleteOutcome
  private(set) var deletedIDs: [String] = []

  init(
    snapshots: [ContainerSnapshot],
    diskUsage: UInt64 = 512,
    deleteOutcome: ContainerDeleteOutcome = .success
  ) {
    self.snapshots = snapshots
    diskUsageValue = diskUsage
    self.deleteOutcome = deleteOutcome
  }

  var remainingIDs: [String] {
    snapshots.map(\.id).sorted()
  }

  func list(ids: [String]) async throws -> [ContainerSnapshot] {
    guard !ids.isEmpty else { return snapshots }
    let ids = Set(ids)
    return snapshots.filter { ids.contains($0.id) }
  }

  func diskUsage(id: String) async throws -> UInt64 {
    diskUsageValue
  }

  func deleteStopped(id: String) async throws {
    deletedIDs.append(id)
    snapshots.removeAll { $0.id == id }
    switch deleteOutcome {
    case .success:
      return
    case .cancellationAfterCommit:
      throw CancellationError()
    case .timeoutAfterCommit:
      throw ResourceManagementError.operationTimedOut("Delete stopped container")
    }
  }

  func setStatus(id: String, status: RuntimeStatus) {
    guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
    snapshots[index].status = status
  }

  func addLabel(id: String, key: String, value: String) {
    guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
    snapshots[index].configuration.labels[key] = value
  }
}

private actor PublishedSocketWorkspaceDouble:
  ContainerAttachmentWorkspaceManaging
{
  private(set) var cleanedOperationIDs: [UUID] = []

  func validateAttachmentsBeforeStart(
    _ configuration: ContainerConfiguration,
    operationID: UUID
  ) async throws -> ContainerHostDirectoryAccess? { nil }

  func cleanupAttachmentWorkspace(operationID: UUID) async {
    cleanedOperationIDs.append(operationID)
  }
}
