import Darwin
import Foundation

protocol VirtualMachineDiskImageResizeJournaling: Sendable {
  func load(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageResizeJournal?
  func save(
    _ journal: VirtualMachineDiskImageResizeJournal,
    in bundleURL: URL
  ) throws
  func remove(
    _ journal: VirtualMachineDiskImageResizeJournal,
    from bundleURL: URL
  ) throws
}

struct FileVirtualMachineDiskImageResizeJournalStore:
  VirtualMachineDiskImageResizeJournaling,
  @unchecked Sendable
{
  static let filename = VirtualMachineDiskImageResizeArtifacts.journalFilename
  private static let maximumJournalBytes: off_t = 64 * 1_024

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func load(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageResizeJournal? {
    let url = journalURL(in: bundleURL)
    var pathMetadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &pathMetadata) == 0 else {
      if errno == ENOENT { return nil }
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }

    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumJournalBytes,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      let data = try handle.readToEnd()
    else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }

    let journal: VirtualMachineDiskImageResizeJournal
    do {
      journal = try JSONDecoder().decode(
        VirtualMachineDiskImageResizeJournal.self,
        from: data
      )
    } catch {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    try validate(journal)
    return journal
  }

  func save(
    _ journal: VirtualMachineDiskImageResizeJournal,
    in bundleURL: URL
  ) throws {
    try validate(journal)
    if let existing = try load(in: bundleURL) {
      try validateTransition(from: existing, to: journal)
    } else if journal.phase != .planned || journal.resizedIdentity != nil {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = journalURL(in: bundleURL)
    try encoder.encode(journal).write(to: url, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
    try fullySyncFile(at: url)
    try synchronizeDirectory(bundleURL)
  }

  func remove(
    _ journal: VirtualMachineDiskImageResizeJournal,
    from bundleURL: URL
  ) throws {
    guard try load(in: bundleURL) == journal else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    try fileManager.removeItem(at: journalURL(in: bundleURL))
    try synchronizeDirectory(bundleURL)
  }

  private func validate(
    _ journal: VirtualMachineDiskImageResizeJournal
  ) throws {
    let hasResizedImage = journal.phase != .planned
    guard journal.version == VirtualMachineDiskImageResizeJournal.currentVersion,
      isSafeRelativePath(journal.diskImagePath),
      isSafeRelativePath(journal.resizeArtifactPath),
      journal.sourceIdentity.fileType == .regularFile,
      journal.sourceIdentity.ownerUserID == UInt32(Darwin.geteuid()),
      journal.sourceIdentity.linkCount == 1,
      journal.sourceLogicalBytes > 0,
      journal.sourceBlockSizeBytes > 0,
      journal.sourceLogicalBytes.isMultiple(of: journal.sourceBlockSizeBytes),
      journal.targetLogicalBytes > journal.sourceLogicalBytes,
      journal.targetLogicalBytes.isMultiple(of: journal.sourceBlockSizeBytes),
      hasResizedImage == (journal.resizedIdentity != nil)
    else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }

    if let resizedIdentity = journal.resizedIdentity {
      guard resizedIdentity.fileType == .regularFile,
        resizedIdentity.ownerUserID == UInt32(Darwin.geteuid()),
        resizedIdentity.linkCount == 1,
        resizedIdentity.refersToSameFileNode(as: journal.sourceIdentity)
      else {
        throw VirtualMachineDiskImageResizeError.invalidJournal
      }
    }
  }

  private func validateTransition(
    from current: VirtualMachineDiskImageResizeJournal,
    to updated: VirtualMachineDiskImageResizeJournal
  ) throws {
    guard current.version == updated.version,
      current.operationID == updated.operationID,
      current.machineID == updated.machineID,
      current.guest == updated.guest,
      current.diskImagePath == updated.diskImagePath,
      current.resizeArtifactPath == updated.resizeArtifactPath,
      current.diskImageFormat == updated.diskImageFormat,
      current.sourceIdentity == updated.sourceIdentity,
      current.sourceLogicalBytes == updated.sourceLogicalBytes,
      current.sourceBlockSizeBytes == updated.sourceBlockSizeBytes,
      current.targetLogicalBytes == updated.targetLogicalBytes
    else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }

    switch current.phase {
    case .planned:
      guard updated.phase == .imageExtended,
        updated.resizedIdentity != nil
      else {
        throw VirtualMachineDiskImageResizeError.invalidJournal
      }
    case .imageExtended:
      guard updated.phase == .manifestUpdated,
        current.resizedIdentity == updated.resizedIdentity
      else {
        throw VirtualMachineDiskImageResizeError.invalidJournal
      }
    case .manifestUpdated:
      throw VirtualMachineDiskImageResizeError.invalidJournal
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

  private func fullySyncFile(at url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    defer { Darwin.close(descriptor) }
    if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
      Darwin.fsync(descriptor) != 0
    {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
