import CryptoKit
import Darwin
import Foundation

enum ImageBuildOutputError: LocalizedError, Equatable, Sendable {
  case destinationRequired
  case invalidDestinationName(String)
  case unsafeDestinationParent(String)
  case destinationMustBeNew(String)
  case destinationChanged(String)
  case outputReplacementRequiresConfirmation(String)
  case reviewUnavailable
  case artifactKindMismatch
  case publicationFailed(String)

  var errorDescription: String? {
    switch self {
    case .destinationRequired:
      "Choose an output destination before reviewing the build."
    case .invalidDestinationName(let name):
      "“\(name)” is not a safe output file or folder name."
    case .unsafeDestinationParent(let path):
      "The output parent at \(path) must be an owner-controlled directory that is not writable by other users."
    case .destinationMustBeNew(let path):
      "The local directory output at \(path) must not already exist."
    case .destinationChanged(let path):
      "The reviewed output destination at \(path) changed. Review the build again."
    case .outputReplacementRequiresConfirmation(let path):
      "Confirm replacing the reviewed archive at \(path)."
    case .reviewUnavailable:
      "The output destination review is no longer active. Review the build again."
    case .artifactKindMismatch:
      "The build worker returned a different output format than the reviewed build."
    case .publicationFailed(let message):
      "The output could not be committed: \(message)"
    }
  }
}

struct ImageBuildOutputPartialCompletionError: LocalizedError, Equatable, Sendable {
  let completion: ImageBuildCompletion
  let failureMessage: String

  var errorDescription: String? {
    "The reviewed output was committed, but finalization failed: \(failureMessage) The output was retained and will not be deleted."
  }
}

protocol ImageBuildOutputManaging: Sendable {
  func prepare(_ selection: ImageBuildOutputSelection) async throws -> ImageBuildOutputPlan
  func publish(
    _ result: ContainerBuildWorkerResult,
    artifactIdentity: ImageBuildArtifactIdentity,
    plan: ImageBuildOutputPlan,
    authorization: ImageBuildAuthorization
  ) async throws -> ImageBuildCompletion
  func discard(_ plan: ImageBuildOutputPlan) async
}

