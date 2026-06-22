import Foundation
import Testing

@testable import NativeContainers

struct MacVirtualMachineSavedStateStoreTests {
  @Test
  func commitPublishesValidatedStateAndRestoreConsumesIt() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }

    let summary = try await fixture.commitState(Data("saved-memory".utf8))
    let inspection = try await fixture.store.inspect(for: fixture.lease)
    let restore = try await fixture.store.beginRestore(for: fixture.lease)

    #expect(inspection == .available(summary))
    #expect(restore.artifact.summary == summary)
    #expect(
      restore.artifact.stateURL.lastPathComponent
        == MacVirtualMachineSavedStateStore.stateFilename
    )
    #expect(restore.artifact.configurationFingerprint.count == 64)
    #expect(try permissions(at: restore.artifact.stateURL) == 0o600)
    #expect(
      try permissions(
        at: restore.artifact.stateURL.deletingLastPathComponent().appending(
          path: MacVirtualMachineSavedStateStore.metadataFilename
        )
      ) == 0o600
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.savedStateDirectory.path))

    try await fixture.store.finishRestore(restore, for: fixture.lease)
    #expect(try await fixture.store.inspect(for: fixture.lease) == .none)
    #expect(!FileManager.default.fileExists(atPath: restore.consumingDirectoryURL.path))
  }

  @Test
  func writableStorageMutationMakesSavedStateIncompatible() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("state".utf8))

    let disk = try FileHandle(forWritingTo: fixture.machine.diskImageURL)
    try disk.seekToEnd()
    try disk.write(contentsOf: Data([0xFF]))
    try disk.close()

    let inspection = try await fixture.store.inspect(for: fixture.lease)
    guard case .incompatible(let reason) = inspection else {
      Issue.record("Expected incompatible saved state")
      return
    }
    #expect(reason.contains("writable storage changed"))
    await #expect(throws: MacVirtualMachineSavedStateError.self) {
      _ = try await fixture.store.beginRestore(for: fixture.lease)
    }
  }

  @Test
  func hostOperatingSystemChangeIsRejectedBeforeRestoreAttempt() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("state".utf8))
    let metadataURL = fixture.savedStateDirectory.appending(
      path: MacVirtualMachineSavedStateStore.metadataFilename
    )
    let metadata = try JSONDecoder().decode(
      MacVirtualMachineSavedStateMetadata.self,
      from: Data(contentsOf: metadataURL)
    )
    let changed = MacVirtualMachineSavedStateMetadata(
      schemaVersion: metadata.schemaVersion,
      machineID: metadata.machineID,
      configurationFingerprint: metadata.configurationFingerprint,
      stateFilename: metadata.stateFilename,
      createdAt: metadata.createdAt,
      stateSizeBytes: metadata.stateSizeBytes,
      hostOperatingSystemVersion: "different host build"
    )
    try JSONEncoder().encode(changed).write(to: metadataURL, options: .atomic)

    let inspection = try await fixture.store.inspect(for: fixture.lease)
    guard case .incompatible(let reason) = inspection else {
      Issue.record("Expected host incompatibility")
      return
    }
    #expect(reason.contains("host operating system changed"))
  }

  @Test
  func recoveryDeletesInterruptedSaveRestoreAndDiscardTransactions() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("single-use".utf8))

    let restoringDirectory = fixture.transactionDirectory(
      suffix: MacVirtualMachineSavedStateStore.restoringSuffix
    )
    let partialDirectory = fixture.transactionDirectory(
      suffix: MacVirtualMachineSavedStateStore.stagingSuffix
    )
    let discardingDirectory = fixture.transactionDirectory(
      suffix: MacVirtualMachineSavedStateStore.discardingSuffix
    )
    try FileManager.default.moveItem(
      at: fixture.savedStateDirectory,
      to: restoringDirectory
    )
    try FileManager.default.createDirectory(
      at: partialDirectory,
      withIntermediateDirectories: false
    )
    try FileManager.default.createDirectory(
      at: discardingDirectory,
      withIntermediateDirectories: false
    )

    #expect(try await fixture.store.inspect(for: fixture.lease) == .none)
    #expect(!FileManager.default.fileExists(atPath: restoringDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: partialDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: discardingDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.savedStateDirectory.path))
  }

  @Test
  func activeTransactionPinsLeaseAndRejectsOverlap() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let transaction = try await fixture.store.beginSave(for: fixture.lease)

    await #expect(
      throws: MacVirtualMachineSavedStateError.operationInProgress(fixture.machine.manifest.id)
    ) {
      _ = try await fixture.store.beginSave(for: fixture.lease)
    }

    fixture.lease.release()
    #expect(fixture.releaseRecorder.count == 0)
    await fixture.store.abortSave(transaction, for: fixture.lease)
    #expect(fixture.releaseRecorder.count == 1)
    #expect(!FileManager.default.fileExists(atPath: transaction.stagingDirectoryURL.path))
  }

  @Test
  func committedCheckpointMustBeConsumedBeforeAnotherSave() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("checkpoint".utf8))

    await #expect(
      throws: MacVirtualMachineSavedStateError.checkpointAlreadyExists(
        fixture.machine.manifest.id
      )
    ) {
      _ = try await fixture.store.beginSave(for: fixture.lease)
    }
  }

  @Test
  func discardAtomicallyRemovesCommittedCheckpoint() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("checkpoint".utf8))

    try await fixture.store.discard(for: fixture.lease)

    #expect(try await fixture.store.inspect(for: fixture.lease) == .none)
    #expect(!FileManager.default.fileExists(atPath: fixture.savedStateDirectory.path))
  }

  @Test
  func reviewedReclamationRemovesOnlyTheUnchangedCheckpoint() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("reviewed-checkpoint".utf8))
    let candidate = try #require(
      try await fixture.store.prepareSavedStateReclamation(for: fixture.lease)
    )

    let removed = try await fixture.store.reclaimSavedState(
      candidate,
      for: fixture.lease
    )

    #expect(removed)
    #expect(try await fixture.store.inspect(for: fixture.lease) == .none)
  }

  @Test
  func reviewedReclamationRejectsAReplacementCheckpoint() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("first-checkpoint".utf8))
    let candidate = try #require(
      try await fixture.store.prepareSavedStateReclamation(for: fixture.lease)
    )
    try await fixture.store.discard(for: fixture.lease)
    let replacement = try await fixture.commitState(Data("replacement-checkpoint".utf8))

    let removed = try await fixture.store.reclaimSavedState(
      candidate,
      for: fixture.lease
    )

    #expect(!removed)
    #expect(try await fixture.store.inspect(for: fixture.lease) == .available(replacement))
  }

  @Test
  func releasedLeaseCannotInspectOrMutateSavedState() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    fixture.lease.release()

    await #expect(
      throws: MacVirtualMachineRuntimeError.staleTarget(fixture.lease.target)
    ) {
      _ = try await fixture.store.inspect(for: fixture.lease)
    }
  }

  @Test
  func symbolicStateFileIsRejectedWithoutDeletingItsTarget() async throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let outside = fixture.rootURL.appending(path: "Outside.state")
    try Data("outside".utf8).write(to: outside)
    let transaction = try await fixture.store.beginSave(for: fixture.lease)
    try FileManager.default.createSymbolicLink(
      at: transaction.stateURL,
      withDestinationURL: outside
    )

    await #expect(throws: MacVirtualMachineSavedStateError.self) {
      _ = try await fixture.store.commitSave(transaction, for: fixture.lease)
    }
    await fixture.store.abortSave(transaction, for: fixture.lease)
    #expect(try Data(contentsOf: outside) == Data("outside".utf8))
  }

  @Test
  func configurationDescriptorUsesStableLocallyAdministeredMACAddress() throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let service = MacVirtualMachineConfigurationDescriptorService()

    let first = try service.descriptor(for: fixture.machine)
    let second = try service.descriptor(for: fixture.machine)

    #expect(first == second)
    #expect(first.macAddress.split(separator: ":").count == 6)
    let firstOctet = try #require(UInt8(first.macAddress.prefix(2), radix: 16))
    #expect(firstOctet & 0b0000_0011 == 0b0000_0010)
  }

  @Test
  func configurationDescriptorIgnoresTheAppFacingDisplayName() throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let service = MacVirtualMachineConfigurationDescriptorService()

    let baseline = try service.descriptor(for: fixture.machine)
    let renamed = try service.descriptor(
      for: fixture.machine.withName("Renamed")
    )

    #expect(renamed == baseline)
  }

  @Test
  func hostAudioAdvancesTopologyWhileSharingRemainsOptional() throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let service = MacVirtualMachineConfigurationDescriptorService()

    let baseline = try service.descriptor(for: fixture.machine)
    let shared = try service.descriptor(
      for: fixture.machine.withSharedDirectories(
        MacVirtualMachineSharedDirectoryConfiguration(
          revision: 1,
          directories: []
        )
      )
    )
    let microphone = try service.descriptor(
      for: fixture.machine.withAudioConfiguration(
        MacVirtualMachineAudioConfiguration(
          revision: 1,
          isMicrophoneEnabled: true
        )
      )
    )

    #expect(
      MacVirtualMachineConfigurationDescriptor.directorySharingTopologyVersion
        < MacVirtualMachineConfigurationDescriptor.currentTopologyVersion
    )
    #expect(
      baseline.topologyVersion
        == MacVirtualMachineConfigurationDescriptor.currentTopologyVersion
    )
    #expect(baseline.audioDevices == ["VirtioSound/HostOutput"])
    #expect(baseline.audioConfigurationRevision == nil)
    #expect(
      microphone.audioDevices
        == ["VirtioSound/HostOutput", "VirtioSound/HostInput"]
    )
    #expect(microphone.audioConfigurationRevision == 1)
    #expect(microphone.topologyVersion == baseline.topologyVersion)
    #expect(baseline.directorySharingRevision == nil)
    #expect(baseline.sharedDirectories == nil)
    #expect(
      shared.topologyVersion
        == MacVirtualMachineConfigurationDescriptor.currentTopologyVersion
    )
    #expect(shared.audioDevices == baseline.audioDevices)
    #expect(shared.directorySharingRevision == 1)
    #expect(shared.sharedDirectories == [])
  }

  @Test
  func diskSnapshotFingerprintTracksTopologyAndLayerIdentity() throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let fingerprinter = MacVirtualMachineConfigurationFingerprinter()
    let mutation = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Checkpoint")
    let directoryURL = fixture.machine.bundleURL.appending(
      path: MacVirtualMachineDiskSnapshotLayer.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false
    )
    let layerURL = fixture.machine.bundleURL.appending(
      path: mutation.createdLayer.relativePath
    )
    try Data("layer-one".utf8).write(to: layerURL)
    let snapshotMachine = fixture.machine.withDiskSnapshots(
      mutation.configuration,
      layerURLs: [layerURL]
    )

    let descriptor = try MacVirtualMachineConfigurationDescriptorService()
      .descriptor(for: snapshotMachine)
    let baseline = try fingerprinter.fingerprint(for: fixture.machine)
    let original = try fingerprinter.fingerprint(for: snapshotMachine)
    try Data("layer-two-is-different".utf8).write(to: layerURL)
    let changed = try fingerprinter.fingerprint(for: snapshotMachine)

    #expect(descriptor.diskSnapshotRevision == 1)
    #expect(
      descriptor.diskSnapshotLayerPaths
        == [mutation.createdLayer.relativePath]
    )
    #expect(original != baseline)
    #expect(changed != original)
  }

  @Test
  func sharingFingerprintTracksSemanticsButNotBookmarkRenewal() throws {
    let fixture = try SavedStateStoreFixture()
    defer { fixture.remove() }
    let fingerprinter = MacVirtualMachineConfigurationFingerprinter()
    let identifier = UUID()
    let original = MacVirtualMachineSharedDirectory(
      id: identifier,
      guestName: "Projects",
      bookmarkData: Data("first-bookmark".utf8),
      lastKnownPath: "/old/Projects",
      sourceIdentity: .init(device: 2, inode: 3),
      readOnly: false
    )
    let renewed = MacVirtualMachineSharedDirectory(
      id: identifier,
      guestName: "Projects",
      bookmarkData: Data("renewed-bookmark".utf8),
      lastKnownPath: "/new/Projects",
      sourceIdentity: .init(device: 2, inode: 3),
      readOnly: false
    )
    let originalMachine = fixture.machine.withSharedDirectories(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [original]
      )
    )
    let renewedMachine = fixture.machine.withSharedDirectories(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [renewed]
      )
    )
    let revisedMachine = fixture.machine.withSharedDirectories(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 2,
        directories: [renewed]
      )
    )

    let baseline = try fingerprinter.fingerprint(for: fixture.machine)
    let originalFingerprint = try fingerprinter.fingerprint(for: originalMachine)
    let renewedFingerprint = try fingerprinter.fingerprint(for: renewedMachine)
    let revisedFingerprint = try fingerprinter.fingerprint(for: revisedMachine)

    #expect(originalFingerprint != baseline)
    #expect(renewedFingerprint == originalFingerprint)
    #expect(revisedFingerprint != originalFingerprint)
  }
}

