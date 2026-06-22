import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineLibraryTests {
  @Test
  func createsAtomicBundleWithSparseDiskAndReloadsIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )

    let created = try await library.createDraft(
      name: "Build Machine",
      guest: .macOS,
      resources: resources
    )
    let loaded = try await library.list()

    #expect(loaded == [created])

    let bundles = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == VirtualMachineLibrary.bundleExtension }
    #expect(bundles.count == 1)
    #expect(bundles[0].pathExtension == VirtualMachineLibrary.bundleExtension)

    let diskURL = bundles[0].appending(path: created.diskImagePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
    #expect((attributes[.size] as? NSNumber)?.uint64Value == resources.diskBytes)

    let partials = bundles.filter { $0.lastPathComponent.contains(".partial-") }
    #expect(partials.isEmpty)
  }

  @Test
  func listRejectsUnknownManifestSchema() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let bundle =
      root
      .appending(path: "unknown", directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let manifest = """
      {
        "schemaVersion": 999,
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Future VM",
        "guest": "macOS",
        "installState": "draft",
        "resources": { "cpuCount": 4, "memoryBytes": 8589934592, "diskBytes": 68719476736 },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """
    try Data(manifest.utf8).write(
      to: bundle.appending(path: VirtualMachineLibrary.manifestFilename))

    let library = VirtualMachineLibrary(rootURL: root)
    await #expect(throws: VirtualMachineModelError.unsupportedSchema(999)) {
      _ = try await library.list()
    }
  }

  @Test
  func listRejectsARenamedBundleBeforeItCanTargetTheCanonicalMachine() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let original = try await library.createDraft(
      name: "Original",
      guest: .macOS,
      resources: resources
    )
    let copiedBundle = root.appending(
      path: "Copied.\(VirtualMachineLibrary.bundleExtension)",
      directoryHint: .isDirectory
    )
    try FileManager.default.copyItem(
      at: bundleURL(root: root, id: original.id),
      to: copiedBundle
    )

    await #expect(
      throws: VirtualMachineModelError.bundleIdentifierMismatch(
        expected: original.id,
        bundleName: copiedBundle.lastPathComponent
      )
    ) {
      _ = try await library.list()
    }
    #expect(FileManager.default.fileExists(atPath: bundleURL(root: root, id: original.id).path))
  }

  @Test
  func failedDiscardLeavesOnlyAHiddenTombstoneThatRecoveryCanRetry() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let fileManager = TombstoneRemovalFailingFileManager()
    let library = VirtualMachineLibrary(rootURL: root, fileManager: fileManager)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let machine = try await library.createDraft(
      name: "Discarded",
      guest: .macOS,
      resources: resources
    )

    await #expect(throws: TombstoneRemovalError.expected) {
      try await library.discardVirtualMachine(id: machine.id)
    }
    #expect(try await library.list().isEmpty)
    let tombstones = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(VirtualMachineLibrary.deletionTombstonePrefix) }
    #expect(tombstones.count == 1)

    let recoveredLibrary = VirtualMachineLibrary(rootURL: root)
    let recoveryOutcome = try await recoveredLibrary.recoverInterruptedMacOSInstallations()
    #expect(recoveryOutcome == .recovered)
    #expect(!FileManager.default.fileExists(atPath: tombstones[0].path))
  }

  @Test
  func identityPinnedDiscardRejectsAChangedManifest() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let machine = try await library.createDraft(
      name: "Reviewed",
      guest: .macOS,
      resources: resources
    )
    var stale = machine
    stale.name = "Changed"

    await #expect(
      throws: VirtualMachineModelError.virtualMachineIdentityChanged(machine.id)
    ) {
      try await library.discardVirtualMachine(ifUnchanged: stale)
    }
    #expect(try await library.list() == [machine])

    try await library.discardVirtualMachine(ifUnchanged: machine)
    #expect(try await library.list().isEmpty)
  }

  @Test
  func suspendedPreparationDoesNotPermitAReentrantDiscard() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let preparer = BlockingMacPlatformArtifactPreparer()
    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: preparer
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Busy Mac",
      guest: .macOS,
      resources: resources
    )

    let preparation = Task {
      try await library.prepareMacVM(
        id: draft.id,
        restoreImageURL: root.appending(path: "Restore.ipsw")
      )
    }
    await preparer.waitUntilStarted()

    await #expect(throws: VirtualMachineModelError.libraryInUse) {
      try await library.discardVirtualMachine(id: draft.id)
    }
    await #expect(throws: VirtualMachineModelError.libraryInUse) {
      _ = try await library.migrateRestoreImageReferences(
        from: root.appending(path: "Legacy.ipsw"),
        to: root.appending(path: "Durable.ipsw")
      )
    }

    await preparer.resume()
    _ = try await preparation.value
  }

  @Test
  func preparesMacPlatformArtifactsAndAtomicallyUpdatesManifest() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let preparer = TestMacPlatformArtifactPreparer(behavior: .success)
    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: preparer
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Prepared Mac",
      guest: .macOS,
      resources: resources
    )
    let restoreImageURL = root.appending(path: "Restore.ipsw")

    let prepared = try await library.prepareMacVM(
      id: draft.id,
      restoreImageURL: restoreImageURL
    )
    let reloaded = try await library.list()

    #expect(prepared.installState == .readyToInstall)
    #expect(prepared.restoreImageURL == restoreImageURL)
    #expect(
      prepared.auxiliaryStoragePath == MacPlatformArtifactURLs.auxiliaryStorageManifestPath
    )
    #expect(prepared.hardwareModelPath == MacPlatformArtifactURLs.hardwareModelManifestPath)
    #expect(
      prepared.machineIdentifierPath == MacPlatformArtifactURLs.machineIdentifierManifestPath
    )
    #expect(
      prepared.macOSGuestOperatingSystem
        == MacGuestOperatingSystemIdentity(
          buildVersion: "TEST",
          majorVersion: 27,
          minorVersion: 0,
          patchVersion: 0
        )
    )
    #expect(prepared.macOSFirstBootState == nil)
    #expect(prepared.updatedAt >= draft.updatedAt)
    #expect(reloaded == [prepared])

    let artifactDirectory = bundleURL(root: root, id: draft.id).appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    let artifacts = MacPlatformArtifactURLs(directory: artifactDirectory)
    for artifact in artifacts.all {
      #expect(FileManager.default.fileExists(atPath: artifact.path))
    }
    #expect(try Data(contentsOf: artifacts.auxiliaryStorage) == Data("auxiliary".utf8))
    #expect(try Data(contentsOf: artifacts.hardwareModel) == Data("hardware".utf8))
    #expect(try Data(contentsOf: artifacts.machineIdentifier) == Data("machine".utf8))

    let recordedResources = await preparer.recordedResources
    let recordedRestoreImageURL = await preparer.recordedRestoreImageURL
    #expect(recordedResources == resources)
    #expect(recordedRestoreImageURL == restoreImageURL)
    try expectNoPartialDirectories(in: bundleURL(root: root, id: draft.id))
  }

  @Test
  func migratesSharedRestoreImageReferencesUnderOneLibraryOperation() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(
        behavior: .success
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let sourceURL = root.appending(path: "Legacy.ipsw")
    let destinationURL = root.appending(path: "Durable.ipsw")
    let first = try await library.createDraft(
      name: "First Mac",
      guest: .macOS,
      resources: resources
    )
    let second = try await library.createDraft(
      name: "Second Mac",
      guest: .macOS,
      resources: resources
    )
    _ = try await library.prepareMacVM(
      id: first.id,
      restoreImageURL: sourceURL
    )
    _ = try await library.prepareMacVM(
      id: second.id,
      restoreImageURL: sourceURL
    )

    #expect(try await library.loadRestoreImageReferences() == [sourceURL])
    #expect(
      try await library.migrateRestoreImageReferences(
        from: sourceURL,
        to: destinationURL
      ) == 2
    )
    #expect(try await library.loadRestoreImageReferences() == [destinationURL])
    #expect(
      try await library.list().allSatisfy {
        $0.restoreImageURL == destinationURL
      }
    )
    #expect(
      try await library.migrateRestoreImageReferences(
        from: sourceURL,
        to: destinationURL
      ) == 0
    )
  }

  @Test
  func preparationFailureRollsBackArtifactsAndPreservesDraftManifest() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(
        behavior: .failAfterFirstArtifact
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Rollback Mac",
      guest: .macOS,
      resources: resources
    )

    await #expect(throws: TestMacPlatformPreparationError.failed) {
      _ = try await library.prepareMacVM(
        id: draft.id,
        restoreImageURL: root.appending(path: "Restore.ipsw")
      )
    }

    let reloaded = try await library.list()
    #expect(reloaded == [draft])
    let bundle = bundleURL(root: root, id: draft.id)
    #expect(
      !FileManager.default.fileExists(
        atPath: bundle.appending(path: MacPlatformArtifactURLs.directoryName).path
      )
    )
    try expectNoPartialDirectories(in: bundle)
  }

  @Test
  func missingPreparedArtifactRollsBackBeforePromotion() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(
        behavior: .omitMachineIdentifier
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Incomplete Mac",
      guest: .macOS,
      resources: resources
    )

    await #expect(
      throws: MacPlatformArtifactError.missingArtifact(
        MacPlatformArtifactURLs.machineIdentifierFilename
      )
    ) {
      _ = try await library.prepareMacVM(
        id: draft.id,
        restoreImageURL: root.appending(path: "Restore.ipsw")
      )
    }

    let reloaded = try await library.list()
    #expect(reloaded == [draft])
    try expectNoPartialDirectories(in: bundleURL(root: root, id: draft.id))
  }

  @Test
  func versionOneManifestWithoutMacPlatformFieldsRemainsDecodable() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let bundle = bundleURL(root: root, id: identifier)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let manifest = """
      {
        "schemaVersion": 1,
        "id": "\(identifier.uuidString)",
        "name": "Legacy VM",
        "guest": "macOS",
        "installState": "draft",
        "resources": { "cpuCount": 4, "memoryBytes": 4294967296, "diskBytes": 8589934592 },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """
    try Data(manifest.utf8).write(
      to: bundle.appending(path: VirtualMachineLibrary.manifestFilename)
    )

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(behavior: .success)
    )
    let manifests = try await library.list()
    let loaded = try #require(manifests.first)

    #expect(loaded.id == identifier)
    #expect(loaded.auxiliaryStoragePath == nil)
    #expect(loaded.hardwareModelPath == nil)
    #expect(loaded.machineIdentifierPath == nil)
    #expect(loaded.restoreImageURL == nil)
    #expect(loaded.diskImageFormat == nil)
    #expect(loaded.effectiveDiskImageFormat == .raw)
    #expect(loaded.audioConfiguration == nil)
    #expect(loaded.effectiveAudioConfiguration == .disconnected)
    #expect(loaded.networkConfiguration == nil)
    #expect(loaded.effectiveNetworkConfiguration == .nat)
    #expect(loaded.macOSGuestOperatingSystem == nil)
    #expect(loaded.macOSFirstBootState == nil)

    let prepared = try await library.prepareMacVM(
      id: identifier,
      restoreImageURL: root.appending(path: "LegacyRestore.ipsw")
    )
    #expect(prepared.installState == .readyToInstall)
  }

  @Test
  func audioConfigurationPersistsOnlyUnderTheRuntimeLease() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try installedLibraryFixture(root: root)
    let lease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )

    let updated = try await fixture.library.setMacOSMicrophoneEnabled(
      true,
      for: lease
    )

    #expect(updated.revision == 1)
    #expect(updated.isMicrophoneEnabled)
    lease.release()

    await #expect(throws: MacVirtualMachineRuntimeError.staleTarget(lease.target)) {
      _ = try await fixture.library.setMacOSMicrophoneEnabled(
        false,
        for: lease
      )
    }

    let manifests = try await fixture.library.list()
    let reloaded = try #require(manifests.first)
    #expect(reloaded.effectiveAudioConfiguration == updated)
    let replacementLease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )
    #expect(replacementLease.machine.manifest.effectiveAudioConfiguration == updated)
    replacementLease.release()
  }

  @Test
  func networkConfigurationPersistsOnlyUnderTheRuntimeLease() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try installedLibraryFixture(root: root)
    let lease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )

    let updated = try await fixture.library.setMacOSNetworkAttachment(
      .shared,
      for: lease
    )

    #expect(updated.revision == 1)
    #expect(updated.attachment == .shared)
    lease.release()

    await #expect(throws: MacVirtualMachineRuntimeError.staleTarget(lease.target)) {
      _ = try await fixture.library.setMacOSNetworkAttachment(
        .hostOnly,
        for: lease
      )
    }

    let manifests = try await fixture.library.list()
    let reloaded = try #require(manifests.first)
    #expect(reloaded.effectiveNetworkConfiguration == updated)
    let replacementLease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )
    #expect(
      replacementLease.machine.manifest.effectiveNetworkConfiguration
        == updated
    )
    replacementLease.release()
  }

  @Test
  func sharedDirectorySidecarLoadsAndMutatesUnderRuntimeLease() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try installedLibraryFixture(root: root)
    let store = FileMacVirtualMachineSharedDirectoryConfigurationStore()
    let first = librarySharedDirectory(name: "Projects", inode: 1)
    try store.save(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [first]
      ),
      to: fixture.bundle
    )

    let lease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )
    #expect(lease.machine.sharedDirectories.revision == 1)
    #expect(lease.machine.sharedDirectories.directories == [first])
    await #expect(
      throws: MacVirtualMachineRuntimeError.ownedElsewhere(fixture.manifest.id)
    ) {
      _ = try await fixture.library.acquireMacOSRuntime(id: fixture.manifest.id)
    }

    let second = librarySharedDirectory(name: "Reference", inode: 2)
    let updated = try await fixture.library.addMacOSSharedDirectory(
      second,
      for: lease
    )
    #expect(updated.revision == 2)
    #expect(Set(updated.directories.map(\.guestName)) == ["Projects", "Reference"])
    lease.release()

    await #expect(throws: MacVirtualMachineRuntimeError.staleTarget(lease.target)) {
      _ = try await fixture.library.removeMacOSSharedDirectory(
        id: first.id,
        for: lease
      )
    }

    let replacementLease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )
    #expect(replacementLease.machine.sharedDirectories == updated)
    replacementLease.release()
  }

  @Test
  func commitsASIFManifestOnlyForTheSealedRuntimeLeaseArtifacts() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try installedLibraryFixture(root: root)
    let destinationPath = "Disk.asif"
    let destinationURL = fixture.bundle.appending(path: destinationPath)
    try Data("asif".utf8).write(to: destinationURL)
    let inspector = FileVirtualMachineStorageArtifactInspector()
    let sourceURL = fixture.bundle.appending(path: fixture.manifest.diskImagePath)
    let lease = try await fixture.library.acquireMacOSRuntime(
      id: fixture.manifest.id
    )
    defer { lease.release() }

    let updated = try await fixture.library.commitDiskImageReplacement(
      VirtualMachineDiskImageMigrationCommit(
        sourcePath: fixture.manifest.diskImagePath,
        destinationPath: destinationPath,
        sourceFormat: .raw,
        destinationFormat: .asif,
        sourceIdentity: try inspector.inspect(at: sourceURL),
        destinationIdentity: try inspector.inspect(at: destinationURL)
      ),
      for: lease
    )

    #expect(updated.diskImagePath == destinationPath)
    #expect(updated.effectiveDiskImageFormat == .asif)
    #expect(try await fixture.library.list() == [updated])
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @Test
  func pendingDiskMigrationBlocksRuntimeAndDiscardButAllowsRecoveryLease()
    async throws
  {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try installedLibraryFixture(root: root)
    let sourceURL = fixture.bundle.appending(
      path: fixture.manifest.diskImagePath
    )
    let operationID = UUID()
    try FileVirtualMachineDiskImageReplacementJournalStore().save(
      VirtualMachineDiskImageMigrationJournal(
        version: VirtualMachineDiskImageMigrationJournal.currentVersion,
        operationID: operationID,
        machineID: fixture.manifest.id,
        sourcePath: fixture.manifest.diskImagePath,
        destinationPath: "Disk.asif",
        stagingPath:
          "\(VirtualMachineDiskImageReplacementArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageReplacementArtifacts.stagingSuffix)",
        sourceIdentity: try FileVirtualMachineStorageArtifactInspector()
          .inspect(at: sourceURL),
        sourceLogicalBytes: fixture.manifest.resources.diskBytes,
        sourceBlockSizeBytes: 512,
        destinationIdentity: nil,
        phase: .planned,
        hostBootIdentifier: UUID().uuidString.lowercased()
      ),
      in: fixture.bundle
    )

    await #expect(
      throws: MacVirtualMachineRuntimeError.diskReplacementPending(
        fixture.manifest.id
      )
    ) {
      _ = try await fixture.library.acquireMacOSRuntime(
        id: fixture.manifest.id
      )
    }
    await #expect(
      throws: MacVirtualMachineRuntimeError.diskReplacementPending(
        fixture.manifest.id
      )
    ) {
      try await fixture.library.discardVirtualMachine(id: fixture.manifest.id)
    }

    let recoveryLease = try await fixture.library
      .acquireDiskImageReplacementRuntime(id: fixture.manifest.id)
    recoveryLease.release()
  }

  private func installedLibraryFixture(
    root: URL
  ) throws -> (
    library: VirtualMachineLibrary,
    manifest: VirtualMachineManifest,
    bundle: URL
  ) {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Installed Mac",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    manifest.auxiliaryStoragePath = "AuxiliaryStorage"
    manifest.hardwareModelPath = "HardwareModel"
    manifest.machineIdentifierPath = "MachineIdentifier"
    let bundle = bundleURL(root: root, id: manifest.id)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    for filename in [
      manifest.diskImagePath,
      "AuxiliaryStorage",
      "HardwareModel",
      "MachineIdentifier",
    ] {
      try Data(filename.utf8).write(to: bundle.appending(path: filename))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: bundle.appending(path: VirtualMachineLibrary.manifestFilename)
    )
    return (
      VirtualMachineLibrary(rootURL: root),
      manifest,
      bundle
    )
  }

  private func librarySharedDirectory(
    name: String,
    inode: UInt64
  ) -> MacVirtualMachineSharedDirectory {
    MacVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: name,
      bookmarkData: Data("bookmark-\(inode)".utf8),
      lastKnownPath: "/tmp/\(name)",
      sourceIdentity: .init(device: 1, inode: inode),
      readOnly: true
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  private func bundleURL(root: URL, id: UUID) -> URL {
    root
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  private func expectNoPartialDirectories(in bundle: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: bundle,
      includingPropertiesForKeys: nil
    )
    #expect(entries.allSatisfy { !$0.lastPathComponent.contains(".partial-") })
  }
}

