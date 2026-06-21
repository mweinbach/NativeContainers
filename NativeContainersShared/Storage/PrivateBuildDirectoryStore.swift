import CryptoKit
import Darwin
import Foundation

struct PrivateBuildDirectoryArtifact: Equatable, Sendable {
  let url: URL
  let sha256: String
  let byteCount: Int64
  let entryCount: Int
}

struct PrivateBuildDirectoryIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let permissions: UInt16
  let owner: UInt32
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let sha256: String
  let byteCount: Int64
  let entryCount: Int
}

enum PrivateBuildDirectoryStoreError: Error, Equatable, Sendable {
  case destinationExists(String)
  case digestMismatch
  case byteCountMismatch
  case entryCountMismatch
  case sourceChanged
  case unsupportedEntry(String)
  case tooManyEntries
  case ioFailure(operation: String, path: String, code: Int32)
}

struct PrivateBuildDirectoryStore: Sendable {
  static let directoryName = "local"
  private static let maximumEntryCount = 500_000

  let rootDirectory: URL

  init(rootDirectory: URL = PrivateBuildArtifactStore.defaultRootDirectory()) {
    self.rootDirectory = rootDirectory.standardizedFileURL
  }

  func persist(
    sourceRootDirectory: URL,
    sourceDirectoryName: String,
    buildID: UUID
  ) throws -> PrivateBuildDirectoryArtifact {
    try ensurePrivateRoot()
    let buildName = buildID.uuidString.lowercased()
    let buildDirectory = rootDirectory.appending(
      path: buildName,
      directoryHint: .isDirectory
    )
    guard Darwin.mkdir(buildDirectory.path(percentEncoded: false), 0o700) == 0 else {
      if errno == EEXIST {
        throw PrivateBuildDirectoryStoreError.destinationExists(
          buildDirectory.path(percentEncoded: false)
        )
      }
      throw posixError("create private output directory", buildDirectory)
    }

    do {
      let source = sourceRootDirectory.standardizedFileURL
        .appending(path: sourceDirectoryName, directoryHint: .isDirectory)
        .appending(path: Self.directoryName, directoryHint: .isDirectory)
      let destination = buildDirectory.appending(
        path: Self.directoryName,
        directoryHint: .isDirectory
      )
      let sourceBefore = try treeFingerprint(at: source)
      try copyDirectory(from: source, to: destination)
      let sourceAfter = try treeFingerprint(at: source)
      guard sourceBefore == sourceAfter else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }
      let copied = try treeFingerprint(at: destination)
      guard copied.hasSameContents(as: sourceBefore) else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }

