import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageReplacementRecoveryTests {
  @Test
  func failedKillSignalRequiresAHostRestartBeforeRecovery() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let bootA = UUID().uuidString.lowercased()
    let bootB = UUID().uuidString.lowercased()
    var service: VirtualMachineDiskImageMigrationService? = makeDiskImageMigrationService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .killSignalFailed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootA)
    )

    await #expect(throws: VirtualMachineDiskImageMigrationError.self) {
      _ = try await service?.migrateToASIF(machineID: fixture.manifest.id)
    }
    let journalStore = FileVirtualMachineDiskImageReplacementJournalStore()
    let journal = try #require(
      try journalStore.load(in: fixture.bundleURL)
    )
    #expect(journal.phase == .terminationQuarantined)
    #expect(journal.terminationQuarantine == .untilHostRestart)
    #expect(journal.hostBootIdentifier == bootA)
    service = nil

    let sameBootRecovery = makeDiskImageReplacementCoordinator(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootA)
    )
    let blocked =
      try await sameBootRecovery.recoverInterruptedDiskImageReplacements()
    #expect(blocked.recoveredMachineIDs.isEmpty)
    #expect(blocked.failures.count == 1)
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).count == 1)

    let nextBootRecovery = makeDiskImageReplacementCoordinator(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootB)
    )
    let recovered =
      try await nextBootRecovery.recoverInterruptedDiskImageReplacements()
    #expect(recovered.recoveredMachineIDs == [fixture.manifest.id])
    #expect(recovered.failures.isEmpty)
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).isEmpty)
    #expect(try journalStore.load(in: fixture.bundleURL) == nil)
  }

  @Test
  func startupRecoveryDoesNotLeaseMachinesWithoutAJournal() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let recovery = makeDiskImageReplacementCoordinator(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let report = try await recovery.recoverInterruptedDiskImageReplacements()

    #expect(report == .empty)
    #expect(store.acquireCount == 0)
  }

  @Test
  func startupRecoveryRollsBackAnUncommittedPartial() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let sourceIdentity = try FileVirtualMachineStorageArtifactInspector().inspect(
      at: fixture.sourceURL
    )
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    try Data("partial".utf8).write(to: stagingURL)
    let journal = VirtualMachineDiskImageMigrationJournal(
      version: VirtualMachineDiskImageMigrationJournal.currentVersion,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath: "Installed/Disk.asif",
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      sourceBlockSizeBytes: 512,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    try FileVirtualMachineDiskImageReplacementJournalStore().save(
      journal,
      in: fixture.bundleURL
    )
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let recovery = makeDiskImageReplacementCoordinator(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let report = try await recovery.recoverInterruptedDiskImageReplacements()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(report.deferredMachineIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test(
    arguments: [
      VirtualMachineDiskImageReplacementJournal.legacyVersion,
      VirtualMachineDiskImageReplacementJournal.operationMetadataVersion,
      VirtualMachineDiskImageReplacementJournal.currentVersion,
    ]
  )
  func startupRecoveryFinishesCleanupAfterManifestCommit(
    journalVersion: Int
  ) async throws {
    try await assertCommittedRAWMigrationRecovery(
      journalVersion: journalVersion,
      destinationBlockSizeBytes:
        VirtualMachineDiskImageDescriptor.rawBlockSizeBytes,
      shouldRecover: true
    )
  }

  @Test(
    arguments: [
      VirtualMachineDiskImageReplacementJournal.legacyVersion,
      VirtualMachineDiskImageReplacementJournal.operationMetadataVersion,
    ]
  )
  func startupRecoveryRejectsLegacyRAWMigrationWithChangedBlockGeometry(
    journalVersion: Int
  ) async throws {
    try await assertCommittedRAWMigrationRecovery(
      journalVersion: journalVersion,
      destinationBlockSizeBytes: 4_096,
      shouldRecover: false
    )
  }
  @Test
  func startupRecoveryContinuesPastAMalformedJournal() async throws {
    let malformed = try DiskImageMigrationFixture()
    let recoverable = try DiskImageMigrationFixture()
    defer {
      malformed.remove()
      recoverable.remove()
    }
    try Data("not-json".utf8).write(
      to: malformed.bundleURL.appending(
        path: FileVirtualMachineDiskImageReplacementJournalStore.filename
      )
    )

    let sourceIdentity = try FileVirtualMachineStorageArtifactInspector()
      .inspect(at: recoverable.sourceURL)
    let operationID = UUID()
    let stagingPath =
      "Installed/\(VirtualMachineDiskImageReplacementArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageReplacementArtifacts.stagingSuffix)"
    let stagingURL = recoverable.bundleURL.appending(path: stagingPath)
    try Data("partial".utf8).write(to: stagingURL)
    try FileVirtualMachineDiskImageReplacementJournalStore().save(
      VirtualMachineDiskImageMigrationJournal(
        version: VirtualMachineDiskImageMigrationJournal.currentVersion,
        operationID: operationID,
        machineID: recoverable.manifest.id,
        sourcePath: recoverable.manifest.diskImagePath,
        destinationPath: "Installed/Disk.asif",
        stagingPath: stagingPath,
        sourceIdentity: sourceIdentity,
        sourceLogicalBytes: recoverable.manifest.resources.diskBytes,
        sourceBlockSizeBytes: 512,
        destinationIdentity: nil,
        phase: .planned,
        hostBootIdentifier: UUID().uuidString.lowercased()
      ),
      in: recoverable.bundleURL
    )
    let store = RecoveryMigrationStoreDouble(fixtures: [malformed, recoverable])
    let recovery = VirtualMachineDiskImageReplacementCoordinator(
      store: store,
      savedStates: SavedStateInspectorDouble(status: .none),
      converter: RecordingMigrationConverter(behavior: .succeed),
      imageInspector: StubDiskImageInspector(
        rawLogicalBytes: recoverable.manifest.resources.diskBytes,
        asifLogicalBytes: recoverable.manifest.resources.diskBytes
      )
    )

    let report = try await recovery.recoverInterruptedDiskImageReplacements()

    #expect(report.recoveredMachineIDs == [recoverable.manifest.id])
    #expect(report.deferredMachineIDs.isEmpty)
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.machineID == malformed.manifest.id)
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
  }

  @Test
  func startupRecoveryRollsBackAnUncommittedRewriteCandidate() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    try RewriteConverter.candidateMarker.write(to: stagingURL)
    let inspector = FileVirtualMachineStorageArtifactInspector()
    let sourceIdentity = try inspector.inspect(at: fixture.sourceURL)
    let candidateIdentity = try inspector.inspect(at: stagingURL)
    var journal = VirtualMachineDiskImageReplacementJournal(
      operation: .rewriteASIF,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath:
        "Installed/Disk-\(operationID.uuidString.lowercased()).asif",
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      sourceBlockSizeBytes: 512,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let journalStore = FileVirtualMachineDiskImageReplacementJournalStore()
    try journalStore.save(journal, in: fixture.bundleURL)
    journal.destinationIdentity = candidateIdentity
    journal.phase = .converted
    journal.hostBootIdentifier = nil
    try journalStore.save(journal, in: fixture.bundleURL)
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let coordinator = VirtualMachineDiskImageReplacementCoordinator(
      store: store,
      savedStates: RewriteSavedStateInspector(status: .none),
      imageInspector: RewriteDiskImageInspector(
        sourceURL: fixture.sourceURL,
        logicalBytes: fixture.manifest.resources.diskBytes,
        sourceLayerType: nil,
        candidateBlockSizeBytes: 512
      )
    )

    let report =
      try await coordinator
      .recoverInterruptedDiskImageReplacements()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    #expect(try journalStore.load(in: fixture.bundleURL) == nil)
  }

  @Test(
    arguments: [
      VirtualMachineDiskImageReplacementJournal.operationMetadataVersion,
      VirtualMachineDiskImageReplacementJournal.currentVersion,
    ]
  )
  func startupRecoveryFinishesACommittedASIFRewrite(
    journalVersion: Int
  ) async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let destinationPath =
      "Installed/Disk-\(operationID.uuidString.lowercased()).asif"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    let destinationURL = fixture.bundleURL.appending(path: destinationPath)
    try RewriteConverter.candidateMarker.write(to: stagingURL)
    let inspector = FileVirtualMachineStorageArtifactInspector()
    let sourceIdentity = try inspector.inspect(at: fixture.sourceURL)
    var journal = VirtualMachineDiskImageReplacementJournal(
      version: journalVersion,
      operation: .rewriteASIF,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath: destinationPath,
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      sourceBlockSizeBytes:
        journalVersion
        >= VirtualMachineDiskImageReplacementJournal.geometryMetadataVersion
        ? 512 : nil,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let journalStore = FileVirtualMachineDiskImageReplacementJournalStore()
    try journalStore.save(journal, in: fixture.bundleURL)
    journal.destinationIdentity = try inspector.inspect(at: stagingURL)
    journal.phase = .converted
    journal.hostBootIdentifier = nil
    try journalStore.save(journal, in: fixture.bundleURL)
    try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
    journal.destinationIdentity = try inspector.inspect(at: destinationURL)
    journal.phase = .promoted
    try journalStore.save(journal, in: fixture.bundleURL)
    var committedManifest = fixture.manifest
    committedManifest.markDiskImageReplaced(
      to: destinationPath,
      format: .asif
    )
    let store = RewriteStoreDouble(
      manifest: committedManifest,
      bundleURL: fixture.bundleURL
    )
    let coordinator = VirtualMachineDiskImageReplacementCoordinator(
      store: store,
      savedStates: RewriteSavedStateInspector(status: .none),
      imageInspector: RewriteDiskImageInspector(
        sourceURL: fixture.sourceURL,
        logicalBytes: fixture.manifest.resources.diskBytes,
        sourceLayerType: nil,
        candidateBlockSizeBytes: 512
      )
    )

    let report =
      try await coordinator
      .recoverInterruptedDiskImageReplacements()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(try journalStore.load(in: fixture.bundleURL) == nil)
  }

  private func assertCommittedRAWMigrationRecovery(
    journalVersion: Int,
    destinationBlockSizeBytes: UInt64,
    shouldRecover: Bool
  ) async throws {
var fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let inspector = FileVirtualMachineStorageArtifactInspector()
    let sourceIdentity = try inspector.inspect(at: fixture.sourceURL)
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    try Data("converted-asif".utf8).write(to: stagingURL)
    let stagingIdentity = try inspector.inspect(at: stagingURL)
    var journal = VirtualMachineDiskImageMigrationJournal(
      version: journalVersion,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath: "Installed/Disk.asif",
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      sourceBlockSizeBytes:
        journalVersion
        >= VirtualMachineDiskImageReplacementJournal.geometryMetadataVersion
        ? VirtualMachineDiskImageDescriptor.rawBlockSizeBytes : nil,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let journalStore = FileVirtualMachineDiskImageReplacementJournalStore()
    try journalStore.save(journal, in: fixture.bundleURL)
    journal.destinationIdentity = stagingIdentity
    journal.phase = .converted
    journal.hostBootIdentifier = nil
    try journalStore.save(journal, in: fixture.bundleURL)
    try FileManager.default.moveItem(
      at: stagingURL,
      to: fixture.destinationURL
    )
    journal.destinationIdentity = try inspector.inspect(
      at: fixture.destinationURL
    )
    journal.phase = .promoted
    try journalStore.save(journal, in: fixture.bundleURL)
    fixture.manifest.markDiskImageReplaced(
      to: "Installed/Disk.asif",
      format: .asif
    )

    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let recovery = makeDiskImageReplacementCoordinator(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      asifBlockSizeBytes: destinationBlockSizeBytes
    )

    let report = try await recovery.recoverInterruptedDiskImageReplacements()

    if shouldRecover {
      #expect(report.recoveredMachineIDs == [fixture.manifest.id])
      #expect(report.failures.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
      #expect(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
      #expect(try journalStore.load(in: fixture.bundleURL) == nil)
    } else {
      #expect(report.recoveredMachineIDs.isEmpty)
      #expect(report.failures.count == 1)
      #expect(report.failures.first?.diagnostic.contains("block size") == true)
      #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
      #expect(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
      #expect(try journalStore.load(in: fixture.bundleURL) != nil)
    }
  }
}
