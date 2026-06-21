import Darwin
import Foundation

protocol VirtualMachineDiskImageMigrationJournaling: Sendable {
  func load(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageMigrationJournal?
  func save(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    in bundleURL: URL
  ) throws
  func remove(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    from bundleURL: URL
  ) throws
}

struct FileVirtualMachineDiskImageMigrationJournalStore:
  VirtualMachineDiskImageMigrationJournaling,
  @unchecked Sendable
{
  static let filename = VirtualMachineDiskImageMigrationArtifacts.journalFilename

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func load(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageMigrationJournal? {
    let journalURL = journalURL(in: bundleURL)
    var pathMetadata = stat()
    guard
      Darwin.lstat(
        journalURL.path(percentEncoded: false),
        &pathMetadata
      ) == 0
    else {
      if errno == ENOENT {
        return nil
      }
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let descriptor = Darwin.open(
      journalURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      let data = try handle.readToEnd()
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let journal: VirtualMachineDiskImageMigrationJournal
    do {
      journal = try JSONDecoder().decode(
        VirtualMachineDiskImageMigrationJournal.self,
        from: data
      )
    } catch {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    try validate(journal)
    return journal
  }

  func save(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    in bundleURL: URL
  ) throws {
    try validate(journal)
    if let existing = try load(in: bundleURL) {
      try validateTransition(from: existing, to: journal)
    } else if journal.phase != .planned || journal.destinationIdentity != nil {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let journalURL = journalURL(in: bundleURL)
    try encoder.encode(journal).write(to: journalURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: journalURL.path
    )
    try synchronizeDirectory(bundleURL)
  }

  func remove(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    from bundleURL: URL
  ) throws {
    guard try load(in: bundleURL) == journal else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    try fileManager.removeItem(at: journalURL(in: bundleURL))
    try synchronizeDirectory(bundleURL)
  }

  private func validate(
    _ journal: VirtualMachineDiskImageMigrationJournal
  ) throws {
    let hasUnconvertedImage =
      journal.phase == .planned || journal.phase == .terminationQuarantined
    let hasValidQuarantine: Bool
    if journal.phase == .terminationQuarantined {
      switch journal.terminationQuarantine {
      case .untilAppRestart, .manualIntervention:
        hasValidQuarantine = journal.hostBootIdentifier == nil
      case .untilHostRestart:
        hasValidQuarantine =
          journal.hostBootIdentifier
          .flatMap { UUID(uuidString: $0) } != nil
      case nil:
        hasValidQuarantine = false
      }
    } else if journal.phase == .planned {
      hasValidQuarantine =
        journal.terminationQuarantine == nil
        && journal.hostBootIdentifier.flatMap { UUID(uuidString: $0) } != nil
    } else {
      hasValidQuarantine =
        journal.terminationQuarantine == nil
        && journal.hostBootIdentifier == nil
    }
    guard journal.version == VirtualMachineDiskImageMigrationJournal.currentVersion,
      journal.sourceLogicalBytes > 0,
      isSafeRelativePath(journal.sourcePath),
      isSafeRelativePath(journal.destinationPath),
      isSafeRelativePath(journal.stagingPath),
      Set([
        journal.sourcePath,
        journal.destinationPath,
        journal.stagingPath,
      ]).count == 3,
      journal.destinationPath.lowercased().hasSuffix(".asif"),
      journal.stagingPath.hasSuffix(
        "\(VirtualMachineDiskImageMigrationArtifacts.stagingPrefix)\(journal.operationID.uuidString.lowercased())\(VirtualMachineDiskImageMigrationArtifacts.stagingSuffix)"
      ),
      journal.sourceIdentity.fileType == .regularFile,
      journal.sourceIdentity.ownerUserID == UInt32(geteuid()),
      journal.sourceIdentity.linkCount == 1,
      hasUnconvertedImage == (journal.destinationIdentity == nil),
      hasValidQuarantine
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    if let destinationIdentity = journal.destinationIdentity {
      guard destinationIdentity.fileType == .regularFile,
        destinationIdentity.ownerUserID == UInt32(geteuid()),
        destinationIdentity.linkCount == 1
      else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
    }
  }

  private func validateTransition(
    from current: VirtualMachineDiskImageMigrationJournal,
    to updated: VirtualMachineDiskImageMigrationJournal
  ) throws {
    guard current.version == updated.version,
      current.operationID == updated.operationID,
      current.machineID == updated.machineID,
      current.sourcePath == updated.sourcePath,
      current.destinationPath == updated.destinationPath,
      current.stagingPath == updated.stagingPath,
      current.sourceIdentity == updated.sourceIdentity,
      current.sourceLogicalBytes == updated.sourceLogicalBytes
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let hasValidPhaseTransition: Bool
    switch current.phase {
    case .planned:
      hasValidPhaseTransition =
        updated.phase == .converted || updated.phase == .terminationQuarantined
    case .terminationQuarantined:
      hasValidPhaseTransition = false
    case .converted:
      hasValidPhaseTransition = updated.phase == .promoted
    case .promoted:
      hasValidPhaseTransition = updated.phase == .manifestUpdated
    case .manifestUpdated:
      hasValidPhaseTransition = false
    }
    guard hasValidPhaseTransition else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    if current.phase == .converted {
      guard let before = current.destinationIdentity,
        let after = updated.destinationIdentity,
        before.refersToSameStableFile(as: after)
      else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
    } else if current.phase != .planned {
      guard current.destinationIdentity == updated.destinationIdentity else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
    }
  }

  private func journalURL(in bundleURL: URL) -> URL {
    bundleURL.appending(path: Self.filename, directoryHint: .notDirectory)
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    let string = NSString(string: path)
    let components = string.pathComponents
    return !string.isAbsolutePath
      && !components.isEmpty
      && !components.contains("..")
      && components.allSatisfy { $0 != "/" && $0 != "." }
      && !path.contains("\0")
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