extension ResolvedMacVirtualMachine {
  fileprivate func withName(_ name: String) throws -> ResolvedMacVirtualMachine {
    var manifest = manifest
    try manifest.rename(to: name)
    return ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: diskSnapshotLayerURLs,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      sharedDirectories: sharedDirectories
    )
  }

  fileprivate func withDiskSnapshots(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration,
    layerURLs: [URL]
  ) -> ResolvedMacVirtualMachine {
    var manifest = manifest
    manifest.macOSDiskSnapshotConfiguration = configuration
    return ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: layerURLs,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      sharedDirectories: sharedDirectories
    )
  }

  fileprivate func withAudioConfiguration(
    _ configuration: MacVirtualMachineAudioConfiguration
  ) -> ResolvedMacVirtualMachine {
    var manifest = manifest
    manifest.audioConfiguration = configuration
    return ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: diskSnapshotLayerURLs,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      sharedDirectories: sharedDirectories
    )
  }

  fileprivate func withSharedDirectories(
    _ configuration: MacVirtualMachineSharedDirectoryConfiguration
  ) -> ResolvedMacVirtualMachine {
    ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: diskSnapshotLayerURLs,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      sharedDirectories: configuration
    )
  }
}

private struct SavedStateStoreFixture {
  let rootURL: URL
  let machine: ResolvedMacVirtualMachine
  let lease: MacVirtualMachineRuntimeLease
  let releaseRecorder: SavedStateReleaseRecorder
  let store = MacVirtualMachineSavedStateStore()