actor AppleImageBuildOutputService: ImageBuildOutputManaging {
  private struct ParentIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let permissions: UInt16
    let owner: UInt32
  }

  private struct ReviewLease {
    let plan: ImageBuildOutputPlan
    let parentURL: URL
    let childName: String
    let descriptor: Int32
    let parentIdentity: ParentIdentity
    let securityScopedURL: URL
    let startedSecurityScope: Bool
  }

  private let fileStore: PrivateBuildArtifactStore
  private let directoryStore: PrivateBuildDirectoryStore
  private var reviews: [UUID: ReviewLease] = [:]

  init(
    artifactRootDirectory: URL = PrivateBuildArtifactStore.defaultRootDirectory()
  ) {
    fileStore = PrivateBuildArtifactStore(rootDirectory: artifactRootDirectory)
    directoryStore = PrivateBuildDirectoryStore(rootDirectory: artifactRootDirectory)
  }

  func prepare(_ selection: ImageBuildOutputSelection) async throws -> ImageBuildOutputPlan {
    if selection.kind == .imageStore {
      guard selection.destinationURL == nil else {
        throw ImageBuildOutputError.destinationChanged(
          selection.destinationURL?.path(percentEncoded: false) ?? ""
        )
      }
      return ImageBuildOutputPlan(
        reviewID: nil,
        kind: .imageStore,
        destinationURL: nil,
        existingDestinationIdentity: nil
      )
    }

    guard let requestedDestination = selection.destinationURL else {
      throw ImageBuildOutputError.destinationRequired
    }
    let childName = requestedDestination.lastPathComponent
    try validateChildName(childName)

    let securityScopedParent = requestedDestination.deletingLastPathComponent()
    let startedSecurityScope = securityScopedParent.startAccessingSecurityScopedResource()
    do {
      let parentURL = securityScopedParent.standardizedFileURL.resolvingSymlinksInPath()
      let descriptor = Darwin.open(
        parentURL.path(percentEncoded: false),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw ImageBuildOutputError.unsafeDestinationParent(
          parentURL.path(percentEncoded: false)
        )
      }

      do {
        let parentIdentity = try validateParentDescriptor(descriptor, url: parentURL)
        let existingIdentity = try destinationIdentity(
          parentDescriptor: descriptor,
          childName: childName,
          fullPath: parentURL.appending(path: childName).path(percentEncoded: false)
        )
        if selection.kind == .rootFilesystemDirectory, existingIdentity != nil {
          throw ImageBuildOutputError.destinationMustBeNew(
            parentURL.appending(path: childName).path(percentEncoded: false)
          )
        }

        let reviewID = UUID()
        let destination = parentURL.appending(
          path: childName,
          directoryHint: selection.kind == .rootFilesystemDirectory
            ? .isDirectory
            : .notDirectory
        )
        let plan = ImageBuildOutputPlan(
          reviewID: reviewID,
          kind: selection.kind,
          destinationURL: destination,
          existingDestinationIdentity: existingIdentity
        )
        reviews[reviewID] = ReviewLease(
          plan: plan,
          parentURL: parentURL,
          childName: childName,
          descriptor: descriptor,
          parentIdentity: parentIdentity,
          securityScopedURL: securityScopedParent,
          startedSecurityScope: startedSecurityScope
        )
        return plan
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

  func publish(
    _ result: ContainerBuildWorkerResult,
    artifactIdentity: ImageBuildArtifactIdentity,
    plan: ImageBuildOutputPlan,
    authorization: ImageBuildAuthorization
  ) async throws -> ImageBuildCompletion {
    guard plan.kind != .imageStore else {
      throw ImageBuildOutputError.artifactKindMismatch
    }
    let lease = try activeLease(for: plan)
    try revalidate(lease)

    switch (plan.kind, result.artifact.kind, artifactIdentity) {
    case (.ociArchive, .ociArchive, .regularFile(let identity)):
      return try publishFile(
        result,
        expectedIdentity: identity,
        lease: lease,
        authorization: authorization
      ) { destination, sha256, byteCount in
        .ociArchive(destination: destination, sha256: sha256, byteCount: byteCount)
      }

    case (
      .rootFilesystemArchive,
      .rootFilesystemArchive,
      .regularFile(let identity)
    ):
      return try publishFile(
        result,
        expectedIdentity: identity,
        lease: lease,
        authorization: authorization
      ) { destination, sha256, byteCount in
        .rootFilesystemArchive(
          destination: destination,
          sha256: sha256,
          byteCount: byteCount
        )
      }

    case (
      .rootFilesystemDirectory,
      .rootFilesystemDirectory,
      .directory(let identity)
    ):
      return try publishDirectory(
        result,
        expectedIdentity: identity,
        lease: lease
      )

    default:
      throw ImageBuildOutputError.artifactKindMismatch
    }
  }

  func discard(_ plan: ImageBuildOutputPlan) async {
    guard let reviewID = plan.reviewID, let lease = reviews.removeValue(forKey: reviewID)
    else {
      return
    }
    Darwin.close(lease.descriptor)
    if lease.startedSecurityScope {
      lease.securityScopedURL.stopAccessingSecurityScopedResource()
    }
  }

  private func publishFile(
    _ result: ContainerBuildWorkerResult,
    expectedIdentity: SecureRegularFileIdentity,
    lease: ReviewLease,
    authorization: ImageBuildAuthorization,
    makeCompletion: (URL, String, Int64) -> ImageBuildCompletion
  ) throws -> ImageBuildCompletion {
    let artifact = result.artifact
    let privateArtifact = PrivateBuildArtifact(
      url: URL(filePath: artifact.path).standardizedFileURL,
      sha256: artifact.sha256,
      byteCount: artifact.byteCount
    )
    try fileStore.revalidate(
      privateArtifact,
      buildID: result.buildID,
      expectedIdentity: expectedIdentity
    )

    if lease.plan.replacesExistingDestination, !authorization.allowsOutputReplacement {
      throw ImageBuildOutputError.outputReplacementRequiresConfirmation(
        lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
      )
    }

    let temporaryName = ".nativecontainers-\(UUID().uuidString.lowercased()).partial"
    var temporaryExists = false
    var committed = false
    defer {
      if temporaryExists, !committed {
        temporaryName.withCString {
          _ = Darwin.unlinkat(lease.descriptor, $0, 0)
        }
      }
    }

    let destinationDescriptor = temporaryName.withCString {
      Darwin.openat(
        lease.descriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
    }
    guard destinationDescriptor >= 0 else {
      throw outputPOSIXError("create temporary output")
    }
    temporaryExists = true
    defer { Darwin.close(destinationDescriptor) }

    let copied = try SecureRegularFileValidator.withValidatedFileDescriptor(
      rootDirectory: fileStore.rootDirectory,
      directoryName: result.buildID.uuidString.lowercased(),
      fileName: PrivateBuildArtifactStore.archiveName
    ) { sourceDescriptor, currentIdentity in
      guard currentIdentity == expectedIdentity else {
        throw ImageBuildError.workerArtifactMismatch
      }
      return try copyAndHash(
        sourceDescriptor: sourceDescriptor,
        destinationDescriptor: destinationDescriptor
      )
    }
    guard copied.sha256 == artifact.sha256, copied.byteCount == artifact.byteCount else {
      throw ImageBuildError.workerArtifactMismatch
    }

    let permissions =
      lease.plan.existingDestinationIdentity.map {
        mode_t($0.permissions & 0o777)
      } ?? 0o600
    guard
      Darwin.fchmod(destinationDescriptor, permissions) == 0,
      Darwin.fsync(destinationDescriptor) == 0
    else {
      throw outputPOSIXError("flush temporary output")
    }

    let completion = makeCompletion(
      lease.plan.destinationURL!,
      copied.sha256,
      copied.byteCount
    )
    try Task.checkCancellation()
    try revalidate(lease)
    let renameResult: Int32
    if lease.plan.replacesExistingDestination {
      renameResult = swap(
        temporaryName,
        lease.childName,
        parentDescriptor: lease.descriptor
      )
    } else {
      renameResult = temporaryName.withCString { temporaryPointer in
        lease.childName.withCString { destinationPointer in
          Darwin.renameatx_np(
            lease.descriptor,
            temporaryPointer,
            lease.descriptor,
            destinationPointer,
            UInt32(RENAME_EXCL)
          )
        }
      }
    }
    guard renameResult == 0 else {
      if [EEXIST, ENOENT, EISDIR, ENOTDIR].contains(errno) {
        throw ImageBuildOutputError.destinationChanged(
          lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
        )
      }
      throw outputPOSIXError("commit reviewed output")
    }

    if let reviewedIdentity = lease.plan.existingDestinationIdentity {
      // RENAME_SWAP makes the old destination available under our unique
      // temporary name, so identity drift can still be detected atomically.
      committed = true
      let displacedIdentity = try? destinationIdentity(
        parentDescriptor: lease.descriptor,
        childName: temporaryName,
        fullPath: lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
      )
      guard displacedIdentity == reviewedIdentity else {
        let rollbackResult = swap(
          temporaryName,
          lease.childName,
          parentDescriptor: lease.descriptor
        )
        if rollbackResult == 0 {
          committed = false
          throw ImageBuildOutputError.destinationChanged(
            lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
          )
        }
        throw ImageBuildOutputPartialCompletionError(
          completion: completion,
          failureMessage:
            "The destination changed during the atomic commit and the prior entry could not be restored. A hidden recovery entry named \(temporaryName) remains beside the output."
        )
      }

      let unlinkResult = temporaryName.withCString {
        Darwin.unlinkat(lease.descriptor, $0, 0)
      }
      guard unlinkResult == 0 else {
        throw ImageBuildOutputPartialCompletionError(
          completion: completion,
          failureMessage:
            "The prior reviewed archive could not be removed. A hidden recovery entry named \(temporaryName) remains beside the output."
        )
      }
      temporaryExists = false
    } else {
      committed = true
      temporaryExists = false
    }
    guard Darwin.fsync(lease.descriptor) == 0 else {
      throw ImageBuildOutputPartialCompletionError(
        completion: completion,
        failureMessage: outputPOSIXError("flush output parent").localizedDescription
      )
    }
    return completion
  }

  private func publishDirectory(
    _ result: ContainerBuildWorkerResult,
    expectedIdentity: PrivateBuildDirectoryIdentity,
    lease: ReviewLease
  ) throws -> ImageBuildCompletion {
    guard !lease.plan.replacesExistingDestination else {
      throw ImageBuildOutputError.destinationMustBeNew(
        lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
      )
    }
    let artifact = result.artifact
    guard let entryCount = artifact.entryCount else {
      throw ImageBuildOutputError.artifactKindMismatch
    }
    let privateArtifact = PrivateBuildDirectoryArtifact(
      url: URL(filePath: artifact.path).standardizedFileURL,
      sha256: artifact.sha256,
      byteCount: artifact.byteCount,
      entryCount: entryCount
    )

    let temporaryName = ".nativecontainers-\(UUID().uuidString.lowercased()).partial"
    let temporaryURL = lease.parentURL.appending(
      path: temporaryName,
      directoryHint: .isDirectory
    )
    var temporaryExists = false
    var committed = false
    defer {
      if temporaryExists, !committed {
        try? FileManager.default.removeItem(at: temporaryURL)
      }
    }

    try directoryStore.copy(
      privateArtifact,
      buildID: result.buildID,
      expectedIdentity: expectedIdentity,
      to: temporaryURL
    )
    temporaryExists = true
    try Task.checkCancellation()
    try revalidate(lease)

    let renameResult = temporaryName.withCString { temporaryPointer in
      lease.childName.withCString { destinationPointer in
        Darwin.renameatx_np(
          lease.descriptor,
          temporaryPointer,
          lease.descriptor,
          destinationPointer,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      if errno == EEXIST {
        throw ImageBuildOutputError.destinationChanged(
          lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
        )
      }
      throw outputPOSIXError("commit reviewed directory output")
    }

    committed = true
    temporaryExists = false
    let completion = ImageBuildCompletion.rootFilesystemDirectory(
      destination: lease.plan.destinationURL!,
      byteCount: artifact.byteCount,
      entryCount: entryCount
    )
    guard Darwin.fsync(lease.descriptor) == 0 else {
      throw ImageBuildOutputPartialCompletionError(
        completion: completion,
        failureMessage: outputPOSIXError("flush output parent").localizedDescription
      )
    }
    return completion
  }

  private func activeLease(for plan: ImageBuildOutputPlan) throws -> ReviewLease {
    guard
      let reviewID = plan.reviewID,
      let lease = reviews[reviewID],
      lease.plan == plan
    else {
      throw ImageBuildOutputError.reviewUnavailable
    }
    return lease
  }

  private func revalidate(_ lease: ReviewLease) throws {
    guard
      try validateParentDescriptor(
        lease.descriptor,
        url: lease.parentURL
      ) == lease.parentIdentity
    else {
      throw ImageBuildOutputError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }

    let currentDescriptor = Darwin.open(
      lease.parentURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard currentDescriptor >= 0 else {
      throw ImageBuildOutputError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }
    defer { Darwin.close(currentDescriptor) }
    guard
      try validateParentDescriptor(
        currentDescriptor,
        url: lease.parentURL
      ) == lease.parentIdentity
    else {
      throw ImageBuildOutputError.destinationChanged(
        lease.parentURL.path(percentEncoded: false)
      )
    }

    let currentIdentity = try destinationIdentity(
      parentDescriptor: lease.descriptor,
      childName: lease.childName,
      fullPath: lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
    )
    guard currentIdentity == lease.plan.existingDestinationIdentity else {
      throw ImageBuildOutputError.destinationChanged(
        lease.plan.destinationURL?.path(percentEncoded: false) ?? lease.childName
      )
    }
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
      throw ImageBuildOutputError.unsafeDestinationParent(
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

  private func destinationIdentity(
    parentDescriptor: Int32,
    childName: String,
    fullPath: String
  ) throws -> SecureRegularFileIdentity? {
    let descriptor = childName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
    }
    if descriptor < 0, errno == ENOENT {
      return nil
    }
    guard descriptor >= 0 else {
      throw ImageBuildOutputError.destinationChanged(fullPath)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ImageBuildOutputError.destinationChanged(fullPath)
    }
    return SecureRegularFileIdentity(
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

  private func copyAndHash(
    sourceDescriptor: Int32,
    destinationDescriptor: Int32
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
        throw outputPOSIXError("read private output artifact")
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
          throw outputPOSIXError("write temporary output")
        }
        written += writeCount
      }
      byteCount += Int64(readCount)
    }
    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount
    )
  }

  private func swap(
    _ firstName: String,
    _ secondName: String,
    parentDescriptor: Int32
  ) -> Int32 {
    firstName.withCString { firstPointer in
      secondName.withCString { secondPointer in
        Darwin.renameatx_np(
          parentDescriptor,
          firstPointer,
          parentDescriptor,
          secondPointer,
          UInt32(RENAME_SWAP)
        )
      }
    }
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
      throw ImageBuildOutputError.invalidDestinationName(name)
    }
  }

  private func outputPOSIXError(_ operation: String) -> ImageBuildOutputError {
    ImageBuildOutputError.publicationFailed(
      "\(operation) failed with POSIX error \(errno)."
    )
  }
}
