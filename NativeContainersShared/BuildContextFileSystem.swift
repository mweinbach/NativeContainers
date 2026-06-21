import Darwin
import Foundation

enum BuildContextFileSystem {
  static func copyRegularFile(
    from sourceURL: URL,
    sourceSnapshot: BuildContextFileSnapshot,
    to destinationURL: URL,
    displayPath: String
  ) throws -> BuildContextFileSnapshot {
    let sourceDescriptor = Darwin.open(
      sourceURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard sourceDescriptor >= 0 else {
      throw posixError("open source file", sourceURL)
    }
    defer { Darwin.close(sourceDescriptor) }

    guard try snapshot(descriptor: sourceDescriptor, displayPath: displayPath) == sourceSnapshot
    else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }

    let destinationDescriptor = Darwin.open(
      destinationURL.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard destinationDescriptor >= 0 else {
      throw posixError("create staged file", destinationURL)
    }
    defer { Darwin.close(destinationDescriptor) }

    do {
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        try Task.checkCancellation()
        let bytesRead = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
        }
        guard bytesRead >= 0 else {
          throw posixError("read source file", sourceURL)
        }
        if bytesRead == 0 { break }

        var written = 0
        while written < bytesRead {
          let count = buffer.withUnsafeBytes { bytes in
            Darwin.write(
              destinationDescriptor,
              bytes.baseAddress?.advanced(by: written),
              bytesRead - written
            )
          }
          guard count > 0 else {
            throw posixError("write staged file", destinationURL)
          }
          written += count
        }
      }
      guard Darwin.fsync(destinationDescriptor) == 0 else {
        throw posixError("flush staged file", destinationURL)
      }
      guard try snapshot(descriptor: sourceDescriptor, displayPath: displayPath) == sourceSnapshot,
        try snapshot(at: sourceURL, displayPath: displayPath) == sourceSnapshot
      else {
        throw BuildContextStagingError.sourceChanged(displayPath)
      }
      guard Darwin.fchmod(destinationDescriptor, sourceSnapshot.permissions) == 0 else {
        throw posixError("preserve staged file permissions", destinationURL)
      }
      try setModificationTime(
        descriptor: destinationDescriptor,
        from: sourceSnapshot,
        displayPath: displayPath
      )
      let result = try snapshot(descriptor: destinationDescriptor, displayPath: displayPath)
      guard result.kind == .regularFile, result.size == sourceSnapshot.size else {
        throw BuildContextStagingError.sourceChanged(displayPath)
      }
      return result
    } catch {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }
  }

  static func setModificationTime(
    at url: URL,
    from source: BuildContextFileSnapshot,
    displayPath: String
  ) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
    )
    guard descriptor >= 0 else {
      throw posixError("open staged directory", url)
    }
    defer { Darwin.close(descriptor) }
    try setModificationTime(
      descriptor: descriptor,
      from: source,
      displayPath: displayPath
    )
  }

  static func setPermissions(
    at url: URL,
    from source: BuildContextFileSnapshot,
    displayPath: String
  ) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
    )
    guard descriptor >= 0 else {
      throw posixError("open staged directory", url)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fchmod(descriptor, source.permissions) == 0 else {
      throw BuildContextStagingError.ioFailure(
        operation: "preserve staged directory permissions",
        path: displayPath,
        code: errno
      )
    }
  }

  static func setModificationTime(
    descriptor: Int32,
    from source: BuildContextFileSnapshot,
    displayPath: String
  ) throws {
    let times = [
      timespec(tv_sec: source.modifiedSeconds, tv_nsec: source.modifiedNanoseconds),
      timespec(tv_sec: source.modifiedSeconds, tv_nsec: source.modifiedNanoseconds),
    ]
    let result = times.withUnsafeBufferPointer {
      Darwin.futimens(descriptor, $0.baseAddress)
    }
    guard result == 0 else {
      throw BuildContextStagingError.ioFailure(
        operation: "preserve staged modification time",
        path: displayPath,
        code: errno
      )
    }
  }

  static func ensurePrivateDirectory(
    _ url: URL,
    withIntermediateDirectories: Bool
  ) throws {
    let displayPath = url.lastPathComponent
    if let existing = try optionalSnapshot(at: url, displayPath: displayPath) {
      guard existing.kind == .directory, existing.owner == geteuid() else {
        throw BuildContextStagingError.stagingDirectoryNotOwned
      }
    } else {
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw ioError("create private directory", url, fallback: error)
      }
    }

    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
    )
    guard descriptor >= 0 else {
      throw posixError("open private directory", url)
    }
    defer { Darwin.close(descriptor) }
    let directorySnapshot = try snapshot(descriptor: descriptor, displayPath: displayPath)
    guard directorySnapshot.kind == .directory,
      directorySnapshot.owner == geteuid()
    else {
      throw BuildContextStagingError.stagingDirectoryNotOwned
    }
    guard Darwin.fchmod(descriptor, 0o700) == 0 else {
      throw posixError("set private directory permissions", url)
    }
    guard try snapshot(at: url, displayPath: displayPath).inode == directorySnapshot.inode else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
  }

  static func snapshot(
    at url: URL,
    displayPath: String
  ) throws -> BuildContextFileSnapshot {
    guard let value = try optionalSnapshot(at: url, displayPath: displayPath) else {
      throw BuildContextStagingError.ioFailure(
        operation: "inspect path",
        path: displayPath,
        code: ENOENT
      )
    }
    return value
  }

  static func optionalSnapshot(
    at url: URL,
    displayPath: String
  ) throws -> BuildContextFileSnapshot? {
    var value = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &value) == 0 else {
      let code = errno
      if code == ENOENT { return nil }
      throw BuildContextStagingError.ioFailure(
        operation: "inspect path",
        path: displayPath,
        code: code
      )
    }
    return BuildContextFileSnapshot(value)
  }

  static func snapshot(
    descriptor: Int32,
    displayPath: String
  ) throws -> BuildContextFileSnapshot {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
      throw BuildContextStagingError.ioFailure(
        operation: "inspect open file",
        path: displayPath,
        code: errno
      )
    }
    return BuildContextFileSnapshot(value)
  }

  static func requireFileURL(_ url: URL) throws {
    guard url.isFileURL else {
      throw BuildContextStagingError.nonFileURL(url)
    }
  }

  static func relativePath(
    for child: URL,
    within parent: URL,
    outsideError: BuildContextStagingError
  ) throws -> String {
    let childComponents = child.standardizedFileURL.pathComponents
    let parentComponents = parent.standardizedFileURL.pathComponents
    guard childComponents.count > parentComponents.count,
      childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    else {
      throw outsideError
    }
    let components = childComponents.dropFirst(parentComponents.count)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw BuildContextStagingError.invalidPath(components.joined(separator: "/"))
    }
    return components.joined(separator: "/")
  }

  static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    isContained(lhs, by: rhs) || isContained(rhs, by: lhs)
  }

  static func isContained(_ child: URL, by parent: URL) -> Bool {
    let childComponents = child.standardizedFileURL.pathComponents
    let parentComponents = parent.standardizedFileURL.pathComponents
    return childComponents.count >= parentComponents.count
      && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
  }

  static func pathByteOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
  }

  static func entryByteOrder(_ lhs: BuildContextStagedEntry, _ rhs: BuildContextStagedEntry) -> Bool
  {
    lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
  }

  static func unsupported(
    _ path: String,
    _ kind: BuildContextUnsupportedEntryKind
  ) -> BuildContextStagingError {
    .unsupportedEntry(path: path, kind: kind)
  }

  static func posixError(_ operation: String, _ url: URL) -> BuildContextStagingError {
    .ioFailure(operation: operation, path: url.path, code: errno)
  }

  static func ioError(
    _ operation: String,
    _ url: URL,
    fallback: any Error
  ) -> BuildContextStagingError {
    let code =
      (fallback as NSError).domain == NSPOSIXErrorDomain
      ? Int32((fallback as NSError).code) : EIO
    return .ioFailure(operation: operation, path: url.path, code: code)
  }

  static func defaultStagingRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Build Contexts", directoryHint: .isDirectory)
  }
}

