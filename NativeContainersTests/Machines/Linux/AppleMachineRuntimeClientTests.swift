import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import TerminalProgress
import Testing

@testable import NativeContainers

@Suite("Apple machine runtime client")
struct AppleMachineRuntimeClientTests {
  @Test
  func delegatesCreationPreparationAndTransportThroughFocusedServices() async throws {
    let source = try makeMachineSnapshot(initialized: false)
    let stopped = MachineSnapshot(
      configuration: source.configuration,
      status: .stopped,
      bootConfig: source.bootConfig,
      createdDate: source.createdDate,
      diskSize: source.diskSize,
      initialized: false
    )
    let preparation = MachinePreparationDouble(
      prepared: PreparedLinuxMachineCreation(
        configuration: stopped.configuration,
        resources: nil,
        bootConfig: stopped.bootConfig
      )
    )
    let transport = MachineRuntimeTransportDouble(snapshot: stopped)
    let runtime = AppleMachineRuntimeClient(
      imagePreparation: preparation,
      machineTransport: transport
    )
    let request = try LinuxMachineCreationRequest(
      name: "dev",
      imageReference: "alpine:3.22",
      cpuCount: 4,
      memoryBytes: 2_048 * LinuxMachineCreationRequest.bytesPerMiB,
      homeMount: .none
    )
    let progress = ProgressRecorderForRuntime()

    let created = try await runtime.create(request: request) { update in
      await progress.record(update)
    }

    #expect(created.identity.id == "dev")
    #expect(created.state == .stopped)
    #expect(created.imageDigest == stopped.configuration.image.digest)
    #expect(created.startedAt == nil)
    #expect(await preparation.requestNames == ["dev"])
    #expect(await transport.createdIDs == ["dev"])
    #expect(
      await progress.phases == [
        ContainerOperationProgress.Phase.preparing,
        ContainerOperationProgress.Phase.fetchingImage,
        ContainerOperationProgress.Phase.creating,
      ]
    )
  }

  @Test
  func stoppedMachineSnapshotCreateUsesReviewedGenerationAndCatalogRevision() async throws {
    let machine = try makeMachineSnapshot(initialized: true)
    let stopped = MachineSnapshot(
      configuration: machine.configuration,
      status: .stopped,
      bootConfig: machine.bootConfig,
      createdDate: machine.createdDate,
      diskSize: machine.diskSize,
      initialized: true
    )
    let target = AppleLinuxMachineSnapshotMapper.identity(from: stopped)
    let initial = MachineSnapshotCatalogV1(
      machineID: target.id,
      machineGeneration: 7,
      catalogRevision: 11,
      snapshots: []
    )
    let createdMetadata = MachineSnapshotMetadataV1(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      machineID: target.id,
      name: "before-upgrade",
      createdAt: Date(timeIntervalSince1970: 1_000),
      allocatedSize: 4_096,
      capturedMachineGeneration: 7
    )
    let created = MachineSnapshotCatalogV1(
      machineID: target.id,
      machineGeneration: 7,
      catalogRevision: 12,
      snapshots: [createdMetadata]
    )
    let snapshotTransport = MachineSnapshotTransportDouble(
      listedCatalog: initial,
      createdCatalog: created
    )
    let service = AppleLinuxMachineSnapshotService(
      machineTransport: MachineRuntimeTransportDouble(snapshot: stopped),
      snapshotTransport: snapshotTransport,
      runtimeVerifier: MachineSnapshotRuntimeVerifierDouble(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    let reviewed = try await service.loadSnapshots(for: target)
    let result = try await service.createSnapshot(named: "before-upgrade", in: reviewed)

    #expect(result.catalogRevision == 12)
    #expect(result.snapshots.map(\.name) == ["before-upgrade"])
    let request = try #require(await snapshotTransport.createRequests.first)
    #expect(request.machineID == target.id)
    #expect(request.precondition.machineGeneration == 7)
    #expect(request.precondition.catalogRevision == 11)
  }

  @Test
  func runningMachineCannotLoadOrMutateSnapshotCatalog() async throws {
    let machine = try makeMachineSnapshot(initialized: true)
    let target = AppleLinuxMachineSnapshotMapper.identity(from: machine)
    let snapshotTransport = MachineSnapshotTransportDouble(
      listedCatalog: MachineSnapshotCatalogV1(
        machineID: target.id,
        machineGeneration: 1,
        catalogRevision: 0,
        snapshots: []
      )
    )
    let service = AppleLinuxMachineSnapshotService(
      machineTransport: MachineRuntimeTransportDouble(snapshot: machine),
      snapshotTransport: snapshotTransport,
      runtimeVerifier: MachineSnapshotRuntimeVerifierDouble(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    await #expect(throws: LinuxMachineSnapshotError.machineMustBeStopped(target.id)) {
      _ = try await service.loadSnapshots(for: target)
    }
    #expect(await snapshotTransport.listRequests.isEmpty)
  }
}

private enum MachineRuntimeDoubleError: Error {
  case unsupported
}

private actor MachinePreparationDouble: LinuxMachineImagePreparing {
  private let prepared: PreparedLinuxMachineCreation
  private(set) var requestNames: [String] = []

  init(prepared: PreparedLinuxMachineCreation) {
    self.prepared = prepared
  }

  func prepare(
    request: LinuxMachineCreationRequest,
    progressUpdate: @escaping ProgressUpdateHandler
  ) async -> PreparedLinuxMachineCreation {
    requestNames.append(request.name)
    await progressUpdate([.setDescription("Fetching image")])
    return prepared
  }
}

private actor MachineRuntimeTransportDouble: AppleMachineTransport {
  private let snapshot: MachineSnapshot
  private(set) var createdIDs: [String] = []

  init(snapshot: MachineSnapshot) {
    self.snapshot = snapshot
  }

  func list() -> [MachineSnapshot] {
    [snapshot]
  }

  func inspect(id: String) -> MachineSnapshot {
    snapshot
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) {
    createdIDs.append(configuration.id)
  }

  func boot(
    id: String,
    dynamicEnvironment: [String: String]
  ) throws -> MachineSnapshot {
    throw MachineRuntimeDoubleError.unsupported
  }

  func setConfig(id: String, bootConfig: MachineConfig) throws {
    throw MachineRuntimeDoubleError.unsupported
  }

  func stop(id: String) throws {
    throw MachineRuntimeDoubleError.unsupported
  }

  func delete(id: String) throws {
    throw MachineRuntimeDoubleError.unsupported
  }
}

private actor MachineSnapshotTransportDouble: LinuxMachineSnapshotTransport {
  let listedCatalog: MachineSnapshotCatalogV1
  let createdCatalog: MachineSnapshotCatalogV1
  private(set) var listRequests: [String] = []
  private(set) var createRequests: [MachineSnapshotCreateRequestV1] = []

  init(
    listedCatalog: MachineSnapshotCatalogV1,
    createdCatalog: MachineSnapshotCatalogV1? = nil
  ) {
    self.listedCatalog = listedCatalog
    self.createdCatalog = createdCatalog ?? listedCatalog
  }

  func list(machineID: String) -> MachineSnapshotCatalogV1 {
    listRequests.append(machineID)
    return listedCatalog
  }

  func create(
    _ request: MachineSnapshotCreateRequestV1
  ) -> MachineSnapshotCatalogV1 {
    createRequests.append(request)
    return createdCatalog
  }

  func restore(
    _ request: MachineSnapshotRestoreRequestV1
  ) throws -> MachineSnapshotCatalogV1 {
    throw MachineRuntimeDoubleError.unsupported
  }

  func clone(
    _ request: MachineSnapshotCloneRequestV1
  ) throws -> MachineSnapshotCloneResultV1 {
    throw MachineRuntimeDoubleError.unsupported
  }

  func delete(
    _ request: MachineSnapshotDeleteRequestV1
  ) throws -> MachineSnapshotCatalogV1 {
    throw MachineRuntimeDoubleError.unsupported
  }
}

private struct MachineSnapshotRuntimeVerifierDouble:
  LinuxMachineSnapshotRuntimeVerifying
{
  func verifySnapshotSupport() async throws {}
}

private actor ProgressRecorderForRuntime {
  private(set) var phases: [ContainerOperationProgress.Phase] = []

  func record(_ progress: ContainerOperationProgress) {
    phases.append(progress.phase)
  }
}
