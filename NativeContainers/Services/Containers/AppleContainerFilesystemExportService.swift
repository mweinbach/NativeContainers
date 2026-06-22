import ContainerAPIClient
import ContainerResource
import CryptoKit
import Darwin
import Foundation

protocol ContainerFilesystemExportTransport: Sendable {
  func export(id: String, archive: URL) async throws
}

struct AppleContainerFilesystemExportTransport: ContainerFilesystemExportTransport {
  private let client: ContainerClient

  init(client: ContainerClient = ContainerClient()) {
    self.client = client
  }

  func export(id: String, archive: URL) async throws {
    try await client.export(id: id, archive: archive)
  }
}

actor AppleContainerFilesystemExportService: ContainerFilesystemExporting {
  private struct ParentIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let permissions: UInt16
    let owner: UInt32
  }

  private final class DestinationLease {
    let parentURL: URL
    let childName: String
    let descriptor: Int32
    let identity: ParentIdentity
    let securityScopedURL: URL
    let startedSecurityScope: Bool

    init(
      parentURL: URL,
      childName: String,
      descriptor: Int32,
      identity: ParentIdentity,
      securityScopedURL: URL,
      startedSecurityScope: Bool
    ) {
      self.parentURL = parentURL
      self.childName = childName
      self.descriptor = descriptor
      self.identity = identity
      self.securityScopedURL = securityScopedURL
      self.startedSecurityScope = startedSecurityScope
    }

    deinit {
      Darwin.close(descriptor)
      if startedSecurityScope {
        securityScopedURL.stopAccessingSecurityScopedResource()
      }
    }
  }

  private struct StagingOperation {
    let directoryName: String
    let directoryURL: URL
    let archiveURL: URL
    let lockLease: AdvisoryFileLockLease
  }

  private static let stagingDirectoryPrefix = ".nativecontainers-export-"
  private static let stagingArchiveName = "rootfs.tar"
  private static let stagingLockName = ".lock"

  private let transport: any ContainerFilesystemExportTransport
  private let snapshotReader: any ContainerSnapshotReading
  private let stagingRootDirectory: URL

  init(
    containerClient: ContainerClient = ContainerClient(),
    snapshotReader: (any ContainerSnapshotReading)? = nil,
    stagingRootDirectory: URL = AppleContainerFilesystemExportService.defaultStagingRootDirectory()
  ) {
    transport = AppleContainerFilesystemExportTransport(client: containerClient)
    self.snapshotReader =
      snapshotReader ?? AppleContainerSnapshotReader(client: containerClient)
    self.stagingRootDirectory = stagingRootDirectory.standardizedFileURL
  }

  init(
    transport: any ContainerFilesystemExportTransport,
    snapshotReader: any ContainerSnapshotReading,
    stagingRootDirectory: URL
  ) {
    self.transport = transport
    self.snapshotReader = snapshotReader
    self.stagingRootDirectory = stagingRootDirectory.standardizedFileURL
  }

  static func defaultStagingRootDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Container Export Staging", directoryHint: .isDirectory)
  }

  func exportFilesystem(
    _ request: ContainerFilesystemExportRequest
  ) async throws -> ContainerFilesystemExportReceipt {
    try Task.checkCancellation()
    try await validateTarget(request.target)
    let destinationLease = try prepareDestination(request.destinationURL)
    let operation = try prepareStagingOperation()
    defer { finishStagingOperation(operation) }

    let transport = transport
    let target = request.target
    let archiveURL = operation.archiveURL
    let exportTask = Task.detached {
      try await transport.export(id: target.id, archive: archiveURL)
    }

    do {
      try await exportTask.value
    } catch is CancellationError {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw ContainerFilesystemExportError.exportFailed(
        "The Apple export operation was cancelled."
      )
    } catch {
      throw ContainerFilesystemExportError.exportFailed(error.localizedDescription)
    }

    // Once Apple accepts the XPC export, let it settle in private staging
    // before honoring caller cancellation so the server never writes into
    // a directory that this process has already removed.
    try Task.checkCancellation()
    try await validateTarget(request.target)
    try Task.checkCancellation()

    return try publish(
      operation: operation,
      destination: destinationLease,
      target: request.target
    )
  }

  private func validateTarget(_ target: ContainerTerminalTargetIdentity) async throws {
    let snapshot: ContainerSnapshot
    do {
      snapshot = try await snapshotReader.get(id: target.id)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ContainerFilesystemExportError.containerUnavailable(target.id)
    }

    let record = AppleRuntimeInventoryService.containerRecord(from: snapshot)
    guard target.matches(record) else {
      throw ContainerFilesystemExportError.containerIdentityChanged(target.id)
    }
    guard record.state == .stopped else {
      throw ContainerFilesystemExportError.containerMustBeStopped(target.id)
    }
  }

  private func prepareDestination(_ requestedURL: URL) throws -> DestinationLease {
    let childName = requestedURL.lastPathComponent
    try validateChildName(childName)

    let securityScopedParent = requestedURL.deletingLastPathComponent()
    let startedSecurityScope = securityScopedParent.startAccessingSecurityScopedResource()
    do {
      let parentURL = securityScopedParent.standardizedFileURL.resolvingSymlinksInPath()
      let descriptor = Darwin.open(
        parentURL.path(percentEncoded: false),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw ContainerFilesystemExportError.unsafeDestinationParent(
          parentURL.path(percentEncoded: false)
        )
      }

      do {
        let identity = try validateParentDescriptor(descriptor, url: parentURL)
        let fullPath = parentURL.appending(path: childName).path(percentEncoded: false)
        guard
          try destinationIsAbsent(
            parentDescriptor: descriptor,
            childName: childName,
            fullPath: fullPath
          )
        else {
          throw ContainerFilesystemExportError.destinationMustBeNew(fullPath)
        }
        return DestinationLease(
          parentURL: parentURL,
          childName: childName,
          descriptor: descriptor,
          identity: identity,
          securityScopedURL: securityScopedParent,
          startedSecurityScope: startedSecurityScope
        )
      } catch {
        Darwin.close(descriptor)
        throw error
      }
    } catch {
      if startedSecurityScope {
        securityScopedParent.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  private func revalidate(_ lease: DestinationLease) throws {
    guard try validateParentDescriptor(lease.descriptor, url: lease.parentURL) == lease.identity
    else {
      throw ContainerFilesystemExportError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }

    let currentDescriptor = Darwin.open(
      lease.parentURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard currentDescriptor >= 0 else {
      throw ContainerFilesystemExportError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }
    defer { Darwin.close(currentDescriptor) }

    guard
      try validateParentDescriptor(currentDescriptor, url: lease.parentURL) == lease.identity
    else {
      throw ContainerFilesystemExportError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }

    let fullPath = lease.parentURL.appending(path: lease.childName).path(percentEncoded: false)
    guard
      try destinationIsAbsent(
        parentDescriptor: lease.descriptor,
        childName: lease.childName,
        fullPath: fullPath
      )
    else {
      throw ContainerFilesystemExportError.destinationChanged(fullPath)
    }
  }

  private func publish(
    operation: StagingOperation,
    destination: DestinationLease,
    target: ContainerTerminalTargetIdentity
  ) throws -> ContainerFilesystemExportReceipt {
    let expectedIdentity: SecureRegularFileIdentity
    do {
      expectedIdentity = try SecureRegularFileValidator.validate(
        rootDirectory: stagingRootDirectory,
        directoryName: operation.directoryName,
        fileName: Self.stagingArchiveName
      )
    } catch {
      throw ContainerFilesystemExportError.unsafeArchive(
        operation.archiveURL.path(percentEncoded: false)
      )
    }

    let temporaryName = ".nativecontainers-\(UUID().uuidString.lowercased()).partial"
    var temporaryExists = false
    var committed = false
    defer {
      if temporaryExists, !committed {
        temporaryName.withCString {
          _ = Darwin.unlinkat(destination.descriptor, $0, 0)
        }
      }
    }

    let outputDescriptor = temporaryName.withCString {
      Darwin.openat(
        destination.descriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard outputDescriptor >= 0 else {
      throw publicationPOSIXError("create temporary archive")
    }
    temporaryExists = true
    defer { Darwin.close(outputDescriptor) }

    let copied: (sha256: String, byteCount: Int64)
    do {
      copied = try SecureRegularFileValidator.withValidatedFileDescriptor(
        rootDirectory: stagingRootDirectory,
        directoryName: operation.directoryName,
        fileName: Self.stagingArchiveName
      ) { sourceDescriptor, currentIdentity in
        guard currentIdentity == expectedIdentity else {
          throw ContainerFilesystemExportError.unsafeArchive(
            operation.archiveURL.path(percentEncoded: false)
          )
        }
        return try copyAndHash(
          sourceDescriptor: sourceDescriptor,
          sourceIdentity: currentIdentity,
          destinationDescriptor: outputDescriptor,
          sourcePath: operation.archiveURL.path(percentEncoded: false)
        )
      }
    } catch let error as ContainerFilesystemExportError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ContainerFilesystemExportError.unsafeArchive(
        operation.archiveURL.path(percentEncoded: false)
      )
    }

    guard
      Darwin.fchmod(outputDescriptor, 0o600) == 0,
      Darwin.fsync(outputDescriptor) == 0
    else {
      throw publicationPOSIXError("flush temporary archive")
    }

    let receipt = ContainerFilesystemExportReceipt(
      target: target,
      destinationURL: destination.parentURL.appending(
        path: destination.childName,
        directoryHint: .notDirectory
      ),
      byteCount: copied.byteCount,
      sha256: copied.sha256
    )

    try Task.checkCancellation()
    try revalidate(destination)
    let renameResult = temporaryName.withCString { temporaryPointer in
      destination.childName.withCString { destinationPointer in
        Darwin.renameatx_np(
          destination.descriptor,
          temporaryPointer,
          destination.descriptor,
          destinationPointer,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      if [EEXIST, ENOENT, EISDIR, ENOTDIR].contains(errno) {
        throw ContainerFilesystemExportError.destinationChanged(
          receipt.destinationURL.path(percentEncoded: false)
        )
      }
      throw publicationPOSIXError("commit filesystem archive")
    }

    committed = true
    temporaryExists = false
    guard Darwin.fsync(destination.descriptor) == 0 else {
      throw ContainerFilesystemExportPartialCompletionError(
        receipt: receipt,
        failureMessage: publicationPOSIXError("flush archive parent").localizedDescription
      )
    }
    return receipt
  }

  private func copyAndHash(
    sourceDescriptor: Int32,
    sourceIdentity: SecureRegularFileIdentity,
    destinationDescriptor: Int32,
    sourcePath: String
  ) throws -> (sha256: String, byteCount: Int64) {
    var hasher = SHA256()
    var byteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)

    while true {
      try Task.checkCancellation()
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount >= 0 else {
        throw publicationPOSIXError("read staged archive")
      }
      if readCount == 0 { break }

      hasher.update(data: Data(buffer[0..<readCount]))
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
          throw publicationPOSIXError("write temporary archive")
        }
        written += writeCount
      }
      byteCount += Int64(readCount)
    }

    var finalMetadata = stat()
    guard
      Darwin.fstat(sourceDescriptor, &finalMetadata) == 0,
      makeIdentity(finalMetadata) == sourceIdentity,
      byteCount == sourceIdentity.size
    else {
      throw ContainerFilesystemExportError.unsafeArchive(sourcePath)
    }

    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount
    )
  }

  private func prepareStagingOperation() throws -> StagingOperation {
    let rootDescriptor = try prepareStagingRoot()
    defer { Darwin.close(rootDescriptor) }
    recoverAbandonedStagingOperations()

    let directoryName =
      Self.stagingDirectoryPrefix + UUID().uuidString.lowercased()
    let createResult = directoryName.withCString {
      Darwin.mkdirat(rootDescriptor, $0, 0o700)
    }
    guard createResult == 0 else {
      throw stagingPOSIXError("create operation directory")
    }

    let directoryURL = stagingRootDirectory.appending(
      path: directoryName,
      directoryHint: .isDirectory
    )
    do {
      let descriptor = directoryName.withCString {
        Darwin.openat(
          rootDescriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard descriptor >= 0 else {
        throw stagingPOSIXError("open operation directory")
      }
      defer { Darwin.close(descriptor) }

      var metadata = stat()
      guard
        Darwin.fstat(descriptor, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid(),
        Darwin.fchmod(descriptor, 0o700) == 0
      else {
        throw ContainerFilesystemExportError.stagingUnavailable(
          "The operation directory was not private."
        )
      }

      let lockURL = directoryURL.appending(
        path: Self.stagingLockName,
        directoryHint: .notDirectory
      )
      guard let lockLease = try AdvisoryFileLock.acquire(at: lockURL) else {
        throw ContainerFilesystemExportError.stagingUnavailable(
          "The operation lock was already held."
        )
      }
      return StagingOperation(
        directoryName: directoryName,
        directoryURL: directoryURL,
        archiveURL: directoryURL.appending(
          path: Self.stagingArchiveName,
          directoryHint: .notDirectory
        ),
        lockLease: lockLease
      )
    } catch {
      try? FileManager.default.removeItem(at: directoryURL)
      throw error
    }
  }

  private func finishStagingOperation(_ operation: StagingOperation) {
    operation.lockLease.release()
    try? FileManager.default.removeItem(at: operation.directoryURL)
  }

  private func prepareStagingRoot() throws -> Int32 {
    let parent = stagingRootDirectory.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw ContainerFilesystemExportError.stagingUnavailable(error.localizedDescription)
    }

    if Darwin.mkdir(stagingRootDirectory.path(percentEncoded: false), 0o700) != 0,
      errno != EEXIST
    {
      throw stagingPOSIXError("create staging root")
    }

    let descriptor = Darwin.open(
      stagingRootDirectory.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw stagingPOSIXError("open staging root")
    }

    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      Darwin.fchmod(descriptor, 0o700) == 0
    else {
      Darwin.close(descriptor)
      throw ContainerFilesystemExportError.stagingUnavailable(
        "The staging root is not an owner-controlled directory."
      )
    }
    return descriptor
  }

  private func recoverAbandonedStagingOperations() {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: stagingRootDirectory,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      return
    }

    for entry in entries where isRecognizedStagingDirectory(entry.lastPathComponent) {
      var metadata = stat()
      guard
        Darwin.lstat(entry.path(percentEncoded: false), &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid(),
        metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
      else {
        continue
      }

      let lockURL = entry.appending(path: Self.stagingLockName, directoryHint: .notDirectory)
      guard let lease = try? AdvisoryFileLock.acquire(at: lockURL) else {
        continue
      }
      lease.release()
      try? FileManager.default.removeItem(at: entry)
    }
  }

  private func isRecognizedStagingDirectory(_ name: String) -> Bool {
    guard name.hasPrefix(Self.stagingDirectoryPrefix) else { return false }
    let suffix = String(name.dropFirst(Self.stagingDirectoryPrefix.count))
    return UUID(uuidString: suffix) != nil
  }

  private func validateParentDescriptor(
    _ descriptor: Int32,
    url: URL
  ) throws -> ParentIdentity {
    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ContainerFilesystemExportError.unsafeDestinationParent(
        url.path(percentEncoded: false)
      )
    }
    return ParentIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      permissions: UInt16(metadata.st_mode & 0o7777),
      owner: UInt32(metadata.st_uid)
    )
  }

  private func destinationIsAbsent(
    parentDescriptor: Int32,
    childName: String,
    fullPath: String
  ) throws -> Bool {
    let descriptor = childName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
    }
    if descriptor < 0, errno == ENOENT {
      return true
    }
    guard descriptor >= 0 else {
      throw ContainerFilesystemExportError.destinationChanged(fullPath)
    }
    Darwin.close(descriptor)
    return false
  }

  private func validateChildName(_ name: String) throws {
    guard
      !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains("\0"),
      name.utf8.count <= Int(NAME_MAX)
    else {
      throw ContainerFilesystemExportError.invalidDestinationName(name)
    }
  }

  private func makeIdentity(_ metadata: stat) -> SecureRegularFileIdentity {
    SecureRegularFileIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      size: Int64(metadata.st_size),
      permissions: UInt16(metadata.st_mode & 0o7777),
      owner: UInt32(metadata.st_uid),
      linkCount: UInt64(metadata.st_nlink),
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
    )
  }

  private func stagingPOSIXError(_ operation: String) -> ContainerFilesystemExportError {
    .stagingUnavailable("\(operation) failed with POSIX error \(errno).")
  }

  private func publicationPOSIXError(
    _ operation: String
  ) -> ContainerFilesystemExportError {
    .publicationFailed("\(operation) failed with POSIX error \(errno).")
  }
}
