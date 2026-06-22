import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine disk snapshot service")
@MainActor
struct MacVirtualMachineDiskSnapshotServiceTests {
  @Test
  func snapshotReadsPersistenceWithoutRuntimeOwnership() async throws {
    let fixture = try DiskSnapshotServiceFixture()

    let snapshot = try await fixture.service.snapshot(
      id: fixture.machine.manifest.id
    )

    #expect(snapshot == .empty)
    #expect(await fixture.leaseStore.acquireCount == 0)
  }

  @Test
  func creationCommitsAfterLayerCreationAndReleasesLease() async throws {
    let fixture = try DiskSnapshotServiceFixture()

    let result = try await fixture.service.createSnapshot(
      named: "Before Upgrade",
      for: fixture.machine.manifest.id
    )

    #expect(result.configuration.snapshots.map(\.name) == ["Before Upgrade"])
    #expect(result.configuration.layers.count == 1)
    #expect(result.cleanupWarning == nil)
    #expect(fixture.layerStore.createdRetainedLayerCounts == [0])
    #expect(
      fixture.layerStore.createdTargetLogicalBytes
        == [fixture.machine.manifest.resources.diskBytes]
    )
    #expect(fixture.layerStore.removedLayerIDs.isEmpty)
    #expect(await fixture.persistence.commitCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func savedStateBlocksCreationBeforeTouchingLayers() async throws {
    let fixture = try DiskSnapshotServiceFixture(
      savedStateStatus: .available(
        MacVirtualMachineSavedStateSummary(
          createdAt: Date(),
          stateSizeBytes: 1
        )
      )
    )

    await #expect(
      throws: MacVirtualMachineDiskSnapshotError.savedStateMustBeDiscarded
    ) {
      _ = try await fixture.service.createSnapshot(
        named: "Blocked",
        for: fixture.machine.manifest.id
      )
    }

    #expect(fixture.layerStore.createdRetainedLayerCounts.isEmpty)
    #expect(await fixture.persistence.commitCount == 0)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func failedManifestCommitRemovesUncommittedLayer() async throws {
    let fixture = try DiskSnapshotServiceFixture(commitError: FixtureError.commit)

    await #expect(throws: FixtureError.commit) {
      _ = try await fixture.service.createSnapshot(
        named: "Rollback",
        for: fixture.machine.manifest.id
      )
    }

    #expect(fixture.layerStore.createdRetainedLayerCounts == [0])
    #expect(fixture.layerStore.removedLayerIDs.count == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func restoreCommitsPrunedHistoryBeforeReportingCleanupWarning() async throws {
    var configuration = MacVirtualMachineDiskSnapshotConfiguration.empty
    for name in ["Base", "Configured", "Experiment"] {
      configuration = try configuration.creatingSnapshot(
        named: name
      ).configuration
    }
    let fixture = try DiskSnapshotServiceFixture(
      configuration: configuration,
      removalError: FixtureError.cleanup
    )

    let result = try await fixture.service.restoreSnapshot(
      id: configuration.snapshots[1].id,
      for: fixture.machine.manifest.id
    )

    #expect(result.configuration.snapshots.map(\.name) == ["Base", "Configured"])
    #expect(result.configuration.layers.count == 2)
    #expect(fixture.layerStore.createdRetainedLayerCounts == [1])
    #expect(
      fixture.layerStore.createdTargetLogicalBytes
        == [fixture.machine.manifest.resources.diskBytes]
    )
    #expect(fixture.layerStore.removedLayerIDs.count == 2)
    #expect(result.cleanupWarning?.contains("cleanup") == true)
    #expect(await fixture.persistence.commitCount == 1)
  }
}

@MainActor
private struct DiskSnapshotServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let persistence: DiskSnapshotPersistence
  let leaseStore: DiskSnapshotLeaseStore
  let layerStore: DiskSnapshotLayerStore
  let releaseRecorder = DiskSnapshotLeaseReleaseRecorder()
  let service: MacVirtualMachineDiskSnapshotService

  init(
    configuration: MacVirtualMachineDiskSnapshotConfiguration = .empty,
    savedStateStatus: MacVirtualMachineSavedStateStatus = .none,
    commitError: (any Error)? = nil,
    removalError: (any Error)? = nil
  ) throws {
    machine = try makeDiskSnapshotMachine(configuration: configuration)
    persistence = DiskSnapshotPersistence(
      manifest: machine.manifest,
      commitError: commitError
    )
    leaseStore = DiskSnapshotLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    layerStore = DiskSnapshotLayerStore(removalError: removalError)
    service = MacVirtualMachineDiskSnapshotService(
      leasingStore: leaseStore,
      persistence: persistence,
      savedStateService: DiskSnapshotSavedStateService(
        status: savedStateStatus
      ),
      layerStore: layerStore
    )
  }
}

