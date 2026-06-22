import DiskImageKit
import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageResizeServiceTests {
  @Test
  func growsLinuxDiskAndCommitsManifestAtomically() async throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskResizeServiceFixture(guest: .linux)
    defer { fixture.remove() }

    let result = try await fixture.service.grow(
      machineID: fixture.manifest.id,
      guest: .linux,
      to: fixture.targetBytes
    )
    let persisted = await fixture.store.currentManifest()
    let descriptor = try fixture.extender.descriptor(
      for: fixture.resizeSource
    )

    #expect(result.didResize)
    #expect(result.previousLogicalBytes == fixture.sourceBytes)
    #expect(result.newLogicalBytes == fixture.targetBytes)
    #expect(persisted.resources.diskBytes == fixture.targetBytes)
    #expect(descriptor.logicalBytes == fixture.targetBytes)
    #expect(
      try fixture.journals.load(in: fixture.bundleURL) == nil
    )
  }

  @Test
  func growsMacOSASIFDiskThroughTheSameTransaction() async throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskResizeServiceFixture(guest: .macOS)
    defer { fixture.remove() }

    let result = try await fixture.service.grow(
      machineID: fixture.manifest.id,
      guest: .macOS,
      to: fixture.targetBytes
    )

    #expect(result.manifest.guest == .macOS)
    #expect(result.manifest.resources.diskBytes == fixture.targetBytes)
    #expect(
      try fixture.extender.descriptor(for: fixture.resizeSource)
        .logicalBytes == fixture.targetBytes
    )
  }

  @Test
  func savedStateBlocksGrowthBeforePublishingAJournal() async throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskResizeServiceFixture(guest: .linux)
    defer { fixture.remove() }
    fixture.savedStates.status = .available(
      VirtualMachineSavedStateSummary(
        createdAt: .distantPast,
        stateSizeBytes: 4_096
      )
    )

    await #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try await fixture.service.grow(
        machineID: fixture.manifest.id,
        guest: .linux,
        to: fixture.targetBytes
      )
    }
    #expect(
      try fixture.extender.descriptor(for: fixture.resizeSource)
        .logicalBytes == fixture.sourceBytes
    )
    #expect(
      try fixture.journals.load(in: fixture.bundleURL) == nil
    )
  }

  @Test
  func recoveryFinishesAnExtensionCompletedBeforeJournalAdvance() async throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskResizeServiceFixture(guest: .linux)
    defer { fixture.remove() }

    let sourceIdentity = try fixture.artifactInspector.inspect(
      at: fixture.diskURL
    )
    let journal = fixture.makeJournal(sourceIdentity: sourceIdentity)
    try fixture.journals.save(journal, in: fixture.bundleURL)
    _ = try fixture.extender.extend(
      fixture.resizeSource,
      to: fixture.targetBytes
    )

    let report =
      try await fixture.service.recoverInterruptedDiskImageResizes()
    let persisted = await fixture.store.currentManifest()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(report.deferredMachineIDs.isEmpty)
    #expect(report.failures.isEmpty)
    #expect(persisted.resources.diskBytes == fixture.targetBytes)
    #expect(
      try fixture.journals.load(in: fixture.bundleURL) == nil
    )
  }

  @Test
  func recoveryCleansJournalWhenManifestCommitAlreadyLanded() async throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskResizeServiceFixture(guest: .linux)
    defer { fixture.remove() }

    let sourceIdentity = try fixture.artifactInspector.inspect(
      at: fixture.diskURL
    )
    var journal = fixture.makeJournal(sourceIdentity: sourceIdentity)
    try fixture.journals.save(journal, in: fixture.bundleURL)
    _ = try fixture.extender.extend(
      fixture.resizeSource,
      to: fixture.targetBytes
    )
    journal.resizedIdentity = try fixture.artifactInspector.inspect(
      at: fixture.diskURL
    )
    journal.phase = .imageExtended
    try fixture.journals.save(journal, in: fixture.bundleURL)
    await fixture.store.setDiskBytes(fixture.targetBytes)

    let report =
      try await fixture.service.recoverInterruptedDiskImageResizes()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(report.failures.isEmpty)
    #expect(
      try fixture.journals.load(in: fixture.bundleURL) == nil
    )
  }
}

