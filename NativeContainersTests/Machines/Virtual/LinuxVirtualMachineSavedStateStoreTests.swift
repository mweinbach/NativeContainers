import Foundation
import Testing

@testable import NativeContainers

struct LinuxVirtualMachineSavedStateStoreTests {
  @Test
  func commitPublishesValidatedStateAndRestoreConsumesIt() async throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }

    let summary = try await fixture.commitState(Data("saved-linux-memory".utf8))
    let inspection = try await fixture.store.inspect(for: fixture.lease)
    let restore = try await fixture.store.beginRestore(for: fixture.lease)

    #expect(inspection == .available(summary))
    #expect(restore.artifact.summary == summary)
    #expect(
      restore.artifact.stateURL.lastPathComponent
        == LinuxVirtualMachineSavedStateStore.stateFilename
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.savedStateDirectory.path))

    try await fixture.store.finishRestore(restore, for: fixture.lease)
    #expect(try await fixture.store.inspect(for: fixture.lease) == .none)
  }

  @Test
  func diskMutationMakesLinuxSavedStateIncompatible() async throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("state".utf8))

    try append(0xFF, to: fixture.machine.diskImageURL)

    guard
      case .incompatible(let reason) =
        try await fixture.store.inspect(for: fixture.lease)
    else {
      Issue.record("Expected an incompatible Linux saved state")
      return
    }
    #expect(reason.contains("writable storage changed"))
  }

  @Test
  func efiVariableMutationMakesLinuxSavedStateIncompatible() async throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.commitState(Data("state".utf8))

    try append(0x01, to: fixture.machine.efiVariableStoreURL)

    guard
      case .incompatible(let reason) =
        try await fixture.store.inspect(for: fixture.lease)
    else {
      Issue.record("Expected an incompatible Linux saved state")
      return
    }
    #expect(reason.contains("writable storage changed"))
  }

  @Test
  func snapshotLayerMutationChangesLinuxConfigurationFingerprint() throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }
    let mutation = try VirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Checkpoint")
    let layerURL = fixture.root.appending(
      path: mutation.createdLayer.relativePath
    )
    try FileManager.default.createDirectory(
      at: layerURL.deletingLastPathComponent(),
      withIntermediateDirectories: false
    )
    try Data("overlay".utf8).write(to: layerURL)
    var manifest = fixture.machine.manifest
    manifest.linuxDiskSnapshotConfiguration = mutation.configuration
    let machine = fixture.machine.replacing(
      manifest: manifest,
      diskSnapshotLayerURLs: [layerURL]
    )
    let fingerprinter = LinuxVirtualMachineConfigurationFingerprinter()
    let baseline = try fingerprinter.fingerprint(for: machine)

    try append(0x01, to: layerURL)

    #expect(try fingerprinter.fingerprint(for: machine) != baseline)
  }

  @Test
  func fingerprintIgnoresDisplayNameAndTracksLinuxTopology() throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }
    let fingerprinter = LinuxVirtualMachineConfigurationFingerprinter()
    let baseline = try fingerprinter.fingerprint(for: fixture.machine)

    var renamedManifest = fixture.machine.manifest
    try renamedManifest.rename(to: "Renamed Linux VM")
    let renamed = fixture.machine.replacing(manifest: renamedManifest)
    #expect(try fingerprinter.fingerprint(for: renamed) == baseline)

    var clipboardManifest = fixture.machine.manifest
    clipboardManifest.linuxConfiguration?.sharesClipboard = false
    let clipboardChanged = fixture.machine.replacing(
      manifest: clipboardManifest
    )
    #expect(
      try fingerprinter.fingerprint(for: clipboardChanged) != baseline
    )

    var networkManifest = fixture.machine.manifest
    networkManifest.networkConfiguration = VirtualMachineNetworkConfiguration(
      revision: 1,
      attachment: .shared
    )
    let networkChanged = fixture.machine.replacing(manifest: networkManifest)
    #expect(try fingerprinter.fingerprint(for: networkChanged) != baseline)
  }

  @Test
  func activeLinuxTransactionPinsLeaseUntilAbort() async throws {
    let fixture = try LinuxSavedStateStoreFixture()
    defer { fixture.remove() }
    let transaction = try await fixture.store.beginSave(for: fixture.lease)

    fixture.lease.release()
    #expect(fixture.releaseRecorder.count == 0)

    await fixture.store.abortSave(transaction, for: fixture.lease)
    #expect(fixture.releaseRecorder.count == 1)
  }
}

private struct LinuxSavedStateStoreFixture {
  let root: URL
  let machine: ResolvedLinuxVirtualMachine
  let lease: LinuxVirtualMachineRuntimeLease
  let releaseRecorder: LinuxSavedStateReleaseRecorder
  let store = LinuxVirtualMachineSavedStateStore()

  init() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LinuxSavedStateTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    let diskURL = root.appending(path: "Disk.img")
    let platformURL = root.appending(
      path: LinuxPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: platformURL,
      withIntermediateDirectories: false
    )
    let efiURL = platformURL.appending(
      path: LinuxPlatformArtifactURLs.efiVariableStoreFilename
    )
    let identifierURL = platformURL.appending(
      path: LinuxPlatformArtifactURLs.machineIdentifierFilename
    )
    try Data("disk".utf8).write(to: diskURL)
    try Data("efi".utf8).write(to: efiURL)
    try Data("machine-identifier".utf8).write(to: identifierURL)

    var manifest = try VirtualMachineManifest(
      name: "Linux Saved State",
      guest: .linux,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 2,
        memoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB
      )
    )
    manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
      efiVariableStorePath:
        LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
      machineIdentifierPath:
        LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
      installationMediaPath: nil,
      macAddress: "02:00:00:00:00:31"
    )
    let machine = ResolvedLinuxVirtualMachine(
      manifest: manifest,
      bundleURL: root,
      diskImageURL: diskURL,
      efiVariableStoreURL: efiURL,
      machineIdentifierURL: identifierURL,
      installationMediaURL: nil
    )
    let releaseRecorder = LinuxSavedStateReleaseRecorder()

    self.root = root
    self.machine = machine
    self.releaseRecorder = releaseRecorder
    lease = LinuxVirtualMachineRuntimeLease(
      machine: machine,
      target: LinuxVirtualMachineRuntimeTarget(
        machineID: manifest.id,
        generation: UUID()
      )
    ) {
      releaseRecorder.record()
    }
  }

  var savedStateDirectory: URL {
    root.appending(
      path: LinuxVirtualMachineSavedStateStore.directoryName,
      directoryHint: .isDirectory
    )
  }

  func commitState(
    _ data: Data
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    let transaction = try await store.beginSave(for: lease)
    try data.write(to: transaction.stateURL)
    return try await store.commitSave(transaction, for: lease)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

extension ResolvedLinuxVirtualMachine {
  fileprivate func replacing(
    manifest: VirtualMachineManifest,
    diskSnapshotLayerURLs: [URL]? = nil
  ) -> ResolvedLinuxVirtualMachine {
    ResolvedLinuxVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs:
        diskSnapshotLayerURLs ?? self.diskSnapshotLayerURLs,
      efiVariableStoreURL: efiVariableStoreURL,
      machineIdentifierURL: machineIdentifierURL,
      installationMediaURL: installationMediaURL,
      sharedDirectories: sharedDirectories
    )
  }
}

private final class LinuxSavedStateReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.withLock { value }
  }

  func record() {
    lock.withLock { value += 1 }
  }
}

private func append(_ byte: UInt8, to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data([byte]))
  try handle.close()
}
