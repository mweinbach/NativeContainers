import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineDiskImageResizeJournalTests {
  @Test
  func persistsOnlyForwardResizePhasesAndRemovesExactJournal() throws {
    let fixture = try DiskImageResizeJournalFixture()
    defer { fixture.remove() }

    var journal = fixture.journal
    try fixture.store.save(journal, in: fixture.bundleURL)
    #expect(try fixture.store.load(in: fixture.bundleURL) == journal)

    journal.resizedIdentity = fixture.resizedIdentity
    journal.phase = .imageExtended
    try fixture.store.save(journal, in: fixture.bundleURL)

    journal.phase = .manifestUpdated
    try fixture.store.save(journal, in: fixture.bundleURL)
    try fixture.store.remove(journal, from: fixture.bundleURL)
    #expect(try fixture.store.load(in: fixture.bundleURL) == nil)
  }

  @Test
  func rejectsSkippedPhaseAndChangedTransactionIdentity() throws {
    let fixture = try DiskImageResizeJournalFixture()
    defer { fixture.remove() }
    try fixture.store.save(fixture.journal, in: fixture.bundleURL)

    var skipped = fixture.journal
    skipped.resizedIdentity = fixture.resizedIdentity
    skipped.phase = .manifestUpdated
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.store.save(skipped, in: fixture.bundleURL)
    }

    let changed = VirtualMachineDiskImageResizeJournal(
      operationID: UUID(),
      machineID: fixture.journal.machineID,
      guest: fixture.journal.guest,
      diskImagePath: fixture.journal.diskImagePath,
      resizeArtifactPath: fixture.journal.resizeArtifactPath,
      diskImageFormat: fixture.journal.diskImageFormat,
      sourceIdentity: fixture.journal.sourceIdentity,
      sourceLogicalBytes: fixture.journal.sourceLogicalBytes,
      sourceBlockSizeBytes: fixture.journal.sourceBlockSizeBytes,
      targetLogicalBytes: fixture.journal.targetLogicalBytes
    )
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.store.save(changed, in: fixture.bundleURL)
    }
  }

  @Test
  func rejectsSymbolicJournalAndUnsafePaths() throws {
    let fixture = try DiskImageResizeJournalFixture()
    defer { fixture.remove() }

    let unsafe = VirtualMachineDiskImageResizeJournal(
      operationID: UUID(),
      machineID: UUID(),
      guest: .linux,
      diskImagePath: "../Disk.raw",
      resizeArtifactPath: "../Disk.raw",
      diskImageFormat: .raw,
      sourceIdentity: fixture.sourceIdentity,
      sourceLogicalBytes: fixture.sourceBytes,
      sourceBlockSizeBytes: fixture.blockSizeBytes,
      targetLogicalBytes: fixture.targetBytes
    )
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.store.save(unsafe, in: fixture.bundleURL)
    }

    let target = fixture.bundleURL.appending(path: "Elsewhere.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.journalURL,
      withDestinationURL: target
    )
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.store.load(in: fixture.bundleURL)
    }
  }
}

private struct DiskImageResizeJournalFixture {
  let blockSizeBytes: UInt64 = 512
  let sourceBytes = 8 * VirtualMachineResources.bytesPerGiB
  let targetBytes = 9 * VirtualMachineResources.bytesPerGiB
  let bundleURL: URL
  let store = FileVirtualMachineDiskImageResizeJournalStore()

  var journalURL: URL {
    bundleURL.appending(
      path: VirtualMachineDiskImageResizeArtifacts.journalFilename
    )
  }

  var sourceIdentity: VirtualMachineStorageArtifactIdentity {
    identity(logicalBytes: sourceBytes, modificationNanoseconds: 1)
  }

  var resizedIdentity: VirtualMachineStorageArtifactIdentity {
    identity(logicalBytes: targetBytes, modificationNanoseconds: 2)
  }

  var journal: VirtualMachineDiskImageResizeJournal {
    VirtualMachineDiskImageResizeJournal(
      operationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
      machineID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
      guest: .macOS,
      diskImagePath: "Disk.asif",
      resizeArtifactPath: "Snapshots/Top.asif",
      diskImageFormat: .asif,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: sourceBytes,
      sourceBlockSizeBytes: blockSizeBytes,
      targetLogicalBytes: targetBytes
    )
  }

  init() throws {
    bundleURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-DiskResizeJournal-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: false
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: bundleURL)
  }

  private func identity(
    logicalBytes: UInt64,
    modificationNanoseconds: Int64
  ) -> VirtualMachineStorageArtifactIdentity {
    VirtualMachineStorageArtifactIdentity(
      device: 7,
      inode: 11,
      fileType: .regularFile,
      ownerUserID: UInt32(Darwin.geteuid()),
      linkCount: 1,
      logicalBytes: logicalBytes,
      allocatedBytes: 4_096,
      entryCount: 1,
      modificationSeconds: 10,
      modificationNanoseconds: modificationNanoseconds,
      statusChangeSeconds: 10,
      statusChangeNanoseconds: modificationNanoseconds,
      treeFingerprint: "fingerprint-\(modificationNanoseconds)"
    )
  }
}