      let artifact = PrivateBuildDirectoryArtifact(
        url: destination,
        sha256: copied.sha256,
        byteCount: copied.byteCount,
        entryCount: copied.entryCount
      )
      _ = try validate(artifact, buildID: buildID)
      return artifact
    } catch {
      try? FileManager.default.removeItem(at: buildDirectory)
      throw error
    }
  }

  @discardableResult
  func validate(
    _ artifact: PrivateBuildDirectoryArtifact,
    buildID: UUID
  ) throws -> PrivateBuildDirectoryIdentity {
    let expected = artifactURL(buildID: buildID)
    guard artifact.url.standardizedFileURL == expected else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    let buildDirectory = expected.deletingLastPathComponent()
    var buildMetadata = stat()
    guard
      Darwin.lstat(buildDirectory.path(percentEncoded: false), &buildMetadata) == 0,
      buildMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      buildMetadata.st_uid == geteuid(),
      buildMetadata.st_mode & 0o077 == 0
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    let fingerprint = try treeFingerprint(at: expected)
    guard fingerprint.sha256 == artifact.sha256 else {
      throw PrivateBuildDirectoryStoreError.digestMismatch
    }
    guard fingerprint.byteCount == artifact.byteCount else {
      throw PrivateBuildDirectoryStoreError.byteCountMismatch
    }
    guard fingerprint.entryCount == artifact.entryCount else {
      throw PrivateBuildDirectoryStoreError.entryCountMismatch
    }
    return fingerprint.identity
  }

  func revalidate(
    _ artifact: PrivateBuildDirectoryArtifact,
    buildID: UUID,
    expectedIdentity: PrivateBuildDirectoryIdentity
  ) throws {
    guard try validate(artifact, buildID: buildID) == expectedIdentity else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
  }

  func copy(
    _ artifact: PrivateBuildDirectoryArtifact,
    buildID: UUID,
    expectedIdentity: PrivateBuildDirectoryIdentity,
    to destination: URL
  ) throws {
    try revalidate(
      artifact,
      buildID: buildID,
      expectedIdentity: expectedIdentity
    )
    try copyDirectory(from: artifact.url, to: destination)
    do {
      let copied = try treeFingerprint(at: destination)
      guard
        copied.sha256 == artifact.sha256,
        copied.byteCount == artifact.byteCount,
        copied.entryCount == artifact.entryCount
      else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }
      try revalidate(
        artifact,
        buildID: buildID,
        expectedIdentity: expectedIdentity
      )
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  func artifactURL(buildID: UUID) -> URL {
    rootDirectory
      .appending(
        path: buildID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      .appending(path: Self.directoryName, directoryHint: .isDirectory)
      .standardizedFileURL
  }

  private func ensurePrivateRoot() throws {
    let parent = rootDirectory.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw cocoaError("create output parent", parent, error)
    }

    if Darwin.mkdir(rootDirectory.path(percentEncoded: false), 0o700) != 0,
      errno != EEXIST
    {
      throw posixError("create output root", rootDirectory)
    }
    let descriptor = Darwin.open(
      rootDirectory.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw posixError("open output root", rootDirectory)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
    guard Darwin.fchmod(descriptor, 0o700) == 0 else {
      throw posixError("secure output root", rootDirectory)
    }
  }

  private func copyDirectory(from source: URL, to destination: URL) throws {
    let sourceMetadata = try metadata(at: source)
    guard
      sourceMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      sourceMetadata.st_uid == geteuid()
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
    guard Darwin.mkdir(destination.path(percentEncoded: false), 0o700) == 0 else {
      throw posixError("create copied directory output", destination)
    }

    do {
      let children = try sortedChildren(of: source)
      for child in children {
        try copyEntry(
          from: child,
          to: destination.appending(
            path: child.lastPathComponent,
            directoryHint: .inferFromPath
          )
        )
      }
      guard
        Darwin.chmod(
          destination.path(percentEncoded: false),
          sourceMetadata.st_mode & 0o7777
        ) == 0
      else {
        throw posixError("restore copied directory permissions", destination)
      }
      guard try metadata(at: source) == sourceMetadata else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private func copyEntry(from source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    let sourceMetadata = try metadata(at: source)
    guard sourceMetadata.st_uid == geteuid() else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    switch sourceMetadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFDIR):
      guard Darwin.mkdir(destination.path(percentEncoded: false), 0o700) == 0 else {
        throw posixError("create copied output directory", destination)
      }
      for child in try sortedChildren(of: source) {
        try copyEntry(
          from: child,
          to: destination.appending(
            path: child.lastPathComponent,
            directoryHint: .inferFromPath
          )
        )
      }
      guard
        Darwin.chmod(
          destination.path(percentEncoded: false),
          sourceMetadata.st_mode & 0o7777
        ) == 0,
        try metadata(at: source) == sourceMetadata
      else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }

    case mode_t(S_IFREG):
      try copyRegularFile(
        from: source,
        to: destination,
        expected: sourceMetadata
      )

    case mode_t(S_IFLNK):
      let targetData = try symlinkTarget(at: source)
      guard let target = String(data: targetData, encoding: .utf8) else {
        throw PrivateBuildDirectoryStoreError.unsupportedEntry(
          source.lastPathComponent
        )
      }
      let result = target.withCString { targetPointer in
        destination.path(percentEncoded: false).withCString { destinationPointer in
          Darwin.symlink(targetPointer, destinationPointer)
        }
      }
      guard result == 0, try metadata(at: source) == sourceMetadata else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }

    default:
      throw PrivateBuildDirectoryStoreError.unsupportedEntry(
        source.lastPathComponent
      )
    }
  }

  private func copyRegularFile(
    from source: URL,
    to destination: URL,
    expected: stat
  ) throws {
    let sourceDescriptor = Darwin.open(
      source.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard sourceDescriptor >= 0 else {
      throw posixError("open directory output source", source)
    }
    defer { Darwin.close(sourceDescriptor) }

    var opened = stat()
    guard
      Darwin.fstat(sourceDescriptor, &opened) == 0,
      opened == expected,
      opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    let destinationDescriptor = Darwin.open(
      destination.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw posixError("create copied directory output file", destination)
    }
    defer { Darwin.close(destinationDescriptor) }

    var copiedBytes: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      try Task.checkCancellation()
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount >= 0 else {
        throw posixError("read directory output source", source)
      }
      if readCount == 0 { break }

      var written = 0
      while written < readCount {
        try Task.checkCancellation()
        let writeCount = buffer.withUnsafeBytes {
          Darwin.write(
            destinationDescriptor,
            $0.baseAddress?.advanced(by: written),
            readCount - written
          )
        }
        if writeCount < 0, errno == EINTR { continue }
        guard writeCount > 0 else {
          throw posixError("write copied directory output file", destination)
        }
        written += writeCount
      }
      copiedBytes += Int64(readCount)
    }

    var after = stat()
    guard
      Darwin.fstat(sourceDescriptor, &after) == 0,
      after == opened,
      copiedBytes == Int64(opened.st_size),
      Darwin.fchmod(destinationDescriptor, opened.st_mode & 0o7777) == 0,
      Darwin.fsync(destinationDescriptor) == 0
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
  }

  private func sortedChildren(of directory: URL) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).sorted {
        Data($0.lastPathComponent.utf8).lexicographicallyPrecedes(
          Data($1.lastPathComponent.utf8)
        )
      }
    } catch {
      throw cocoaError("enumerate private directory output", directory, error)
    }
  }

  private func treeFingerprint(at root: URL) throws -> DirectoryTreeFingerprint {
    var hasher = SHA256()
    var byteCount: Int64 = 0
    var entryCount = 0
    let rootMetadata = try metadata(at: root)
    guard
      rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      rootMetadata.st_uid == geteuid()
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    try visit(
      root,
      relativePath: ".",
      isRoot: true,
      hasher: &hasher,
      byteCount: &byteCount,
      entryCount: &entryCount
    )
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return DirectoryTreeFingerprint(
      identity: PrivateBuildDirectoryIdentity(
        device: UInt64(rootMetadata.st_dev),
        inode: UInt64(rootMetadata.st_ino),
        permissions: UInt16(rootMetadata.st_mode & 0o7777),
        owner: UInt32(rootMetadata.st_uid),
        modificationSeconds: Int64(rootMetadata.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(rootMetadata.st_mtimespec.tv_nsec),
        sha256: digest,
        byteCount: byteCount,
        entryCount: entryCount
      ),
      sha256: digest,
      byteCount: byteCount,
      entryCount: entryCount
    )
  }

  private func visit(
    _ url: URL,
    relativePath: String,
    isRoot: Bool,
    hasher: inout SHA256,
    byteCount: inout Int64,
    entryCount: inout Int
  ) throws {
    try Task.checkCancellation()
    let before = try metadata(at: url)
    guard before.st_uid == geteuid() else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
    if !isRoot {
      entryCount += 1
      guard entryCount <= Self.maximumEntryCount else {
        throw PrivateBuildDirectoryStoreError.tooManyEntries
      }
    }

    let kind = before.st_mode & mode_t(S_IFMT)
    switch kind {
    case mode_t(S_IFDIR):
      hashField(Data("directory".utf8), into: &hasher)
      hashField(Data(relativePath.utf8), into: &hasher)
      hashInteger(UInt64(before.st_mode & 0o7777), into: &hasher)

      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: nil
        ).sorted {
          Data($0.lastPathComponent.utf8).lexicographicallyPrecedes(
            Data($1.lastPathComponent.utf8)
          )
        }
      } catch {
        throw cocoaError("enumerate private directory output", url, error)
      }
      for child in children {
        let name = child.lastPathComponent
        let childRelative = relativePath == "." ? name : "\(relativePath)/\(name)"
        try visit(
          child,
          relativePath: childRelative,
          isRoot: false,
          hasher: &hasher,
          byteCount: &byteCount,
          entryCount: &entryCount
        )
      }
      guard try metadata(at: url) == before else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }

    case mode_t(S_IFREG):
      hashField(Data("file".utf8), into: &hasher)
      hashField(Data(relativePath.utf8), into: &hasher)
      hashInteger(UInt64(before.st_mode & 0o7777), into: &hasher)
      hashInteger(UInt64(before.st_size), into: &hasher)
      try hashRegularFile(
        at: url,
        expected: before,
        hasher: &hasher,
        byteCount: &byteCount
      )

    case mode_t(S_IFLNK):
      hashField(Data("symlink".utf8), into: &hasher)
      hashField(Data(relativePath.utf8), into: &hasher)
      let target = try symlinkTarget(at: url)
      hashField(target, into: &hasher)
      byteCount += Int64(target.count)
      guard try metadata(at: url) == before else {
        throw PrivateBuildDirectoryStoreError.sourceChanged
      }

    default:
      throw PrivateBuildDirectoryStoreError.unsupportedEntry(relativePath)
    }
  }

  private func hashRegularFile(
    at url: URL,
    expected: stat,
    hasher: inout SHA256,
    byteCount: inout Int64
  ) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      throw posixError("open private directory output file", url)
    }
    defer { Darwin.close(descriptor) }

    var opened = stat()
    guard
      Darwin.fstat(descriptor, &opened) == 0,
      opened == expected,
      opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }

    var fileByteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      try Task.checkCancellation()
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount >= 0 else {
        throw posixError("read private directory output file", url)
      }
      if readCount == 0 { break }
      hasher.update(data: Data(buffer[0..<readCount]))
      fileByteCount += Int64(readCount)
    }

    var after = stat()
    guard
      Darwin.fstat(descriptor, &after) == 0,
      after == opened,
      fileByteCount == Int64(opened.st_size)
    else {
      throw PrivateBuildDirectoryStoreError.sourceChanged
    }
    byteCount += fileByteCount
  }

  private func symlinkTarget(at url: URL) throws -> Data {
    var capacity = 256
    while capacity <= 1024 * 1024 {
      var buffer = [UInt8](repeating: 0, count: capacity)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.readlink(
          url.path(percentEncoded: false),
          $0.baseAddress?.assumingMemoryBound(to: CChar.self),
          $0.count
        )
      }
      guard count >= 0 else {
        throw posixError("read private directory output symlink", url)
      }
      if count < capacity {
        return Data(buffer[0..<count])
      }
      capacity *= 2
    }
    throw PrivateBuildDirectoryStoreError.sourceChanged
  }

  private func metadata(at url: URL) throws -> stat {
    var value = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &value) == 0 else {
      throw posixError("inspect private directory output", url)
    }
    return value
  }

  private func hashField(_ data: Data, into hasher: inout SHA256) {
    hashInteger(UInt64(data.count), into: &hasher)
    hasher.update(data: data)
  }

  private func hashInteger(_ value: UInt64, into hasher: inout SHA256) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
  }

  private func posixError(
    _ operation: String,
    _ url: URL
  ) -> PrivateBuildDirectoryStoreError {
    .ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: errno
    )
  }

  private func cocoaError(
    _ operation: String,
    _ url: URL,
    _ error: any Error
  ) -> PrivateBuildDirectoryStoreError {
    let value = error as NSError
    return .ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: value.domain == NSPOSIXErrorDomain ? Int32(value.code) : EIO
    )
  }
}

private struct DirectoryTreeFingerprint: Equatable {
  let identity: PrivateBuildDirectoryIdentity
  let sha256: String
  let byteCount: Int64
  let entryCount: Int

  func hasSameContents(as other: DirectoryTreeFingerprint) -> Bool {
    sha256 == other.sha256
      && byteCount == other.byteCount
      && entryCount == other.entryCount
  }
}

private func == (lhs: stat, rhs: stat) -> Bool {
  UInt64(lhs.st_dev) == UInt64(rhs.st_dev)
    && UInt64(lhs.st_ino) == UInt64(rhs.st_ino)
    && lhs.st_mode == rhs.st_mode
    && UInt32(lhs.st_uid) == UInt32(rhs.st_uid)
    && UInt64(lhs.st_nlink) == UInt64(rhs.st_nlink)
    && Int64(lhs.st_size) == Int64(rhs.st_size)
    && Int64(lhs.st_mtimespec.tv_sec) == Int64(rhs.st_mtimespec.tv_sec)
    && Int64(lhs.st_mtimespec.tv_nsec) == Int64(rhs.st_mtimespec.tv_nsec)
}