  var savedStateDirectory: URL {
    machine.bundleURL.appending(
      path: MacVirtualMachineSavedStateStore.directoryName,
      directoryHint: .isDirectory
    )
  }

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-SavedStateTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let identifier = UUID()
    let bundle = rootURL.appending(
      path: "\(identifier.uuidString.lowercased()).nativevm",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    let diskURL = bundle.appending(path: "Disk.img")
    let auxiliaryStorageURL = bundle.appending(path: "AuxiliaryStorage")
    let hardwareModelURL = bundle.appending(path: "HardwareModel")
    let machineIdentifierURL = bundle.appending(path: "MachineIdentifier")
    try Data("disk".utf8).write(to: diskURL)
    try Data("auxiliary".utf8).write(to: auxiliaryStorageURL)
    try Data("hardware".utf8).write(to: hardwareModelURL)
    try Data("machine".utf8).write(to: machineIdentifierURL)

    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      id: identifier,
      name: "Saved State Test",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    manifest.auxiliaryStoragePath = "AuxiliaryStorage"
    manifest.hardwareModelPath = "HardwareModel"
    manifest.machineIdentifierPath = "MachineIdentifier"
    machine = ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundle,
      diskImageURL: diskURL,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL
    )
    let target = MacVirtualMachineRuntimeTarget(machineID: identifier, generation: UUID())
    let releaseRecorder = SavedStateReleaseRecorder()
    self.releaseRecorder = releaseRecorder
    lease = MacVirtualMachineRuntimeLease(machine: machine, target: target) {
      releaseRecorder.record()
    }
  }

  func commitState(_ data: Data) async throws -> MacVirtualMachineSavedStateSummary {
    let transaction = try await store.beginSave(for: lease)
    try data.write(to: transaction.stateURL)
    return try await store.commitSave(transaction, for: lease)
  }

  func transactionDirectory(suffix: String) -> URL {
    machine.bundleURL.appending(
      path:
        "\(MacVirtualMachineSavedStateStore.stagingPrefix)\(UUID().uuidString.lowercased())\(suffix)",
      directoryHint: .isDirectory
    )
  }

  func remove() {
    lease.release()
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private final class SavedStateReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func permissions(at url: URL) throws -> UInt16 {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return UInt16((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
}