enum BuildContextFileKind: Equatable {
  case blockDevice
  case characterDevice
  case directory
  case fifo
  case regularFile
  case socket
  case symbolicLink
  case unknown

  init(mode: mode_t) {
    switch mode & mode_t(S_IFMT) {
    case mode_t(S_IFBLK): self = .blockDevice
    case mode_t(S_IFCHR): self = .characterDevice
    case mode_t(S_IFDIR): self = .directory
    case mode_t(S_IFIFO): self = .fifo
    case mode_t(S_IFREG): self = .regularFile
    case mode_t(S_IFSOCK): self = .socket
    case mode_t(S_IFLNK): self = .symbolicLink
    default: self = .unknown
    }
  }
}

struct BuildContextFileSnapshot: Equatable {
  let device: dev_t
  let inode: ino_t
  let kind: BuildContextFileKind
  let permissions: mode_t
  let owner: uid_t
  let group: gid_t
  let size: off_t
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    kind = BuildContextFileKind(mode: value.st_mode)
    permissions = value.st_mode & 0o7777
    owner = value.st_uid
    group = value.st_gid
    size = value.st_size
    modifiedSeconds = value.st_mtimespec.tv_sec
    modifiedNanoseconds = value.st_mtimespec.tv_nsec
    changedSeconds = value.st_ctimespec.tv_sec
    changedNanoseconds = value.st_ctimespec.tv_nsec
  }
}

struct BuildContextStagedEntry {
  let relativePath: String
  let url: URL
  let kind: BuildContextFileKind
  let snapshot: BuildContextFileSnapshot
}

struct BuildContextStagedEntryIdentity: Equatable {
  let relativePath: String
  let kind: BuildContextFileKind
  let snapshot: BuildContextFileSnapshot
}
