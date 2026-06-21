import Darwin
import Foundation

struct ComposeOperationJournalFileStore {
  private static let recordSuffix = ".json"
  private static let temporaryPrefix = ".pending-"

  private let directoryURL: URL
  private let effectiveUserID: uid_t
  private let durabilitySyncer: any ComposeOperationJournalDurabilitySyncing
  private let fileManager: FileManager

  init(
    directoryURL: URL,
    effectiveUserID: uid_t,
    durabilitySyncer: any ComposeOperationJournalDurabilitySyncing,
    fileManager: FileManager
  ) {
    var directoryPath = directoryURL.path(percentEncoded: false)
    while directoryPath.count > 1 && directoryPath.hasSuffix("/") {
      directoryPath.removeLast()
    }
    self.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: false)
    self.effectiveUserID = effectiveUserID
    self.durabilitySyncer = durabilitySyncer
    self.fileManager = fileManager
  }

  static func recordFilename(for operationID: UUID) -> String {
    "\(operationID.uuidString.lowercased())\(recordSuffix)"
  }

  func createRecord(_ data: Data, operationID: UUID) throws {
    try validateEncodedSize(data)
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: true) else {
      throw ComposeOperationJournalError.unsafeDirectory("the directory could not be created")
    }
    defer { Darwin.close(directoryDescriptor) }

    let finalName = Self.recordFilename(for: operationID)
    if let metadata = try entryMetadata(
      named: finalName,
      directoryDescriptor: directoryDescriptor
    ) {
      try validateRecordMetadata(metadata, name: finalName)
      throw ComposeOperationJournalError.recordAlreadyExists(operationID)
    }

    let temporaryName =
      "\(Self.temporaryPrefix)\(operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    try writeTemporaryRecord(
      data,
      named: temporaryName,
      directoryDescriptor: directoryDescriptor,
      operationDescription: "pending record"
    )
    var temporaryExists = true
    defer {
      if temporaryExists {
        _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
      }
    }

    guard
      Darwin.renameatx_np(
        directoryDescriptor,
        temporaryName,
        directoryDescriptor,
        finalName,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      let code = errno
      if code == EEXIST,
        let metadata = try entryMetadata(
          named: finalName,
          directoryDescriptor: directoryDescriptor
        )
      {
        try validateRecordMetadata(metadata, name: finalName)
        throw ComposeOperationJournalError.recordAlreadyExists(operationID)
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "publish a pending record atomically",
        code: code
      )
    }
    temporaryExists = false
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  func updateRecord(
    operationID: UUID,
    transform: (Data) throws -> Data
  ) throws {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      throw ComposeOperationJournalError.invalidRecord("the pending operation is missing")
    }
    defer { Darwin.close(directoryDescriptor) }

    let name = Self.recordFilename(for: operationID)
    let currentData = try readRecord(
      named: name,
      directoryDescriptor: directoryDescriptor
    )
    let updatedData = try transform(currentData)
    try validateEncodedSize(updatedData)

    guard
      let metadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      throw ComposeOperationJournalError.invalidRecord(
        "the pending operation disappeared before its progress was saved"
      )
    }
    try validateRecordMetadata(metadata, name: name)
    try replaceRecord(
      updatedData,
      named: name,
      operationID: operationID,
      directoryDescriptor: directoryDescriptor
    )
  }

  func allRecords() throws -> [(operationID: UUID, data: Data)] {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      return []
    }
    defer { Darwin.close(directoryDescriptor) }

    let names: [String]
    do {
      names = try fileManager.contentsOfDirectory(atPath: directoryURL.path(percentEncoded: false))
    } catch {
      throw posixError("enumerate pending records")
    }

    return try names.compactMap { name in
      guard name.hasSuffix(Self.recordSuffix) else { return nil }
      guard let operationID = Self.operationID(fromRecordFilename: name) else {
        throw ComposeOperationJournalError.invalidRecord(
          "an unexpected record filename is present"
        )
      }
      return (
        operationID,
        try readRecord(named: name, directoryDescriptor: directoryDescriptor)
      )
    }
  }

  func discardRecord(operationID: UUID) throws {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      return
    }
    defer { Darwin.close(directoryDescriptor) }

    let name = Self.recordFilename(for: operationID)
    guard
      let metadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      return
    }
    try validateRecordMetadata(metadata, name: name)

    guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 else {
      throw posixError("discard a reviewed pending record")
    }
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  private func replaceRecord(
    _ data: Data,
    named name: String,
    operationID: UUID,
    directoryDescriptor: Int32
  ) throws {
    let temporaryName =
      "\(Self.temporaryPrefix)update-\(operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    try writeTemporaryRecord(
      data,
      named: temporaryName,
      directoryDescriptor: directoryDescriptor,
      operationDescription: "pending progress update"
    )
    var temporaryExists = true
    defer {
      if temporaryExists {
        _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
      }
    }

    guard
      Darwin.renameat(
        directoryDescriptor,
        temporaryName,
        directoryDescriptor,
        name
      ) == 0
    else {
      throw posixError("publish a pending progress update atomically")
    }
    temporaryExists = false
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  private func writeTemporaryRecord(
    _ data: Data,
    named name: String,
    directoryDescriptor: Int32,
    operationDescription: String
  ) throws {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw posixError("create a \(operationDescription)")
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen {
        Darwin.close(descriptor)
      }
    }

    do {
      guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
        throw posixError("make a \(operationDescription) owner-private")
      }
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw posixError("inspect a \(operationDescription)")
      }
      try validateRecordSecurityMetadata(metadata, name: name)
      try writeAll(data, descriptor: descriptor)
      try durabilitySyncer.syncFile(descriptor: descriptor)

      guard Darwin.close(descriptor) == 0 else {
        descriptorIsOpen = false
        throw posixError("close a \(operationDescription)")
      }
      descriptorIsOpen = false
    } catch {
      _ = Darwin.unlinkat(directoryDescriptor, name, 0)
      throw error
    }
  }

  private func readRecord(
    named name: String,
    directoryDescriptor: Int32
  ) throws -> Data {
    guard
      let pathMetadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      throw ComposeOperationJournalError.invalidRecord("a pending record disappeared")
    }
    try validateRecordMetadata(pathMetadata, name: name)

    let descriptor = Darwin.openat(
      directoryDescriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        throw ComposeOperationJournalError.unsafeRecord(
          name: name,
          reason: "symbolic links are not allowed"
        )
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "open a pending record",
        code: code
      )
    }
    defer { Darwin.close(descriptor) }

    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
      throw posixError("inspect an opened pending record")
    }
    try validateRecordMetadata(openedMetadata, name: name)
    guard sameFile(pathMetadata, openedMetadata) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record changed while it was opened"
      )
    }

    let data = try readAll(
      descriptor: descriptor,
      expectedByteCount: Int(openedMetadata.st_size),
      name: name
    )
    var finalMetadata = stat()
    guard Darwin.fstat(descriptor, &finalMetadata) == 0 else {
      throw posixError("reinspect a pending record")
    }
    guard stableFile(openedMetadata, finalMetadata) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record changed while it was read"
      )
    }
    return data
  }

  private func openJournalDirectory(createIfMissing: Bool) throws -> Int32? {
    guard directoryURL.isFileURL, !directoryURL.lastPathComponent.isEmpty else {
      throw ComposeOperationJournalError.unsafeDirectory("the location is not a local directory")
    }

    let path = directoryURL.path(percentEncoded: false)
    var pathMetadata = stat()
    if Darwin.lstat(path, &pathMetadata) != 0 {
      let code = errno
      if code == ENOENT {
        guard createIfMissing else { return nil }
        try createJournalDirectory()
        guard Darwin.lstat(path, &pathMetadata) == 0 else {
          throw posixError("inspect the created journal directory")
        }
      } else {
        throw ComposeOperationJournalError.ioFailure(
          operation: "inspect the journal directory",
          code: code
        )
      }
    }
    try validateDirectoryMetadata(pathMetadata)

    let descriptor = Darwin.open(
      path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        throw ComposeOperationJournalError.unsafeDirectory(
          "symbolic links are not allowed"
        )
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "open the journal directory",
        code: code
      )
    }

    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
      Darwin.close(descriptor)
      throw posixError("inspect the opened journal directory")
    }
    do {
      try validateDirectoryMetadata(openedMetadata)
      guard sameFile(pathMetadata, openedMetadata) else {
        throw ComposeOperationJournalError.unsafeDirectory(
          "the directory changed while it was opened"
        )
      }
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func createJournalDirectory() throws {
    let parentURL = directoryURL.deletingLastPathComponent()
    let name = directoryURL.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else {
      throw ComposeOperationJournalError.unsafeDirectory("the directory name is invalid")
    }

    let parentDescriptor = Darwin.open(
      parentURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else {
      throw posixError("open the journal parent directory")
    }
    defer { Darwin.close(parentDescriptor) }

    if Darwin.mkdirat(parentDescriptor, name, mode_t(0o700)) != 0, errno != EEXIST {
      throw posixError("create the journal directory")
    }

    let directoryDescriptor = Darwin.openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      throw posixError("open the created journal directory")
    }
    defer { Darwin.close(directoryDescriptor) }

    var metadata = stat()
    guard Darwin.fstat(directoryDescriptor, &metadata) == 0 else {
      throw posixError("inspect the created journal directory")
    }
    if metadata.st_uid == effectiveUserID,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    {
      guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
        throw posixError("make the journal directory owner-private")
      }
    }
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
    try durabilitySyncer.syncDirectory(descriptor: parentDescriptor)
  }

  private func entryMetadata(
    named name: String,
    directoryDescriptor: Int32
  ) throws -> stat? {
    var metadata = stat()
    if Darwin.fstatat(
      directoryDescriptor,
      name,
      &metadata,
      AT_SYMLINK_NOFOLLOW
    ) == 0 {
      return metadata
    }
    let code = errno
    guard code == ENOENT else {
      throw ComposeOperationJournalError.ioFailure(
        operation: "inspect a pending record",
        code: code
      )
    }
    return nil
  }

  private func validateDirectoryMetadata(_ metadata: stat) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal location is not a directory"
      )
    }
    guard metadata.st_uid == effectiveUserID else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal directory is not owned by the current user"
      )
    }
    guard metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal directory permissions must be 0700"
      )
    }
  }

  private func validateRecordMetadata(_ metadata: stat, name: String) throws {
    try validateRecordSecurityMetadata(metadata, name: name)
    guard metadata.st_size > 0 else {
      throw ComposeOperationJournalError.invalidRecord("a pending record is empty")
    }
    guard metadata.st_size <= ComposeOperationJournal.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(metadata.st_size))
    }
  }

  private func validateRecordSecurityMetadata(
    _ metadata: stat,
    name: String
  ) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "only regular files are allowed"
      )
    }
    guard metadata.st_uid == effectiveUserID else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record is not owned by the current user"
      )
    }
    guard metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "record permissions must be 0600"
      )
    }
    guard metadata.st_nlink == 1 else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "hard-linked records are not allowed"
      )
    }
  }

  private func validateEncodedSize(_ data: Data) throws {
    guard data.count <= ComposeOperationJournal.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(data.count))
    }
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw posixError("write a pending record")
        }
        guard written > 0 else {
          throw ComposeOperationJournalError.ioFailure(
            operation: "write a pending record",
            code: EIO
          )
        }
        offset += written
      }
    }
  }

  private func readAll(
    descriptor: Int32,
    expectedByteCount: Int,
    name: String
  ) throws -> Data {
    var data = Data()
    data.reserveCapacity(expectedByteCount)
    var buffer = [UInt8](repeating: 0, count: min(8_192, expectedByteCount))

    while data.count < expectedByteCount {
      let requested = min(buffer.count, expectedByteCount - data.count)
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requested)
      }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw posixError("read a pending record")
      }
      guard readCount > 0 else {
        throw ComposeOperationJournalError.unsafeRecord(
          name: name,
          reason: "the record was truncated while it was read"
        )
      }
      data.append(contentsOf: buffer.prefix(readCount))
    }
    return data
  }

  private func posixError(_ operation: String) -> ComposeOperationJournalError {
    ComposeOperationJournalError.ioFailure(operation: operation, code: errno)
  }

  private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
    sameFile(lhs, rhs)
      && lhs.st_size == rhs.st_size
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func operationID(fromRecordFilename name: String) -> UUID? {
    guard name.hasSuffix(recordSuffix) else { return nil }
    let identifier = String(name.dropLast(recordSuffix.count))
    guard identifier == identifier.lowercased() else { return nil }
    return UUID(uuidString: identifier)
  }
}
