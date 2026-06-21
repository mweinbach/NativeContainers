import Darwin
import Foundation

@_silgen_name("flock")
private func nativeFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct PrivateImageBuildHistoryDirectory: Sendable {
  struct Entry: Sendable {
    let name: String
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
  }

  struct Listing: Sendable {
    let entries: [Entry]
    let hasMore: Bool
  }

  struct ChangeToken: Equatable, Sendable {
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusSeconds: Int64
    let statusNanoseconds: Int64
  }

  let rootURL: URL
  let maximumRecordBytes: Int

  init(
    rootURL: URL,
    maximumRecordBytes: Int
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.maximumRecordBytes = maximumRecordBytes
  }

  func withDescriptor<T>(
    _ operation: (Int32) throws -> T
  ) throws -> T {
    let descriptor = try openPrivateRoot()
    defer { Darwin.close(descriptor) }

    try acquireLock(
      descriptor,
      operation: LOCK_EX,
      description: "directory locking"
    )
    defer { _ = nativeFlock(descriptor, LOCK_UN) }

    return try operation(descriptor)
  }

  func withExistingDescriptor<T>(
    _ operation: (Int32) throws -> T
  ) throws -> T? {
    guard let descriptor = try openExistingPrivateRoot() else { return nil }
    defer { Darwin.close(descriptor) }

    try acquireLock(
      descriptor,
      operation: LOCK_EX,
      description: "directory locking"
    )
    defer { _ = nativeFlock(descriptor, LOCK_UN) }

    return try operation(descriptor)
  }

  func changeToken(rootDescriptor: Int32) throws -> ChangeToken {
    var metadata = stat()
    guard Darwin.fstat(rootDescriptor, &metadata) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory change inspection",
        code: errno
      )
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw ImageBuildHistoryStoreError.unsafeStorage(
        rootURL.path(percentEncoded: false)
      )
    }
    return ChangeToken(
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      statusSeconds: Int64(metadata.st_ctimespec.tv_sec),
      statusNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
    )
  }

  func entries(
    rootDescriptor: Int32,
    maximumCount: Int
  ) throws -> Listing {
    let duplicate = Darwin.dup(rootDescriptor)
    guard duplicate >= 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory duplication",
        code: errno
      )
    }
    guard let directory = Darwin.fdopendir(duplicate) else {
      let code = errno
      Darwin.close(duplicate)
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory listing",
        code: code
      )
    }
    defer { Darwin.closedir(directory) }

    var entries: [Entry] = []
    errno = 0
    while let directoryEntry = Darwin.readdir(directory) {
      var nameBuffer = directoryEntry.pointee.d_name
      let name = withUnsafeBytes(of: &nameBuffer) { bytes in
        String(
          cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
        )
      }
      guard name != ".", name != ".." else {
        errno = 0
        continue
      }
      guard entries.count < maximumCount else {
        return Listing(entries: entries, hasMore: true)
      }

      var metadata = stat()
      guard
        Darwin.fstatat(
          rootDescriptor,
          name,
          &metadata,
          AT_SYMLINK_NOFOLLOW
        ) == 0
      else {
        let code = errno
        if code == ENOENT {
          errno = 0
          continue
        }
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "directory entry inspection",
          code: code
        )
      }
      entries.append(
        Entry(
          name: name,
          modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
          modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
      )
      errno = 0
    }
    guard errno == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory listing",
        code: errno
      )
    }
    return Listing(entries: entries, hasMore: false)
  }

  func read(
    named name: String,
    rootDescriptor: Int32
  ) throws -> Data? {
    let descriptor = Darwin.openat(
      rootDescriptor,
      name,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return nil }
      if code == ELOOP || code == ENOTDIR {
        throw ImageBuildHistoryStoreError.unsafeStorage(name)
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "record opening",
        code: code
      )
    }
    defer { Darwin.close(descriptor) }

    var metadata = try privateRegularMetadata(
      descriptor,
      named: name
    )
    guard metadata.st_size > 0 else {
      throw ImageBuildHistoryStoreError.unsafeStorage(name)
    }

    try enforcePrivatePermissions(descriptor, permissions: 0o600)
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "record inspection",
        code: errno
      )
    }
    guard metadata.st_size <= maximumRecordBytes else {
      throw ImageBuildHistoryStoreError.oversizedRecord(Int(metadata.st_size))
    }
    guard let byteCount = Int(exactly: metadata.st_size) else {
      throw ImageBuildHistoryStoreError.oversizedRecord(Int.max)
    }

    var data = Data(count: byteCount)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
      while offset < byteCount {
        let count = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          byteCount - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw ImageBuildHistoryStoreError.ioFailure(
            operation: "read",
            code: errno
          )
        }
        guard count > 0 else {
          throw ImageBuildHistoryStoreError.unsafeStorage(name)
        }
        offset += count
      }
    }

    var after = stat()
    guard Darwin.fstat(descriptor, &after) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "record inspection",
        code: errno
      )
    }
    guard Self.sameIdentityAndContents(metadata, after) else {
      throw ImageBuildHistoryStoreError.unsafeStorage(name)
    }
    return data
  }

  func write(
    _ data: Data,
    named name: String,
    temporaryName: String,
    rootDescriptor: Int32
  ) throws {
    guard data.count <= maximumRecordBytes else {
      throw ImageBuildHistoryStoreError.oversizedRecord(data.count)
    }

    let descriptor = Darwin.openat(
      rootDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "temporary-file creation",
        code: errno
      )
    }

    var descriptorIsOpen = true
    do {
      try enforcePrivatePermissions(descriptor, permissions: 0o600)
      try writeAll(data, to: descriptor)
      guard Darwin.fsync(descriptor) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "file synchronization",
          code: errno
        )
      }
      descriptorIsOpen = false
      guard Darwin.close(descriptor) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "file close",
          code: errno
        )
      }
    } catch {
      if descriptorIsOpen {
        Darwin.close(descriptor)
      }
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
      throw error
    }

    guard
      Darwin.renameat(
        rootDescriptor,
        temporaryName,
        rootDescriptor,
        name
      ) == 0
    else {
      let code = errno
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "atomic replacement",
        code: code
      )
    }

    do {
      try synchronize(rootDescriptor)
    } catch {
      throw ImageBuildHistoryStoreError.maintenanceAfterCommit
    }
  }

  func remove(
    named name: String,
    rootDescriptor: Int32
  ) throws -> Bool {
    let result = Darwin.unlinkat(rootDescriptor, name, 0)
    if result == 0 { return true }
    if errno == ENOENT { return false }
    throw ImageBuildHistoryStoreError.ioFailure(
      operation: "record removal",
      code: errno
    )
  }

  func discard(
    named name: String,
    rootDescriptor: Int32
  ) throws -> Bool {
    try remove(named: name, rootDescriptor: rootDescriptor)
  }

  func acquireLease(
    named name: String,
    rootDescriptor: Int32
  ) throws -> Int32 {
    let descriptor = Darwin.openat(
      rootDescriptor,
      name,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
      0o600
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP || code == ENOTDIR || code == EISDIR {
        throw ImageBuildHistoryStoreError.unsafeStorage(name)
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "launch lease opening",
        code: code
      )
    }

    do {
      _ = try privateRegularMetadata(descriptor, named: name)
      try enforcePrivatePermissions(descriptor, permissions: 0o600)
      try acquireLock(
        descriptor,
        operation: LOCK_EX | LOCK_NB,
        description: "launch lease acquisition"
      )
      guard Darwin.fsync(descriptor) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "launch lease synchronization",
          code: errno
        )
      }
      try synchronize(rootDescriptor)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  func isLeaseActive(
    named name: String,
    rootDescriptor: Int32
  ) throws -> Bool {
    let descriptor = Darwin.openat(
      rootDescriptor,
      name,
      O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return false }
      if code == ELOOP || code == ENOTDIR || code == EISDIR {
        throw ImageBuildHistoryStoreError.unsafeStorage(name)
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "launch lease opening",
        code: code
      )
    }
    defer { Darwin.close(descriptor) }

    _ = try privateRegularMetadata(descriptor, named: name)
    try enforcePrivatePermissions(descriptor, permissions: 0o600)

    while nativeFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      if code == EINTR { continue }
      if code == EWOULDBLOCK || code == EAGAIN {
        return true
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "launch lease inspection",
        code: code
      )
    }

    let didRemove = try remove(named: name, rootDescriptor: rootDescriptor)
    if didRemove {
      try synchronize(rootDescriptor)
    }
    return false
  }

  func synchronize(_ rootDescriptor: Int32) throws {
    guard Darwin.fsync(rootDescriptor) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory synchronization",
        code: errno
      )
    }
  }

  private func createPrivateParentDirectories(_ parentURL: URL) throws {
    var missingDirectories: [URL] = []
    var existingAncestor = parentURL.standardizedFileURL

    while !FileManager.default.fileExists(
      atPath: existingAncestor.path(percentEncoded: false)
    ) {
      missingDirectories.append(existingAncestor)
      let next = existingAncestor.deletingLastPathComponent()
      guard next.path(percentEncoded: false) != existingAncestor.path(percentEncoded: false)
      else {
        throw ImageBuildHistoryStoreError.unsafeStorage(
          parentURL.path(percentEncoded: false)
        )
      }
      existingAncestor = next
    }

    do {
      try FileManager.default.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory creation",
        code: Int32((error as NSError).code)
      )
    }

    for createdURL in missingDirectories.reversed() {
      let descriptor = try openCanonicalDirectory(createdURL)
      do {
        try enforcePrivatePermissions(descriptor, permissions: 0o700)
        try synchronize(descriptor)
        Darwin.close(descriptor)
      } catch {
        Darwin.close(descriptor)
        throw error
      }

      let parentDescriptor = try openCanonicalDirectory(
        createdURL.deletingLastPathComponent()
      )
      do {
        try synchronize(parentDescriptor)
        Darwin.close(parentDescriptor)
      } catch {
        Darwin.close(parentDescriptor)
        throw error
      }
    }
  }

  private func openExistingPrivateRoot() throws -> Int32? {
    let parentURL = rootURL.deletingLastPathComponent()
    guard
      FileManager.default.fileExists(
        atPath: parentURL.path(percentEncoded: false)
      )
    else {
      return nil
    }

    let parentDescriptor = try openCanonicalDirectory(parentURL)
    defer { Darwin.close(parentDescriptor) }

    let name = rootURL.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw ImageBuildHistoryStoreError.unsafeStorage(
        rootURL.path(percentEncoded: false)
      )
    }

    let descriptor = Darwin.openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return nil }
      if code == ELOOP || code == ENOTDIR {
        throw ImageBuildHistoryStoreError.unsafeStorage(
          rootURL.path(percentEncoded: false)
        )
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory opening",
        code: code
      )
    }

    do {
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "directory inspection",
          code: errno
        )
      }
      guard
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
      else {
        throw ImageBuildHistoryStoreError.unsafeStorage(
          rootURL.path(percentEncoded: false)
        )
      }
      try enforcePrivatePermissions(descriptor, permissions: 0o700)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func openPrivateRoot() throws -> Int32 {
    let parentURL = rootURL.deletingLastPathComponent()
    try createPrivateParentDirectories(parentURL)

    let parentDescriptor = try openCanonicalDirectory(parentURL)
    defer { Darwin.close(parentDescriptor) }

    let name = rootURL.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw ImageBuildHistoryStoreError.unsafeStorage(
        rootURL.path(percentEncoded: false)
      )
    }

    let didCreate: Bool
    if Darwin.mkdirat(parentDescriptor, name, 0o700) == 0 {
      didCreate = true
    } else if errno == EEXIST {
      didCreate = false
    } else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory creation",
        code: errno
      )
    }

    let descriptor = Darwin.openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw ImageBuildHistoryStoreError.unsafeStorage(
        rootURL.path(percentEncoded: false)
      )
    }

    do {
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "directory inspection",
          code: errno
        )
      }
      guard
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
      else {
        throw ImageBuildHistoryStoreError.unsafeStorage(
          rootURL.path(percentEncoded: false)
        )
      }

      try enforcePrivatePermissions(descriptor, permissions: 0o700)
      if didCreate {
        try synchronize(parentDescriptor)
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func openCanonicalDirectory(_ url: URL) throws -> Int32 {
    guard let resolvedPath = Darwin.realpath(url.path(percentEncoded: false), nil) else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory resolution",
        code: errno
      )
    }
    defer { Darwin.free(resolvedPath) }
    let components = URL(
      filePath: String(cString: resolvedPath),
      directoryHint: .isDirectory
    ).pathComponents

    var descriptor = Darwin.open(
      "/",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "directory opening",
        code: errno
      )
    }

    for component in components where component != "/" {
      let next = Darwin.openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard next >= 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "directory opening",
          code: code
        )
      }
      Darwin.close(descriptor)
      descriptor = next
    }
    return descriptor
  }

  private func privateRegularMetadata(
    _ descriptor: Int32,
    named name: String
  ) throws -> stat {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "record inspection",
        code: errno
      )
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else {
      throw ImageBuildHistoryStoreError.unsafeStorage(name)
    }
    return metadata
  }

  private func enforcePrivatePermissions(
    _ descriptor: Int32,
    permissions: mode_t
  ) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "permission inspection",
        code: errno
      )
    }

    var didRepair = false
    if try hasExtendedACL(descriptor) {
      try removeExtendedACL(descriptor)
      didRepair = true
    }
    if metadata.st_mode & 0o777 != permissions {
      guard Darwin.fchmod(descriptor, permissions) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "permission update",
          code: errno
        )
      }
      didRepair = true
    }
    if didRepair {
      guard Darwin.fsync(descriptor) == 0 else {
        throw ImageBuildHistoryStoreError.ioFailure(
          operation: "privacy repair synchronization",
          code: errno
        )
      }
    }

    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "permission verification",
        code: errno
      )
    }
    guard
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == permissions
    else {
      throw ImageBuildHistoryStoreError.unsafeStorage(
        rootURL.path(percentEncoded: false)
      )
    }
  }

  private func hasExtendedACL(_ descriptor: Int32) throws -> Bool {
    errno = 0
    guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      let code = errno
      if code == 0 || code == ENOENT || code == EOPNOTSUPP {
        return false
      }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "ACL inspection",
        code: code
      )
    }
    Darwin.acl_free(UnsafeMutableRawPointer(acl))
    return true
  }

  private func removeExtendedACL(_ descriptor: Int32) throws {
    guard let emptyACL = Darwin.acl_init(0) else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "ACL allocation",
        code: errno
      )
    }
    defer { Darwin.acl_free(UnsafeMutableRawPointer(emptyACL)) }

    guard Darwin.acl_set_fd(descriptor, emptyACL) == 0 else {
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: "ACL removal",
        code: errno
      )
    }
  }

  private func acquireLock(
    _ descriptor: Int32,
    operation: Int32,
    description: String
  ) throws {
    while nativeFlock(descriptor, operation) != 0 {
      let code = errno
      if code == EINTR { continue }
      throw ImageBuildHistoryStoreError.ioFailure(
        operation: description,
        code: code
      )
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw ImageBuildHistoryStoreError.ioFailure(
            operation: "write",
            code: errno
          )
        }
        guard count > 0 else {
          throw ImageBuildHistoryStoreError.ioFailure(
            operation: "write",
            code: EIO
          )
        }
        offset += count
      }
    }
  }

  private static func sameIdentityAndContents(
    _ lhs: stat,
    _ rhs: stat
  ) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_size == rhs.st_size
      && lhs.st_uid == rhs.st_uid
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_mode == rhs.st_mode
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
}
