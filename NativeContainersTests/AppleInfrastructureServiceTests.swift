import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple infrastructure service")
struct AppleInfrastructureServiceTests {
  @Test
  func cancellationAfterCommittedVolumeCreateRemovesOwnedResource() async throws {
    let transport = InfrastructureTransportDouble(createOutcome: .cancellationAfterCommit)
    let service = AppleInfrastructureService(
      infrastructureClient: transport,
      containerReader: EmptyContainerSnapshotReader(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try VolumeCreateRequest(
      operationID: UUID(),
      name: "cancelled-volume",
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let plan = try await service.prepareVolumeCreation(request)

    await #expect(throws: CancellationError.self) {
      try await service.createVolume(plan)
    }
    #expect(await transport.volumeNames.isEmpty)
    #expect(await transport.deletedVolumeNames == ["cancelled-volume"])
  }

  @Test
  func realCallerCancellationAfterCommitRemovesOwnedResource() async throws {
    let transport = InfrastructureTransportDouble(
      createOutcome: .waitForCallerCancellationAfterCommit)
    let service = AppleInfrastructureService(
      infrastructureClient: transport,
      containerReader: EmptyContainerSnapshotReader(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try VolumeCreateRequest(
      operationID: UUID(),
      name: "caller-cancelled-volume",
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let plan = try await service.prepareVolumeCreation(request)
    let operation = Task {
      try await service.createVolume(plan)
    }
    while !(await transport.hasStartedCreate) {
      await Task.yield()
    }

    operation.cancel()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
    #expect(await transport.volumeNames.isEmpty)
    #expect(await transport.deletedVolumeNames == ["caller-cancelled-volume"])
  }

  @Test
  func volumePrunePreparationPropagatesDiskUsageCancellation() async throws {
    let volume = VolumeConfiguration(
      name: "slow-volume",
      driver: "local",
      source: "/tmp/slow-volume.img",
      creationDate: Date(timeIntervalSince1970: 1),
      labels: [:],
      options: ["size": "67108864B"],
      sizeInBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let transport = InfrastructureTransportDouble(
      createOutcome: .success,
      initialVolumes: [volume],
      blockDiskUsageUntilCancellation: true
    )
    let service = AppleInfrastructureService(
      infrastructureClient: transport,
      containerReader: EmptyContainerSnapshotReader(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let operation = Task {
      try await service.prepareVolumePrune()
    }
    while !(await transport.hasStartedDiskUsage) {
      await Task.yield()
    }

    operation.cancel()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
  }

  @Test
  func volumePrunePreservesComposeLabeledNamedVolumes() async throws {
    let composeVolume = VolumeConfiguration(
      name: "app-data-runtime",
      driver: "local",
      source: "/tmp/app-data-runtime.img",
      creationDate: Date(timeIntervalSince1970: 1),
      labels: [
        ComposeLabelKey.project: "app",
        ComposeLabelKey.volume: "data",
      ],
      options: ["size": "67108864B"],
      sizeInBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let scratchVolume = VolumeConfiguration(
      name: "scratch",
      driver: "local",
      source: "/tmp/scratch.img",
      creationDate: Date(timeIntervalSince1970: 2),
      labels: [:],
      options: ["size": "67108864B"],
      sizeInBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let transport = InfrastructureTransportDouble(
      createOutcome: .success,
      initialVolumes: [composeVolume, scratchVolume]
    )
    let service = AppleInfrastructureService(
      infrastructureClient: transport,
      containerReader: EmptyContainerSnapshotReader(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    let plan = try await service.prepareVolumePrune()

    #expect(plan.candidates.map(\.volume.name) == ["scratch"])
  }

  @Test
  func timeoutAfterCommittedVolumeCreateReconcilesAsSuccess() async throws {
    let transport = InfrastructureTransportDouble(createOutcome: .timeoutAfterCommit)
    let service = AppleInfrastructureService(
      infrastructureClient: transport,
      containerReader: EmptyContainerSnapshotReader(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try VolumeCreateRequest(
      operationID: UUID(),
      name: "reconciled-volume",
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let plan = try await service.prepareVolumeCreation(request)

    let created = try await service.createVolume(plan)

    #expect(created.name == "reconciled-volume")
    #expect(await transport.volumeNames == ["reconciled-volume"])
    #expect(await transport.deletedVolumeNames.isEmpty)
  }
}

private enum InfrastructureCreateOutcome: Sendable {
  case success
  case cancellationAfterCommit
  case waitForCallerCancellationAfterCommit
  case timeoutAfterCommit
}

private actor InfrastructureTransportDouble: AppleInfrastructureTransport {
  private let createOutcome: InfrastructureCreateOutcome
  private let blockDiskUsageUntilCancellation: Bool
  private var volumes: [VolumeConfiguration]
  private(set) var deletedVolumeNames: [String] = []
  private(set) var hasStartedCreate = false
  private(set) var hasStartedDiskUsage = false

  init(
    createOutcome: InfrastructureCreateOutcome,
    initialVolumes: [VolumeConfiguration] = [],
    blockDiskUsageUntilCancellation: Bool = false
  ) {
    self.createOutcome = createOutcome
    self.volumes = initialVolumes
    self.blockDiskUsageUntilCancellation = blockDiskUsageUntilCancellation
  }

  var volumeNames: [String] {
    volumes.map(\.name)
  }

  func createVolume(
    name: String,
    driver: String,
    driverOptions: [String: String],
    labels: [String: String]
  ) async throws -> VolumeConfiguration {
    let configuration = VolumeConfiguration(
      name: name,
      driver: driver,
      source: "/tmp/\(name).img",
      creationDate: Date(timeIntervalSince1970: 1),
      labels: labels,
      options: driverOptions,
      sizeInBytes: driverOptions["size"].flatMap(Self.parseByteCount)
    )
    volumes.append(configuration)
    hasStartedCreate = true

    switch createOutcome {
    case .success:
      return configuration
    case .cancellationAfterCommit:
      throw CancellationError()
    case .waitForCallerCancellationAfterCommit:
      try await Task.sleep(for: .seconds(60))
      return configuration
    case .timeoutAfterCommit:
      throw ResourceManagementError.operationTimedOut("Create volume")
    }
  }

  func deleteVolume(name: String) async throws {
    deletedVolumeNames.append(name)
    volumes.removeAll { $0.name == name }
  }

  func listVolumes() async throws -> [VolumeConfiguration] {
    volumes
  }

  func volumeDiskUsage(name: String) async throws -> UInt64 {
    hasStartedDiskUsage = true
    if blockDiskUsageUntilCancellation {
      try await Task.sleep(for: .seconds(60))
    }
    return 1_048_576
  }

  func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkResource {
    throw ResourceManagementError.unsupported
  }

  func deleteNetwork(id: String) async throws {
    throw ResourceManagementError.unsupported
  }

  func listNetworks() async throws -> [NetworkResource] {
    []
  }

  private static func parseByteCount(_ value: String) -> UInt64? {
    guard value.hasSuffix("B") else { return nil }
    return UInt64(value.dropLast())
  }
}

private struct EmptyContainerSnapshotReader: ContainerSnapshotReading {
  func list() async throws -> [ContainerSnapshot] {
    []
  }

  func get(id: String) async throws -> ContainerSnapshot {
    throw ResourceManagementError.containerNotRunning(id)
  }
}
