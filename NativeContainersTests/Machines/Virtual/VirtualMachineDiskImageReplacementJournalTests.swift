import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineDiskImageReplacementJournalTests {
  @Test
  func persistsEveryOrderedMigrationPhaseAndRemovesExactJournal() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let store = FileVirtualMachineDiskImageReplacementJournalStore()
    let operationID = UUID()
    var journal = migrationJournal(operationID: operationID)

    try store.save(journal, in: bundle)
    #expect(try store.load(in: bundle) == journal)

    let destinationIdentity = identity(inode: 2, statusNanoseconds: 1)
    journal.destinationIdentity = destinationIdentity
    journal.phase = .converted
    journal.hostBootIdentifier = nil
    try store.save(journal, in: bundle)

    journal.destinationIdentity = identity(inode: 2, statusNanoseconds: 2)
    journal.phase = .promoted
    try store.save(journal, in: bundle)

    journal.phase = .manifestUpdated
    try store.save(journal, in: bundle)
    #expect(try store.load(in: bundle) == journal)

    try store.remove(journal, from: bundle)
    #expect(try store.load(in: bundle) == nil)
  }

  @Test
  func rejectsSkippedOrRewrittenJournalPhases() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let store = FileVirtualMachineDiskImageReplacementJournalStore()
    var journal = migrationJournal(operationID: UUID())
    try store.save(journal, in: bundle)

    journal.destinationIdentity = identity(inode: 2)
    journal.phase = .promoted

    #expect(
      throws: VirtualMachineDiskImageReplacementError.invalidJournal
    ) {
      try store.save(journal, in: bundle)
    }
  }

  @Test
  func refusesASymbolicJournalControlFile() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let target = bundle.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: bundle.appending(
        path: FileVirtualMachineDiskImageReplacementJournalStore.filename
      ),
      withDestinationURL: target
    )

    #expect(
      throws: VirtualMachineDiskImageReplacementError.invalidJournal
    ) {
      _ = try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: bundle
      )
    }
  }

  @Test
  func rejectsAPlannedJournalWithoutABootSessionUUID() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    var journal = migrationJournal(operationID: UUID())
    journal.hostBootIdentifier = nil

    #expect(
      throws: VirtualMachineDiskImageReplacementError.invalidJournal
    ) {
      try FileVirtualMachineDiskImageReplacementJournalStore().save(
        journal,
        in: bundle
      )
    }
  }

  @Test
  func decodesVersionOneRAWMigrationJournalsWithoutOperationKeys() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let operationID = UUID()
    let journal = VirtualMachineDiskImageReplacementJournal(
      version: VirtualMachineDiskImageReplacementJournal.legacyVersion,
      operationID: operationID,
      machineID: UUID(),
      sourcePath: "Installed/Disk.img",
      destinationPath: "Installed/Disk.asif",
      stagingPath:
        "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial",
      sourceIdentity: identity(inode: 1),
      sourceLogicalBytes: 8 * VirtualMachineResources.bytesPerGiB,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let encoded = try JSONEncoder().encode(journal)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "operation")
    object.removeValue(forKey: "sourceFormat")
    object.removeValue(forKey: "destinationFormat")
    try JSONSerialization.data(withJSONObject: object).write(
      to: bundle.appending(
        path: FileVirtualMachineDiskImageReplacementJournalStore.filename
      )
    )

    let decoded = try #require(
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: bundle
      )
    )

    #expect(decoded.version == 1)
    #expect(decoded.operation == .rawToASIF)
    #expect(decoded.sourceFormat == .raw)
    #expect(decoded.destinationFormat == .asif)
  }

  @Test
  func persistsASIFRewriteOperationAndFormats() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let operationID = UUID()
    let journal = VirtualMachineDiskImageReplacementJournal(
      operation: .rewriteASIF,
      operationID: operationID,
      machineID: UUID(),
      sourcePath: "Installed/Disk.asif",
      destinationPath:
        "Installed/Disk-\(operationID.uuidString.lowercased()).asif",
      stagingPath:
        "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial",
      sourceIdentity: identity(inode: 1),
      sourceLogicalBytes: 8 * VirtualMachineResources.bytesPerGiB,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let store = FileVirtualMachineDiskImageReplacementJournalStore()

    try store.save(journal, in: bundle)

    let decoded = try #require(try store.load(in: bundle))
    #expect(decoded.operation == .rewriteASIF)
    #expect(decoded.sourceFormat == .asif)
    #expect(decoded.destinationFormat == .asif)
  }

  private func temporaryBundle() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func migrationJournal(
    operationID: UUID
  ) -> VirtualMachineDiskImageReplacementJournal {
    VirtualMachineDiskImageReplacementJournal(
      version: VirtualMachineDiskImageReplacementJournal.currentVersion,
      operationID: operationID,
      machineID: UUID(),
      sourcePath: "Installed/Disk.img",
      destinationPath: "Installed/Disk.asif",
      stagingPath:
        "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial",
      sourceIdentity: identity(inode: 1),
      sourceLogicalBytes: 8 * VirtualMachineResources.bytesPerGiB,
      destinationIdentity: nil,
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
  }

  private func identity(
    inode: UInt64,
    statusNanoseconds: Int64 = 0
  ) -> VirtualMachineStorageArtifactIdentity {
    VirtualMachineStorageArtifactIdentity(
      device: 1,
      inode: inode,
      fileType: .regularFile,
      ownerUserID: UInt32(geteuid()),
      linkCount: 1,
      logicalBytes: 4_096,
      allocatedBytes: 4_096,
      entryCount: 1,
      modificationSeconds: 1,
      modificationNanoseconds: 0,
      statusChangeSeconds: 1,
      statusChangeNanoseconds: statusNanoseconds,
      treeFingerprint: "identity-\(inode)-\(statusNanoseconds)"
    )
  }
}