@MainActor
private final class ResizeSavedStateInspector:
  MacVirtualMachineSavedStateInspecting,
  LinuxVirtualMachineSavedStateInspecting
{
  var status: VirtualMachineSavedStateStatus = .none

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    status
  }

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus {
    status
  }
}

private actor DiskResizeServiceStore:
  VirtualMachineDiskImageResizeStoring
{
  private var manifest: VirtualMachineManifest
  private let bundleURL: URL
  private let diskURL: URL
  private let auxiliaryStorageURL: URL
  private let hardwareModelURL: URL
  private let machineIdentifierURL: URL
  private let efiVariableStoreURL: URL

  init(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    diskURL: URL,
    auxiliaryStorageURL: URL,
    hardwareModelURL: URL,
    machineIdentifierURL: URL,
    efiVariableStoreURL: URL
  ) {
    self.manifest = manifest
    self.bundleURL = bundleURL
    self.diskURL = diskURL
    self.auxiliaryStorageURL = auxiliaryStorageURL
    self.hardwareModelURL = hardwareModelURL
    self.machineIdentifierURL = machineIdentifierURL
    self.efiVariableStoreURL = efiVariableStoreURL
  }

  func loadVirtualMachineStorageInventory()
    -> VirtualMachineStorageInventory
  {
    VirtualMachineStorageInventory(
      rootURL: bundleURL.deletingLastPathComponent(),
      targets: [
        VirtualMachineStorageTarget(
          manifest: manifest,
          bundleURL: bundleURL
        )
      ]
    )
  }

  func acquireMacOSDiskImageResizeRuntime(
    id: UUID
  ) throws -> MacVirtualMachineRuntimeLease {
    guard manifest.id == id, manifest.guest == .macOS else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    return MacVirtualMachineRuntimeLease(
      machine: ResolvedMacVirtualMachine(
        manifest: manifest,
        bundleURL: bundleURL,
        diskImageURL: diskURL,
        auxiliaryStorageURL: auxiliaryStorageURL,
        hardwareModelURL: hardwareModelURL,
        machineIdentifierURL: machineIdentifierURL
      ),
      target: VirtualMachineRuntimeTarget(
        machineID: manifest.id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func acquireLinuxDiskImageResizeRuntime(
    id: UUID
  ) throws -> LinuxVirtualMachineRuntimeLease {
    guard manifest.id == id, manifest.guest == .linux else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    return LinuxVirtualMachineRuntimeLease(
      machine: ResolvedLinuxVirtualMachine(
        manifest: manifest,
        bundleURL: bundleURL,
        diskImageURL: diskURL,
        efiVariableStoreURL: efiVariableStoreURL,
        machineIdentifierURL: machineIdentifierURL,
        installationMediaURL: nil
      ),
      target: VirtualMachineRuntimeTarget(
        machineID: manifest.id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func commitMacOSDiskImageResize(
    _ commit: VirtualMachineDiskImageResizeCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    try commitResize(commit)
  }

  func commitLinuxDiskImageResize(
    _ commit: VirtualMachineDiskImageResizeCommit,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    try commitResize(commit)
  }

  func currentManifest() -> VirtualMachineManifest {
    manifest
  }

  func setDiskBytes(_ bytes: UInt64) {
    _ = try? manifest.growDisk(to: bytes)
  }

  private func commitResize(
    _ commit: VirtualMachineDiskImageResizeCommit
  ) throws -> VirtualMachineManifest {
    guard manifest.id == commit.machineID,
      manifest.guest == commit.guest,
      manifest.diskImagePath == commit.diskImagePath,
      manifest.resources.diskBytes == commit.sourceLogicalBytes
        || manifest.resources.diskBytes == commit.targetLogicalBytes
    else {
      throw VirtualMachineDiskImageResizeError.staleSource
    }
    _ = try manifest.growDisk(to: commit.targetLogicalBytes)
    return manifest
  }
}

@MainActor
private struct DiskResizeServiceFixture {
  let sourceBytes = 8 * VirtualMachineResources.bytesPerGiB
  let targetBytes = 9 * VirtualMachineResources.bytesPerGiB
  let bundleURL: URL
  let diskURL: URL
  let manifest: VirtualMachineManifest
  let store: DiskResizeServiceStore
  let savedStates = ResizeSavedStateInspector()
  let extender = AppleVirtualMachineDiskImageExtender()
  let artifactInspector = FileVirtualMachineStorageArtifactInspector()
  let journals = FileVirtualMachineDiskImageResizeJournalStore()
  let service: VirtualMachineDiskImageResizeService

  var resizeSource: VirtualMachineDiskImageResizeSource {
    VirtualMachineDiskImageResizeSource(
      baseURL: diskURL,
      layerURLs: [],
      expectedFormat: manifest.effectiveDiskImageFormat
    )
  }

  init(guest: VirtualMachineGuest) throws {
    bundleURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-DiskResizeService-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: false
    )

    let diskFormat: VirtualMachineDiskImageFormat =
      guest == .macOS ? .asif : .raw
    diskURL = bundleURL.appending(
      path: diskFormat == .asif ? "Disk.asif" : "Disk.raw"
    )
    let blockCount = Int(sourceBytes / 512)
    if #available(macOS 27.0, *) {
      switch diskFormat {
      case .raw:
        _ = try DiskImage(
          creating: .raw(url: diskURL, blockCount: blockCount)
        )
      case .asif:
        _ = try DiskImage(
          creating: .asif(
            url: diskURL,
            blockCount: blockCount,
            blockSize: .bytes512
          )
        )
      }
    }

    var createdManifest = try VirtualMachineManifest(
      name: guest == .macOS ? "Resize macOS" : "Resize Linux",
      guest: guest,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: sourceBytes
      ),
      diskImagePath: diskURL.lastPathComponent,
      diskImageFormat: diskFormat
    )
    if guest == .linux {
      createdManifest.linuxConfiguration =
        LinuxVirtualMachineConfiguration(
          efiVariableStorePath: "EFI",
          machineIdentifierPath: "MachineIdentifier",
          installationMediaPath: nil,
          macAddress: "02:00:00:00:00:01"
        )
    }
    manifest = createdManifest

    let auxiliaryStorageURL = bundleURL.appending(path: "AuxiliaryStorage")
    let hardwareModelURL = bundleURL.appending(path: "HardwareModel")
    let machineIdentifierURL = bundleURL.appending(path: "MachineIdentifier")
    let efiVariableStoreURL = bundleURL.appending(path: "EFI")
    for url in [
      auxiliaryStorageURL,
      hardwareModelURL,
      machineIdentifierURL,
      efiVariableStoreURL,
    ] {
      try Data("fixture".utf8).write(to: url)
    }

    store = DiskResizeServiceStore(
      manifest: createdManifest,
      bundleURL: bundleURL,
      diskURL: diskURL,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      efiVariableStoreURL: efiVariableStoreURL
    )
    service = VirtualMachineDiskImageResizeService(
      store: store,
      macSavedStates: savedStates,
      linuxSavedStates: savedStates,
      extender: extender,
      artifactInspector: artifactInspector,
      journals: journals
    )
  }

  func makeJournal(
    sourceIdentity: VirtualMachineStorageArtifactIdentity
  ) -> VirtualMachineDiskImageResizeJournal {
    VirtualMachineDiskImageResizeJournal(
      operationID: UUID(),
      machineID: manifest.id,
      guest: manifest.guest,
      diskImagePath: manifest.diskImagePath,
      resizeArtifactPath: manifest.diskImagePath,
      diskImageFormat: manifest.effectiveDiskImageFormat,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: sourceBytes,
      sourceBlockSizeBytes: 512,
      targetLogicalBytes: targetBytes
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: bundleURL)
  }
}
