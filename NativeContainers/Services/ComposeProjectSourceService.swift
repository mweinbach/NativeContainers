import CryptoKit
import Darwin
import Foundation

protocol ComposeProjectSourceAccessing: Sendable {
  func acquire(directoryURL: URL) async throws -> ComposeProjectSourceLease
  func revalidate(_ lease: ComposeProjectSourceLease) async throws
  func release(_ lease: ComposeProjectSourceLease) async
}

actor FileComposeProjectSourceService: ComposeProjectSourceAccessing {
  private struct DirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let permissions: UInt16
  }

  private struct ActiveLease {
    let lease: ComposeProjectSourceLease
    let directoryDescriptor: Int32
    let fileDescriptor: Int32
    let directoryIdentity: DirectoryIdentity
    let securityScopedURL: URL
    let startedSecurityScope: Bool
  }

  private static let conventionalFileNames = [
    "compose.yaml",
    "compose.yml",
    "docker-compose.yaml",
    "docker-compose.yml",
  ]
  private static let maximumComposeFileBytes: Int64 = 1_048_576

  private var activeLeases: [UUID: ActiveLease] = [:]

  func acquire(directoryURL requestedURL: URL) throws -> ComposeProjectSourceLease {
    let securityScopedURL = requestedURL.standardizedFileURL
    let startedSecurityScope = securityScopedURL.startAccessingSecurityScopedResource()
    var directoryDescriptor: Int32 = -1
    var fileDescriptor: Int32 = -1

    do {
      directoryDescriptor = Darwin.open(
        securityScopedURL.nativeContainersPOSIXPath,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard directoryDescriptor >= 0 else {
        throw ComposeProjectLifecycleError.sourceDirectoryUnsafe(
          "The selected path could not be opened without following links."
        )
      }
      let directoryIdentity = try validateDirectory(descriptor: directoryDescriptor)
      let fileName = try selectComposeFile(in: directoryDescriptor)
      fileDescriptor = Darwin.openat(
        directoryDescriptor,
        fileName,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard fileDescriptor >= 0 else {
        throw ComposeProjectLifecycleError.composeFileUnsafe(
          "The selected Compose file could not be opened without following links."
        )
      }

      let fileIdentity = try readAndValidateFileIdentity(descriptor: fileDescriptor)
      let pathIdentity = try fileIdentityAtPath(
        directoryDescriptor: directoryDescriptor,
        fileName: fileName
      )
      guard pathIdentity == fileIdentity else {
        throw ComposeProjectLifecycleError.sourceChanged
      }

      let id = UUID()
      let composeFileURL = securityScopedURL.appending(
        path: fileName,
        directoryHint: .notDirectory
      )
      let lease = ComposeProjectSourceLease(
        id: id,
        directoryURL: securityScopedURL,
        composeFileURL: composeFileURL,
        summary: ComposeProjectSourceSummary(
          directoryName: securityScopedURL.lastPathComponent,
          fileName: fileName,
          fileIdentity: fileIdentity
        )
      )
      activeLeases[id] = ActiveLease(
        lease: lease,
        directoryDescriptor: directoryDescriptor,
        fileDescriptor: fileDescriptor,
        directoryIdentity: directoryIdentity,
        securityScopedURL: securityScopedURL,
        startedSecurityScope: startedSecurityScope
      )
      return lease
    } catch {
      if fileDescriptor >= 0 {
        Darwin.close(fileDescriptor)
      }
      if directoryDescriptor >= 0 {
        Darwin.close(directoryDescriptor)
      }
      if startedSecurityScope {
        securityScopedURL.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  func revalidate(_ lease: ComposeProjectSourceLease) throws {
    guard let active = activeLeases[lease.id], active.lease == lease else {
      throw ComposeProjectLifecycleError.sourceChanged
    }

    guard
      try validateDirectory(descriptor: active.directoryDescriptor)
        == active.directoryIdentity
    else {
      throw ComposeProjectLifecycleError.sourceChanged
    }

    let descriptorIdentity = try readAndValidateFileIdentity(
      descriptor: active.fileDescriptor
    )
    let pathIdentity = try fileIdentityAtPath(
      directoryDescriptor: active.directoryDescriptor,
      fileName: lease.summary.fileName
    )
    guard
      descriptorIdentity == lease.summary.fileIdentity,
      pathIdentity == lease.summary.fileIdentity
    else {
      throw ComposeProjectLifecycleError.sourceChanged
    }
  }

  func release(_ lease: ComposeProjectSourceLease) {
    guard let active = activeLeases.removeValue(forKey: lease.id) else { return }
    Darwin.close(active.fileDescriptor)
    Darwin.close(active.directoryDescriptor)
    if active.startedSecurityScope {
      active.securityScopedURL.stopAccessingSecurityScopedResource()
    }
  }

  private func selectComposeFile(in directoryDescriptor: Int32) throws -> String {
    var matches: [String] = []
    for fileName in Self.conventionalFileNames {
      var metadata = stat()
      if fstatat(
        directoryDescriptor,
        fileName,
        &metadata,
        AT_SYMLINK_NOFOLLOW
      ) == 0 {
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
          throw ComposeProjectLifecycleError.composeFileUnsafe(
            "\(fileName) is not a regular file."
          )
        }
        matches.append(fileName)
      } else if errno != ENOENT {
        throw ComposeProjectLifecycleError.composeFileUnsafe(
          "\(fileName) could not be inspected safely."
        )
      }
    }

    guard !matches.isEmpty else {
      throw ComposeProjectLifecycleError.composeFileMissing
    }
    guard matches.count == 1, let selected = matches.first else {
      throw ComposeProjectLifecycleError.composeFileAmbiguous(matches)
    }
    return selected
  }

  private func validateDirectory(descriptor: Int32) throws -> DirectoryIdentity {
    var metadata = stat()
    guard
      fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ComposeProjectLifecycleError.sourceDirectoryUnsafe(
        "It must be an owner-controlled directory that is not writable by other users."
      )
    }
    return DirectoryIdentity(
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino,
      owner: metadata.st_uid,
      permissions: UInt16(metadata.st_mode & 0o7777)
    )
  }

  private func fileIdentityAtPath(
    directoryDescriptor: Int32,
    fileName: String
  ) throws -> ComposeProjectSourceFileIdentity {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      fileName,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw ComposeProjectLifecycleError.sourceChanged
    }
    defer { Darwin.close(descriptor) }
    return try readAndValidateFileIdentity(descriptor: descriptor)
  }

  private func readAndValidateFileIdentity(
    descriptor: Int32
  ) throws -> ComposeProjectSourceFileIdentity {
    var before = stat()
    guard
      fstat(descriptor, &before) == 0,
      before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_uid == geteuid(),
      before.st_nlink == 1,
      before.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ComposeProjectLifecycleError.composeFileUnsafe(
        "It must be a private, owner-controlled regular file with one hard link."
      )
    }
    guard before.st_size <= Self.maximumComposeFileBytes else {
      throw ComposeProjectLifecycleError.composeFileTooLarge(before.st_size)
    }
    guard before.st_size >= 0 else {
      throw ComposeProjectLifecycleError.composeFileUnsafe(
        "The file reported an invalid size."
      )
    }

    let data = try readData(
      descriptor: descriptor,
      expectedByteCount: Int(before.st_size)
    )
    var after = stat()
    guard fstat(descriptor, &after) == 0, metadataMatches(before, after) else {
      throw ComposeProjectLifecycleError.sourceChanged
    }
    return identity(metadata: after, data: data)
  }

  private func readData(
    descriptor: Int32,
    expectedByteCount: Int
  ) throws -> Data {
    var data = Data()
    data.reserveCapacity(expectedByteCount)
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: 32 * 1_024)

    while offset < expectedByteCount {
      let requested = min(buffer.count, expectedByteCount - offset)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.pread(descriptor, bytes.baseAddress, requested, off_t(offset))
      }
      guard count >= 0 else {
        throw ComposeProjectLifecycleError.composeFileUnsafe(
          "The file could not be read safely."
        )
      }
      guard count > 0 else {
        throw ComposeProjectLifecycleError.sourceChanged
      }
      data.append(contentsOf: buffer.prefix(count))
      offset += count
    }
    return data
  }

  private func metadataMatches(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_uid == rhs.st_uid
      && lhs.st_mode == rhs.st_mode
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private func identity(
    metadata: stat,
    data: Data
  ) -> ComposeProjectSourceFileIdentity {
    ComposeProjectSourceFileIdentity(
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino,
      owner: metadata.st_uid,
      permissions: UInt16(metadata.st_mode & 0o7777),
      byteCount: metadata.st_size,
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }
}
