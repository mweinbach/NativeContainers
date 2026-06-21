import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineDiskImageMigrationJournalTests {
  @Test
  func persistsEveryOrderedMigrationPhaseAndRemovesExactJournal() throws {
    let bundle = temporaryBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let store = FileVirtualMachineDiskImageMigrationJournalStore()
    let operationID = UUID()
    var journal = migrationJournal(operationID: operationID)

    try store.save(journal, in: bundle)
    #expect(try store.load(in: bundle) == journal)

    let destinationIdentity = identity(inode: 2, statusNanoseconds: 1)
    journal.destinationIdentity = destinationIdentity
    journal.phase = .converted
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
    let store = FileVirtualMachineDiskImageMigrationJournalStore()
    var journal = migrationJournal(operationID: UUID())
    try store.save(journal, in: bundle)

    journal.destinationIdentity = identity(inode: 2)
    journal.phase = .promoted

    #expect(
      throws: VirtualMachineDiskImageMigrationError.invalidJournal
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
        path: FileVirtualMachineDiskImageMigrationJournalStore.filename
      ),
      withDestinationURL: target
    )

    #expect(
      throws: VirtualMachineDiskImageMigrationError.invalidJournal
    ) {
      _ = try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: bundle
      )
    }
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
  ) -> VirtualMachineDiskImageMigrationJournal {
    VirtualMachineDiskImageMigrationJournal(
      version: VirtualMachineDiskImageMigrationJournal.currentVersion,
      operationID: operationID,
      machineID: UUID(),
      sourcePath: "Installed/Disk.img",
      destinationPath: "Installed/Disk.asif",
      stagingPath:
        "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial",
      sourceIdentity: identity(inode: 1),
      sourceLogicalBytes: 8 * VirtualMachineResources.bytesPerGiB,
      destinationIdentity: nil,
      phase: .planned
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
