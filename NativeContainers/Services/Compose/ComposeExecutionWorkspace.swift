import CryptoKit
import Darwin
import Foundation

struct ComposeExecutionConfigurationLease: Equatable, Sendable {
  struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let sha256: String
  }

  struct DirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
  }

  let operationID: UUID
  let directoryURL: URL
  let configurationURL: URL
  let directoryIdentity: DirectoryIdentity
  let fileIdentity: FileIdentity
}

protocol ComposeExecutionWorkspaceManaging: Sendable {
  func prepare(
    operationID: UUID,
    canonicalConfiguration: Data,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease

  func remove(_ lease: ComposeExecutionConfigurationLease) throws
}

struct FileComposeExecutionWorkspace: ComposeExecutionWorkspaceManaging {
  static let maximumConfigurationBytes = 4 * 1_024 * 1_024

  private let rootURL: URL
  private let protectedDirectories: [URL]

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    if let rootURL {
      let standardized = rootURL.standardizedFileURL
      self.rootURL = standardized
      protectedDirectories = [standardized]
    } else {
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0]
      let appDirectory = applicationSupport.appending(
        path: "NativeContainers",
        directoryHint: .isDirectory
      )
      let composeDirectory = appDirectory.appending(
        path: "Compose",
        directoryHint: .isDirectory
      )
      let executionDirectory = composeDirectory.appending(
        path: "Execution",
        directoryHint: .isDirectory
      )
      self.rootURL = executionDirectory
      protectedDirectories = [
        applicationSupport,
        appDirectory,
        composeDirectory,
        executionDirectory,
      ]
    }
  }

  func prepare(
    operationID: UUID,
    canonicalConfiguration: Data,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease {
    guard
      !canonicalConfiguration.isEmpty,
      canonicalConfiguration.count <= Self.maximumConfigurationBytes,
      sha256(canonicalConfiguration) == expectedSHA256
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration bytes did not match the reviewed digest."
      )
    }

    try ensurePrivateDirectories()
    let operationDirectory = rootURL.appending(
      path: operationID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    guard
      Darwin.mkdir(operationDirectory.nativeContainersPOSIXPath, mode_t(0o700)) == 0
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        errno == EEXIST
          ? "An execution workspace already exists for this operation."
          : "The operation directory could not be created (errno \(errno))."
      )
    }

    let directoryIdentity = try validateDirectory(operationDirectory)
    let directoryDescriptor = Darwin.open(
      operationDirectory.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      try? removeEmptyDirectory(operationDirectory, identity: directoryIdentity)
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The operation directory could not be opened safely."
      )
    }
    defer { Darwin.close(directoryDescriptor) }

    var createdFileIdentity: ComposeExecutionConfigurationLease.FileIdentity?
    var completed = false
    defer {
      if !completed {
        if let createdFileIdentity {
          try? removeFile(
            named: "compose.json",
            expectedIdentity: createdFileIdentity,
            directoryDescriptor: directoryDescriptor
          )
        }
        try? removeEmptyDirectory(operationDirectory, identity: directoryIdentity)
      }
    }

    let configurationURL = operationDirectory.appending(
      path: "compose.json",
      directoryHint: .notDirectory
    )
    let descriptor = Darwin.openat(
      directoryDescriptor,
      "compose.json",
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration file could not be created (errno \(errno))."
      )
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen {
        Darwin.close(descriptor)
      }
    }

    do {
      try writeAll(canonicalConfiguration, descriptor: descriptor)
      guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The canonical configuration permissions could not be restricted."
        )
      }
      if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The canonical configuration could not be synchronized."
        )
      }

      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The canonical configuration identity could not be inspected."
        )
      }
      let fileIdentity = try validateRegularFile(
        metadata,
        expectedByteCount: canonicalConfiguration.count,
        expectedSHA256: expectedSHA256,
        descriptor: descriptor
      )
      createdFileIdentity = fileIdentity
      guard Darwin.close(descriptor) == 0 else {
        descriptorIsOpen = false
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The canonical configuration file could not be closed safely."
        )
      }
      descriptorIsOpen = false

      guard Darwin.fsync(directoryDescriptor) == 0 else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The operation directory could not be synchronized."
        )
      }

      completed = true
      return ComposeExecutionConfigurationLease(
        operationID: operationID,
        directoryURL: operationDirectory,
        configurationURL: configurationURL,
        directoryIdentity: directoryIdentity,
        fileIdentity: fileIdentity
      )
    } catch {
      throw error
    }
  }

  func remove(_ lease: ComposeExecutionConfigurationLease) throws {
    guard try validateDirectory(lease.directoryURL) == lease.directoryIdentity else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution directory identity changed before cleanup."
      )
    }

    let directoryDescriptor = Darwin.open(
      lease.directoryURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution directory could not be opened before cleanup."
      )
    }
    defer { Darwin.close(directoryDescriptor) }

    var directoryMetadata = stat()
    guard
      Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
      directoryIdentity(directoryMetadata) == lease.directoryIdentity
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution directory identity changed while cleanup began."
      )
    }

    try removeFile(
      named: "compose.json",
      expectedIdentity: lease.fileIdentity,
      directoryDescriptor: directoryDescriptor
    )
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The operation directory cleanup could not be synchronized."
      )
    }
    try removeEmptyDirectory(lease.directoryURL, identity: lease.directoryIdentity)
  }

  private func ensurePrivateDirectories() throws {
    for directory in protectedDirectories {
      var metadata = stat()
      if Darwin.lstat(directory.nativeContainersPOSIXPath, &metadata) == 0 {
        _ = try validateDirectory(directory, metadata: metadata)
        continue
      }
      guard errno == ENOENT else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "A protected execution directory could not be inspected."
        )
      }
      guard Darwin.mkdir(directory.nativeContainersPOSIXPath, mode_t(0o700)) == 0 else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "A protected execution directory could not be created."
        )
      }
      _ = try validateDirectory(directory)
    }
  }

  private func validateDirectory(
    _ url: URL,
    metadata providedMetadata: stat? = nil
  ) throws -> ComposeExecutionConfigurationLease.DirectoryIdentity {
    var metadata = providedMetadata ?? stat()
    if providedMetadata == nil {
      guard Darwin.lstat(url.nativeContainersPOSIXPath, &metadata) == 0 else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "A protected execution directory is missing."
        )
      }
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "Every execution directory must be owner-controlled and not writable by other users."
      )
    }
    return ComposeExecutionConfigurationLease.DirectoryIdentity(
      device: UInt64(metadata.st_dev), inode: metadata.st_ino
    )
  }

  private func validateRegularFile(
    _ metadata: stat,
    expectedByteCount: Int,
    expectedSHA256: String,
    descriptor: Int32
  ) throws -> ComposeExecutionConfigurationLease.FileIdentity {
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_size == Int64(expectedByteCount)
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration is not a private single-link regular file."
      )
    }
    let data = try readAll(
      descriptor: descriptor,
      expectedByteCount: expectedByteCount
    )
    guard sha256(data) == expectedSHA256 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration changed while it was staged."
      )
    }
    return ComposeExecutionConfigurationLease.FileIdentity(
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino,
      byteCount: metadata.st_size,
      sha256: expectedSHA256
    )
  }

  private func removeFile(
    named name: String,
    expectedIdentity: ComposeExecutionConfigurationLease.FileIdentity,
    directoryDescriptor: Int32
  ) throws {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { return }
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration could not be opened before cleanup."
      )
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration identity could not be inspected before cleanup."
      )
    }
    let current = try validateRegularFile(
      metadata,
      expectedByteCount: Int(expectedIdentity.byteCount),
      expectedSHA256: expectedIdentity.sha256,
      descriptor: descriptor
    )
    guard current == expectedIdentity else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration identity changed before cleanup."
      )
    }
    guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration could not be removed."
      )
    }
  }

  private func removeEmptyDirectory(
    _ directoryURL: URL,
    identity: ComposeExecutionConfigurationLease.DirectoryIdentity
  ) throws {
    guard try validateDirectory(directoryURL) == identity else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution directory identity changed before removal."
      )
    }
    guard Darwin.rmdir(directoryURL.nativeContainersPOSIXPath) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution directory could not be removed."
      )
    }
  }

  private func directoryIdentity(
    _ metadata: stat
  ) -> ComposeExecutionConfigurationLease.DirectoryIdentity {
    ComposeExecutionConfigurationLease.DirectoryIdentity(
      device: UInt64(metadata.st_dev), inode: metadata.st_ino
    )
  }

  private func readAll(descriptor: Int32, expectedByteCount: Int) throws -> Data {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration could not be rewound for verification."
      )
    }
    var data = Data(count: expectedByteCount)
    let count = try data.withUnsafeMutableBytes { bytes -> Int in
      var offset = 0
      while offset < bytes.count {
        let result = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
          throw ComposeProjectLifecycleError.workspaceUnsafe(
            "The canonical configuration could not be read back completely."
          )
        }
        offset += result
      }
      return offset
    }
    guard count == expectedByteCount else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration read-back was incomplete."
      )
    }
    return data
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR {
          continue
        }
        guard count > 0 else {
          throw ComposeProjectLifecycleError.workspaceUnsafe(
            "The canonical configuration could not be written."
          )
        }
        offset += count
      }
    }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