private actor TestMacPlatformArtifactPreparer: MacPlatformArtifactPreparing {
  enum Behavior: Equatable, Sendable {
    case success
    case failAfterFirstArtifact
    case omitMachineIdentifier
  }

  let behavior: Behavior
  private(set) var recordedResources: VirtualMachineResources?
  private(set) var recordedRestoreImageURL: URL?

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws -> MacPlatformPreparationResult {
    recordedRestoreImageURL = restoreImageURL
    recordedResources = resources

    try Data("hardware".utf8).write(to: destination.hardwareModel)
    if behavior == .failAfterFirstArtifact {
      throw TestMacPlatformPreparationError.failed
    }

    try Data("auxiliary".utf8).write(to: destination.auxiliaryStorage)
    if behavior != .omitMachineIdentifier {
      try Data("machine".utf8).write(to: destination.machineIdentifier)
    }
    return MacPlatformPreparationResult(
      operatingSystem: MacGuestOperatingSystemIdentity(
        buildVersion: "TEST",
        majorVersion: 27,
        minorVersion: 0,
        patchVersion: 0
      )
    )
  }
}

private actor BlockingMacPlatformArtifactPreparer: MacPlatformArtifactPreparing {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws -> MacPlatformPreparationResult {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
    try Data("hardware".utf8).write(to: destination.hardwareModel)
    try Data("auxiliary".utf8).write(to: destination.auxiliaryStorage)
    try Data("machine".utf8).write(to: destination.machineIdentifier)
    return MacPlatformPreparationResult(
      operatingSystem: MacGuestOperatingSystemIdentity(
        buildVersion: "TEST",
        majorVersion: 27,
        minorVersion: 0,
        patchVersion: 0
      )
    )
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private enum TestMacPlatformPreparationError: Error, Equatable {
  case failed
}

private enum TombstoneRemovalError: Error, Equatable {
  case expected
}

private final class TombstoneRemovalFailingFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    guard !URL.lastPathComponent.hasPrefix(VirtualMachineLibrary.deletionTombstonePrefix) else {
      throw TombstoneRemovalError.expected
    }
    try super.removeItem(at: URL)
  }
}
