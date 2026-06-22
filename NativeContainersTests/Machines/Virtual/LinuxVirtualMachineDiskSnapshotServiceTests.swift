import Foundation
import Testing

@testable import NativeContainers

@Suite("Linux virtual machine disk snapshot service")
@MainActor
struct LinuxVirtualMachineDiskSnapshotServiceTests {
  @Test
  func snapshotReadsPersistenceWithoutRuntimeOwnership() async throws {
    let fixture = try LinuxDiskSnapshotServiceFixture()

    let snapshot = try await fixture.service.snapshot(
      id: fixture.machine.manifest.id
    )

    #expect(snapshot == .empty)
    #expect(await fixture.leaseStore.acquireCount == 0)
  }

  @Test
  func creationCommitsAfterLayerCreationAndReleasesLease() async throws {
    let fixture = try LinuxDiskSnapshotServiceFixture()

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
    #expect(await fixture.persistence.commitCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func savedStateBlocksCreationBeforeTouchingLayers() async throws {
    let fixture = try LinuxDiskSnapshotServiceFixture(
      savedStateStatus: .available(
        LinuxVirtualMachineSavedStateSummary(
          createdAt: Date(),
          stateSizeBytes: 1
        )
      )
    )

    await #expect(
      throws: VirtualMachineDiskSnapshotError.savedStateMustBeDiscarded
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
  func installerStateBlocksCreationBeforeSavedStateOrLayers() async throws {
    let fixture = try LinuxDiskSnapshotServiceFixture(
      installState: .readyToInstall
    )

    await #expect(
      throws: VirtualMachineModelError.invalidInstallState(.readyToInstall)
    ) {
      _ = try await fixture.service.createSnapshot(
        named: "Too Early",
        for: fixture.machine.manifest.id
      )
    }

    #expect(fixture.savedStateInspector.inspectCount == 0)
    #expect(fixture.layerStore.createdRetainedLayerCounts.isEmpty)
    #expect(await fixture.persistence.commitCount == 0)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func restoreCommitsPrunedHistoryThenRemovesRetiredLayers() async throws {
    var configuration = VirtualMachineDiskSnapshotConfiguration.empty
    for name in ["Base", "Configured", "Experiment"] {
      configuration = try configuration.creatingSnapshot(
        named: name
      ).configuration
    }
    let fixture = try LinuxDiskSnapshotServiceFixture(
      configuration: configuration
    )

    let result = try await fixture.service.restoreSnapshot(
      id: configuration.snapshots[1].id,
      for: fixture.machine.manifest.id
    )

    #expect(result.configuration.snapshots.map(\.name) == ["Base", "Configured"])
    #expect(result.configuration.layers.count == 2)
    #expect(fixture.layerStore.createdRetainedLayerCounts == [1])
    #expect(fixture.layerStore.removedLayerIDs.count == 2)
    #expect(await fixture.persistence.commitCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }
}

@MainActor
private struct LinuxDiskSnapshotServiceFixture {
  let machine: ResolvedLinuxVirtualMachine
  let persistence: LinuxDiskSnapshotPersistence
  let leaseStore: LinuxDiskSnapshotLeaseStore
  let layerStore: LinuxDiskSnapshotLayerStore
  let savedStateInspector: LinuxDiskSnapshotSavedStateInspector
  let releaseRecorder = LinuxDiskSnapshotLeaseReleaseRecorder()
  let service: LinuxVirtualMachineDiskSnapshotService