private actor DiskSnapshotPersistence:
  MacVirtualMachineDiskSnapshotPersisting
{
  private var manifest: VirtualMachineManifest
  private let commitError: (any Error)?
  private(set) var commitCount = 0

  init(
    manifest: VirtualMachineManifest,
    commitError: (any Error)?
  ) {
    self.manifest = manifest
    self.commitError = commitError
  }

  func macOSDiskSnapshotConfiguration(
    id: UUID
  ) -> MacVirtualMachineDiskSnapshotConfiguration {
    manifest.effectiveMacOSDiskSnapshotConfiguration
  }

  func commitMacOSDiskSnapshotConfiguration(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration,
    replacing expected: MacVirtualMachineDiskSnapshotConfiguration,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    commitCount += 1
    if let commitError {
      throw commitError
    }
    guard manifest.effectiveMacOSDiskSnapshotConfiguration == expected else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    manifest.macOSDiskSnapshotConfiguration = configuration
    return manifest
  }
}

private actor DiskSnapshotLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: DiskSnapshotLeaseReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: DiskSnapshotLeaseReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireMacOSRuntime(id: UUID) -> MacVirtualMachineRuntimeLease {
    acquireCount += 1
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

private final class DiskSnapshotLayerStore:
  MacVirtualMachineDiskSnapshotLayerStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let removalError: (any Error)?
  private var storedCreatedRetainedLayerCounts: [Int] = []
  private var storedCreatedTargetLogicalBytes: [UInt64] = []
  private var storedRemovedLayerIDs: [UUID] = []

  init(removalError: (any Error)?) {
    self.removalError = removalError
  }

  var createdRetainedLayerCounts: [Int] {
    lock.withLock { storedCreatedRetainedLayerCounts }
  }

  var removedLayerIDs: [UUID] {
    lock.withLock { storedRemovedLayerIDs }
  }

  var createdTargetLogicalBytes: [UInt64] {
    lock.withLock { storedCreatedTargetLogicalBytes }
  }

  func recoverUnreferencedLayers(
    in bundleURL: URL,
    configuration: MacVirtualMachineDiskSnapshotConfiguration
  ) {}

  func createLayer(
    _ layer: MacVirtualMachineDiskSnapshotLayer,
    baseURL: URL,
    retainedLayerURLs: [URL],
    targetLogicalBytes: UInt64,
    in bundleURL: URL
  ) -> URL {
    lock.withLock {
      storedCreatedRetainedLayerCounts.append(retainedLayerURLs.count)
      storedCreatedTargetLogicalBytes.append(targetLogicalBytes)
    }
    return bundleURL.appending(path: layer.relativePath)
  }

  func removeLayers(
    _ layers: [MacVirtualMachineDiskSnapshotLayer],
    in bundleURL: URL
  ) throws {
    lock.withLock {
      storedRemovedLayerIDs.append(contentsOf: layers.map(\.id))
    }
    if let removalError {
      throw removalError
    }
  }
}

@MainActor
private final class DiskSnapshotSavedStateService:
  MacVirtualMachineSavedStateInspecting
{
  let status: MacVirtualMachineSavedStateStatus

  init(status: MacVirtualMachineSavedStateStatus) {
    self.status = status
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateStatus {
    status
  }
}

private final class DiskSnapshotLeaseReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private enum FixtureError: LocalizedError {
  case commit
  case cleanup

  var errorDescription: String? {
    switch self {
    case .commit:
      "commit"
    case .cleanup:
      "cleanup"
    }
  }
}

private func makeDiskSnapshotMachine(
  configuration: MacVirtualMachineDiskSnapshotConfiguration
) throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Snapshot Service",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
  manifest.macOSDiskSnapshotConfiguration =
    configuration.hasSnapshots ? configuration : nil
  let bundleURL = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundleURL,
    diskImageURL: bundleURL.appending(path: "Disk.img"),
    diskSnapshotLayerURLs: configuration.layers.map {
      bundleURL.appending(path: $0.relativePath)
    },
    auxiliaryStorageURL: bundleURL.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundleURL.appending(path: "HardwareModel"),
    machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier")
  )
}
