import CryptoKit
import Darwin
import Foundation

struct PrivateBuildArtifact: Equatable, Sendable {
  let url: URL
  let sha256: String
  let byteCount: Int64
}

enum PrivateBuildArtifactStoreError: Error, Equatable, Sendable {
  case destinationExists(String)
  case digestMismatch
  case byteCountMismatch
  case sourceChanged
  case ioFailure(operation: String, path: String, code: Int32)
}

struct PrivateBuildArtifactStore: Sendable {
  static let archiveName = "out.tar"

  let rootDirectory: URL

  init(rootDirectory: URL = Self.defaultRootDirectory()) {
    self.rootDirectory = rootDirectory.standardizedFileURL
  }

  static func defaultRootDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Build Artifacts", directoryHint: .isDirectory)
  }

  func persist(
    sourceRootDirectory: URL,
    sourceDirectoryName: String,
    buildID: UUID
  ) throws -> PrivateBuildArtifact {
    try ensurePrivateRoot()
    let buildName = buildID.uuidString.lowercased()
    let buildDirectory = rootDirectory.appending(
      path: buildName,
      directoryHint: .isDirectory
    )
    guard Darwin.mkdir(buildDirectory.path(percentEncoded: false), 0o700) == 0 else {
      if errno == EEXIST {
        throw PrivateBuildArtifactStoreError.destinationExists(
          buildDirectory.path(percentEncoded: false)
        )
      }
      throw posixError("create private artifact directory", buildDirectory)
    }

    do {
      let destination = buildDirectory.appending(
        path: Self.archiveName,
        directoryHint: .notDirectory
      )
      let digest = try SecureRegularFileValidator.withValidatedFileDescriptor(
        rootDirectory: sourceRootDirectory,
        directoryName: sourceDirectoryName,
        fileName: Self.archiveName
      ) { sourceDescriptor, sourceIdentity in
        try copyAndHash(
          sourceDescriptor: sourceDescriptor,
          sourceIdentity: sourceIdentity,
          destination: destination
        )
      }
      let artifact = PrivateBuildArtifact(
        url: destination,
        sha256: digest.sha256,
        byteCount: digest.byteCount
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
    _ artifact: PrivateBuildArtifact,
    buildID: UUID
  ) throws -> SecureRegularFileIdentity {
    let expected = artifactURL(buildID: buildID)
    guard artifact.url.standardizedFileURL == expected else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }

    return try SecureRegularFileValidator.withValidatedFileDescriptor(
      rootDirectory: rootDirectory,
      directoryName: buildID.uuidString.lowercased(),
      fileName: Self.archiveName
    ) { descriptor, identity in
      guard identity.size == artifact.byteCount else {
        throw PrivateBuildArtifactStoreError.byteCountMismatch
      }
      let digest = try hash(descriptor: descriptor)
      guard digest.byteCount == artifact.byteCount else {
        throw PrivateBuildArtifactStoreError.byteCountMismatch
      }
      guard digest.sha256 == artifact.sha256 else {
        throw PrivateBuildArtifactStoreError.digestMismatch
      }
      return identity
    }
  }

  func revalidate(
    _ artifact: PrivateBuildArtifact,
    buildID: UUID,
    expectedIdentity: SecureRegularFileIdentity
  ) throws {
    let expected = artifactURL(buildID: buildID)
    guard artifact.url.standardizedFileURL == expected else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }
    let current = try SecureRegularFileValidator.validate(
      rootDirectory: rootDirectory,
      directoryName: buildID.uuidString.lowercased(),
      fileName: Self.archiveName
    )
    guard current == expectedIdentity else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }
  }

  func remove(buildID: UUID) throws {
    let directory = rootDirectory.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    do {
      try FileManager.default.removeItem(at: directory)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError
    {
      return
    }
  }

  func artifactURL(buildID: UUID) -> URL {
    rootDirectory
      .appending(
        path: buildID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      .appending(path: Self.archiveName, directoryHint: .notDirectory)
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
      throw cocoaError("create artifact parent", parent, error)
    }

    if Darwin.mkdir(rootDirectory.path(percentEncoded: false), 0o700) != 0,
      errno != EEXIST
    {
      throw posixError("create artifact root", rootDirectory)
    }
    let descriptor = Darwin.open(
      rootDirectory.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw posixError("open artifact root", rootDirectory)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }
    guard Darwin.fchmod(descriptor, 0o700) == 0 else {
      throw posixError("secure artifact root", rootDirectory)
    }
  }

  private func copyAndHash(
    sourceDescriptor: Int32,
    sourceIdentity: SecureRegularFileIdentity,
    destination: URL
  ) throws -> (sha256: String, byteCount: Int64) {
    let destinationDescriptor = Darwin.open(
      destination.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw posixError("create private artifact", destination)
    }
    defer { Darwin.close(destinationDescriptor) }

    var hasher = SHA256()
    var byteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      if Task.isCancelled { throw CancellationError() }
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
      }
      if bytesRead < 0, errno == EINTR { continue }
      guard bytesRead >= 0 else {
        throw posixError("read builder artifact", destination)
      }
      if bytesRead == 0 { break }

      let chunk = Data(buffer[0..<bytesRead])
      hasher.update(data: chunk)
      byteCount += Int64(bytesRead)
      var written = 0
      while written < bytesRead {
        let count = chunk.withUnsafeBytes { bytes in
          Darwin.write(
            destinationDescriptor,
            bytes.baseAddress?.advanced(by: written),
            bytesRead - written
          )
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw posixError("write private artifact", destination)
        }
        written += count
      }
    }

    var finalSource = stat()
    guard Darwin.fstat(sourceDescriptor, &finalSource) == 0 else {
      throw posixError("revalidate builder artifact", destination)
    }
    guard
      UInt64(finalSource.st_dev) == sourceIdentity.device,
      UInt64(finalSource.st_ino) == sourceIdentity.inode,
      Int64(finalSource.st_size) == sourceIdentity.size,
      UInt16(finalSource.st_mode & 0o7777) == sourceIdentity.permissions,
      UInt32(finalSource.st_uid) == sourceIdentity.owner,
      UInt64(finalSource.st_nlink) == sourceIdentity.linkCount,
      Int64(finalSource.st_mtimespec.tv_sec) == sourceIdentity.modificationSeconds,
      Int64(finalSource.st_mtimespec.tv_nsec) == sourceIdentity.modificationNanoseconds,
      byteCount == sourceIdentity.size
    else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }
    guard Darwin.fchmod(destinationDescriptor, 0o400) == 0 else {
      throw posixError("seal private artifact", destination)
    }
    guard Darwin.fsync(destinationDescriptor) == 0 else {
      throw posixError("flush private artifact", destination)
    }
    return (hex(hasher.finalize()), byteCount)
  }

  private func hash(descriptor: Int32) throws -> (sha256: String, byteCount: Int64) {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw PrivateBuildArtifactStoreError.sourceChanged
    }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      if Task.isCancelled { throw CancellationError() }
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if bytesRead < 0, errno == EINTR { continue }
      guard bytesRead >= 0 else {
        throw PrivateBuildArtifactStoreError.sourceChanged
      }
      if bytesRead == 0 { break }
      hasher.update(data: Data(buffer[0..<bytesRead]))
      byteCount += Int64(bytesRead)
    }
    return (hex(hasher.finalize()), byteCount)
  }

  private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private func posixError(
    _ operation: String,
    _ url: URL
  ) -> PrivateBuildArtifactStoreError {
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
  ) -> PrivateBuildArtifactStoreError {
    let value = error as NSError
    return .ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: value.domain == NSPOSIXErrorDomain ? Int32(value.code) : EIO
    )
  }
}