  init(
    configuration: VirtualMachineDiskSnapshotConfiguration = .empty,
    installState: VirtualMachineInstallState = .stopped,
    savedStateStatus: LinuxVirtualMachineSavedStateStatus = .none
  ) throws {
    machine = try makeLinuxDiskSnapshotMachine(
      configuration: configuration,
      installState: installState
    )
    persistence = LinuxDiskSnapshotPersistence(manifest: machine.manifest)
    leaseStore = LinuxDiskSnapshotLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    layerStore = LinuxDiskSnapshotLayerStore()
    savedStateInspector = LinuxDiskSnapshotSavedStateInspector(
      status: savedStateStatus
    )
    service = LinuxVirtualMachineDiskSnapshotService(
      linuxLeasingStore: leaseStore,
      linuxPersistence: persistence,
      linuxSavedStateService: savedStateInspector,
      layerStore: layerStore
    )
  }
}

private actor LinuxDiskSnapshotPersistence:
  LinuxVirtualMachineDiskSnapshotPersisting
{
  private var manifest: VirtualMachineManifest
  private(set) var commitCount = 0

  init(manifest: VirtualMachineManifest) {
    self.manifest = manifest
  }

  func linuxDiskSnapshotConfiguration(
    id: UUID
  ) -> VirtualMachineDiskSnapshotConfiguration {
    manifest.effectiveLinuxDiskSnapshotConfiguration
  }

  func commitLinuxDiskSnapshotConfiguration(
    _ configuration: VirtualMachineDiskSnapshotConfiguration,
    replacing expected: VirtualMachineDiskSnapshotConfiguration,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    commitCount += 1
    guard manifest.effectiveLinuxDiskSnapshotConfiguration == expected else {
      throw LinuxVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    manifest.linuxDiskSnapshotConfiguration = configuration
    return manifest
  }
}

private actor LinuxDiskSnapshotLeaseStore:
  LinuxVirtualMachineRuntimeLeasing
{
  let machine: ResolvedLinuxVirtualMachine
  let releaseRecorder: LinuxDiskSnapshotLeaseReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedLinuxVirtualMachine,
    releaseRecorder: LinuxDiskSnapshotLeaseReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireLinuxRuntime(id: UUID) -> LinuxVirtualMachineRuntimeLease {
    acquireCount += 1
    return LinuxVirtualMachineRuntimeLease(
      machine: machine,
      target: LinuxVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

private final class LinuxDiskSnapshotLayerStore:
  VirtualMachineDiskSnapshotLayerStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedCreatedRetainedLayerCounts: [Int] = []
  private var storedCreatedTargetLogicalBytes: [UInt64] = []
  private var storedRemovedLayerIDs: [UUID] = []

  var createdRetainedLayerCounts: [Int] {
    lock.withLock { storedCreatedRetainedLayerCounts }
  }

  var createdTargetLogicalBytes: [UInt64] {
    lock.withLock { storedCreatedTargetLogicalBytes }
  }

  var removedLayerIDs: [UUID] {
    lock.withLock { storedRemovedLayerIDs }
  }

  func recoverUnreferencedLayers(
    in bundleURL: URL,
    configuration: VirtualMachineDiskSnapshotConfiguration
  ) {}

  func createLayer(
    _ layer: VirtualMachineDiskSnapshotLayer,
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
    _ layers: [VirtualMachineDiskSnapshotLayer],
    in bundleURL: URL
  ) {
    lock.withLock {
      storedRemovedLayerIDs.append(contentsOf: layers.map(\.id))
    }
  }
}

@MainActor
private final class LinuxDiskSnapshotSavedStateInspector:
  LinuxVirtualMachineSavedStateInspecting
{
  let status: LinuxVirtualMachineSavedStateStatus
  private(set) var inspectCount = 0

  init(status: LinuxVirtualMachineSavedStateStatus) {
    self.status = status
  }

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) -> LinuxVirtualMachineSavedStateStatus {
    inspectCount += 1
    return status
  }
}

private final class LinuxDiskSnapshotLeaseReleaseRecorder:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func makeLinuxDiskSnapshotMachine(
  configuration: VirtualMachineDiskSnapshotConfiguration,
  installState: VirtualMachineInstallState
) throws -> ResolvedLinuxVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Linux Snapshot",
    guest: .linux,
    installState: installState,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
  manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
    efiVariableStorePath: "Platform/EFI.nvram",
    machineIdentifierPath: "Platform/MachineIdentifier.bin",
    installationMediaPath: installState == .readyToInstall
      ? "Platform/Installer.iso" : nil,
    macAddress: "02:00:00:00:00:01"
  )
  manifest.linuxDiskSnapshotConfiguration = configuration

  let bundleURL = URL(filePath: "/tmp/\(identifier.uuidString).nativevm")
  return ResolvedLinuxVirtualMachine(
    manifest: manifest,
    bundleURL: bundleURL,
    diskImageURL: bundleURL.appending(path: manifest.diskImagePath),
    diskSnapshotLayerURLs: configuration.layers.map {
      bundleURL.appending(path: $0.relativePath)
    },
    efiVariableStoreURL: bundleURL.appending(path: "Platform/EFI.nvram"),
    machineIdentifierURL: bundleURL.appending(
      path: "Platform/MachineIdentifier.bin"
    ),
    installationMediaURL: nil
  )
}
