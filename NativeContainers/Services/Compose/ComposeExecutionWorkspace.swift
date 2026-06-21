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
    projectName: String,
    canonicalConfiguration: Data,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease

  func release(_ lease: ComposeExecutionConfigurationLease) throws
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
      let projectsDirectory = composeDirectory.appending(
        path: "Projects",
        directoryHint: .isDirectory
      )
      self.rootURL = projectsDirectory
      protectedDirectories = [
        applicationSupport,
        appDirectory,
        composeDirectory,
        projectsDirectory,
      ]
    }
  }

  func prepare(
    operationID: UUID,
    projectName: String,
    canonicalConfiguration: Data,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease {
    guard
      isValidComposeProjectName(projectName),
      isLowercaseSHA256(expectedSHA256),
      !canonicalConfiguration.isEmpty,
      canonicalConfiguration.count <= Self.maximumConfigurationBytes,
      sha256(canonicalConfiguration) == expectedSHA256
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The execution project or canonical configuration did not match its reviewed identity."
      )
    }

    try ensurePrivateDirectories()
    _ = try validateDirectory(rootURL, requiresOwnerOnlyAccess: true)
    let projectDirectory = rootURL.appending(
      path: projectName,
      directoryHint: .isDirectory
    )
    var createdProjectDirectory = false
    if Darwin.mkdir(projectDirectory.nativeContainersPOSIXPath, mode_t(0o700)) == 0 {
      createdProjectDirectory = true
    } else if errno != EEXIST {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The stable project directory could not be created (errno \(errno))."
      )
    }

    let directoryIdentity: ComposeExecutionConfigurationLease.DirectoryIdentity
    do {
      directoryIdentity = try validateDirectory(
        projectDirectory,
        requiresOwnerOnlyAccess: true
      )
    } catch {
      if createdProjectDirectory {
        _ = Darwin.rmdir(projectDirectory.nativeContainersPOSIXPath)
      }
      throw error
    }

    let directoryDescriptor = Darwin.open(
      projectDirectory.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      if createdProjectDirectory {
        _ = Darwin.rmdir(projectDirectory.nativeContainersPOSIXPath)
      }
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The stable project directory could not be opened safely."
      )
    }
    defer { Darwin.close(directoryDescriptor) }

    let fileName = "compose-\(expectedSHA256).json"
    let fileIdentity = try openOrCreateConfiguration(
      named: fileName,
      data: canonicalConfiguration,
      expectedSHA256: expectedSHA256,
      directoryDescriptor: directoryDescriptor
    )
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The stable project directory could not be synchronized."
      )
    }

    return ComposeExecutionConfigurationLease(
      operationID: operationID,
      directoryURL: projectDirectory,
      configurationURL: projectDirectory.appending(
        path: fileName,
        directoryHint: .notDirectory
      ),
      directoryIdentity: directoryIdentity,
      fileIdentity: fileIdentity
    )
  }

  func release(_ lease: ComposeExecutionConfigurationLease) throws {
    guard
      try validateDirectory(
        lease.directoryURL,
        requiresOwnerOnlyAccess: true
      ) == lease.directoryIdentity
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The stable project directory identity changed during execution."
      )
    }

    let directoryDescriptor = Darwin.open(
      lease.directoryURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The stable project directory could not be reopened safely."
      )
    }
    defer { Darwin.close(directoryDescriptor) }

    let descriptor = Darwin.openat(
      directoryDescriptor,
      lease.configurationURL.lastPathComponent,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The immutable execution configuration is missing."
      )
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The immutable execution configuration could not be inspected."
      )
    }
    let current = try validateRegularFile(
      metadata,
      expectedByteCount: Int(lease.fileIdentity.byteCount),
      expectedSHA256: lease.fileIdentity.sha256,
      descriptor: descriptor
    )
    guard current == lease.fileIdentity else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The immutable execution configuration identity changed during execution."
      )
    }
  }

  private func openOrCreateConfiguration(
    named fileName: String,
    data: Data,
    expectedSHA256: String,
    directoryDescriptor: Int32
  ) throws -> ComposeExecutionConfigurationLease.FileIdentity {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      fileName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    if descriptor < 0 {
      guard errno == EEXIST else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The immutable execution configuration could not be created (errno \(errno))."
        )
      }
      return try openExistingConfiguration(
        named: fileName,
        data: data,
        expectedSHA256: expectedSHA256,
        directoryDescriptor: directoryDescriptor
      )
    }
    defer { Darwin.close(descriptor) }

    do {
      try writeAll(data, descriptor: descriptor)
      guard
        Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
        Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 || Darwin.fsync(descriptor) == 0
      else {
        throw ComposeProjectLifecycleError.workspaceUnsafe(
          "The immutable execution configuration could not be secured and synchronized."
        )
      }
      return try fileIdentity(
        descriptor: descriptor,
        expectedByteCount: data.count,
        expectedSHA256: expectedSHA256
      )
    } catch {
      _ = Darwin.unlinkat(directoryDescriptor, fileName, 0)
      throw error
    }
  }

  private func openExistingConfiguration(
    named fileName: String,
    data: Data,
    expectedSHA256: String,
    directoryDescriptor: Int32
  ) throws -> ComposeExecutionConfigurationLease.FileIdentity {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      fileName,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The existing immutable execution configuration could not be opened safely."
      )
    }
    defer { Darwin.close(descriptor) }
    return try fileIdentity(
      descriptor: descriptor,
      expectedByteCount: data.count,
      expectedSHA256: expectedSHA256
    )
  }

  private func fileIdentity(
    descriptor: Int32,
    expectedByteCount: Int,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease.FileIdentity {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The immutable execution configuration identity could not be inspected."
      )
    }
    return try validateRegularFile(
      metadata,
      expectedByteCount: expectedByteCount,
      expectedSHA256: expectedSHA256,
      descriptor: descriptor
    )
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
    metadata providedMetadata: stat? = nil,
    requiresOwnerOnlyAccess: Bool = false
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
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      !requiresOwnerOnlyAccess || metadata.st_mode & mode_t(0o077) == 0
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "Every execution directory must be private and owner-controlled."
      )
    }
    return ComposeExecutionConfigurationLease.DirectoryIdentity(
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino
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
      metadata.st_mode & mode_t(0o077) == 0,
      metadata.st_size == Int64(expectedByteCount)
    else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration is not a private single-link regular file."
      )
    }
    let data = try readAll(descriptor: descriptor, expectedByteCount: expectedByteCount)
    guard sha256(data) == expectedSHA256 else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The canonical configuration changed after it was reviewed."
      )
    }
    return ComposeExecutionConfigurationLease.FileIdentity(
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino,
      byteCount: metadata.st_size,
      sha256: expectedSHA256
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
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw ComposeProjectLifecycleError.workspaceUnsafe(
            "The canonical configuration could not be written."
          )
        }
        offset += count
      }
    }
  }

  private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
