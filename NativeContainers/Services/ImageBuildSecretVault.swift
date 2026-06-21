import Darwin
import Foundation

struct ImageBuildSecretSelection: Equatable, Sendable, Identifiable {
  let id: String
  let sourceURL: URL
}

struct ImageBuildSecretReview: Equatable, Sendable, Identifiable {
  let id: String
  let displayPath: String
  let byteCount: Int64
}

struct ImageBuildSecretPreparation: Equatable, Sendable {
  let reviews: [ImageBuildSecretReview]
  let excludedContextFiles: Set<BuildContextExcludedFileIdentity>
}

enum ImageBuildSecretError: LocalizedError, Equatable, Sendable {
  case tooManySecrets(maximum: Int)
  case invalidIdentifier(String)
  case duplicateIdentifier(String)
  case sourceInsideBuildContext(String)
  case sourceUnavailable(String)
  case sourceNotPrivate(String)
  case sourceTooLarge(id: String, byteCount: Int64, maximum: Int)
  case totalTooLarge(byteCount: Int64, maximum: Int)
  case sourceChanged(String)
  case reviewAlreadyExists
  case reviewUnavailable
  case reviewMismatch

  var errorDescription: String? {
    switch self {
    case .tooManySecrets(let maximum):
      "Choose no more than \(maximum) build secrets."
    case .invalidIdentifier(let id):
      "“\(id)” is not a valid secret ID. Use 1–128 ASCII letters, numbers, periods, underscores, or hyphens, beginning with a letter or number."
    case .duplicateIdentifier(let id):
      "Build secret ID “\(id)” is used more than once."
    case .sourceInsideBuildContext(let id):
      "Secret “\(id)” must be stored outside the build context so COPY cannot include it."
    case .sourceUnavailable(let id):
      "The reviewed source for secret “\(id)” is no longer available."
    case .sourceNotPrivate(let id):
      "Secret “\(id)” must be a private regular file owned only by the current user, without links."
    case .sourceTooLarge(let id, let byteCount, let maximum):
      "Secret “\(id)” is \(byteCount) bytes; the per-secret limit is \(maximum) bytes."
    case .totalTooLarge(let byteCount, let maximum):
      "The selected secrets total \(byteCount) bytes; the build limit is \(maximum) bytes."
    case .sourceChanged(let id):
      "Secret “\(id)” changed after review. Review the build again."
    case .reviewAlreadyExists:
      "A secret review already exists for this build."
    case .reviewUnavailable:
      "The reviewed secret sources are no longer available. Review the build again."
    case .reviewMismatch:
      "The reviewed secret list no longer matches this build."
    }
  }
}

enum ImageBuildSecretPolicy {
  static let maximumCount = ContainerBuildSecretLimits.maximumCount
  static let maximumSecretBytes = ContainerBuildSecretLimits.maximumSecretBytes
  static let maximumTotalBytes = ContainerBuildSecretLimits.maximumTotalBytes

  static func validate(
    _ selections: [ImageBuildSecretSelection],
    contextDirectory: URL
  ) throws -> [ImageBuildSecretSelection] {
    guard selections.count <= maximumCount else {
      throw ImageBuildSecretError.tooManySecrets(maximum: maximumCount)
    }

    var identifiers = Set<String>()
    for selection in selections {
      do {
        try ContainerBuildSecretIDPolicy.validate(selection.id)
      } catch {
        throw ImageBuildSecretError.invalidIdentifier(selection.id)
      }
      guard identifiers.insert(selection.id).inserted else {
        throw ImageBuildSecretError.duplicateIdentifier(selection.id)
      }
    }

    let context = contextDirectory.standardizedFileURL.resolvingSymlinksInPath()
    for selection in selections {
      guard selection.sourceURL.isFileURL else {
        throw ImageBuildSecretError.sourceUnavailable(selection.id)
      }
      let source = selection.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
      guard source != context, !ContainerBuildPathBoundary.contains(source, within: context) else {
        throw ImageBuildSecretError.sourceInsideBuildContext(selection.id)
      }
    }
    return selections.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
  }
}

protocol ImageBuildSecretManaging: Sendable {
  func prepare(
    reviewID: UUID,
    selections: [ImageBuildSecretSelection],
    contextDirectory: URL
  ) async throws -> ImageBuildSecretPreparation
  func revalidate(reviewID: UUID) async throws
  func consume(
    reviewID: UUID,
    reviewedSecrets: [ImageBuildSecretReview]
  ) async throws -> ContainerBuildSecretSourcePayload
  func discard(reviewID: UUID) async
}

actor ImageBuildSecretVault: ImageBuildSecretManaging {
  private var reviews: [UUID: [BuildSecretSourceLease]] = [:]

  func prepare(
    reviewID: UUID,
    selections: [ImageBuildSecretSelection],
    contextDirectory: URL
  ) async throws -> ImageBuildSecretPreparation {
    guard reviews[reviewID] == nil else {
      throw ImageBuildSecretError.reviewAlreadyExists
    }
    let canonical = try ImageBuildSecretPolicy.validate(
      selections,
      contextDirectory: contextDirectory
    )
    var leases: [BuildSecretSourceLease] = []
    leases.reserveCapacity(canonical.count)

    var totalBytes: Int64 = 0
    for selection in canonical {
      try Task.checkCancellation()
      let lease = try BuildSecretSourceLease.open(selection)
      totalBytes += lease.identity.size
      guard totalBytes <= Int64(ImageBuildSecretPolicy.maximumTotalBytes) else {
        throw ImageBuildSecretError.totalTooLarge(
          byteCount: totalBytes,
          maximum: ImageBuildSecretPolicy.maximumTotalBytes
        )
      }
      leases.append(lease)
    }

    reviews[reviewID] = leases
    return ImageBuildSecretPreparation(
      reviews: leases.map(\.review),
      excludedContextFiles: Set(leases.map(\.excludedContextFile))
    )
  }

  func revalidate(reviewID: UUID) async throws {
    guard let leases = reviews[reviewID] else {
      throw ImageBuildSecretError.reviewUnavailable
    }
    for lease in leases {
      try Task.checkCancellation()
      try lease.revalidate()
    }
  }

  func consume(
    reviewID: UUID,
    reviewedSecrets: [ImageBuildSecretReview]
  ) async throws -> ContainerBuildSecretSourcePayload {
    guard let leases = reviews.removeValue(forKey: reviewID) else {
      throw ImageBuildSecretError.reviewUnavailable
    }
    guard leases.map(\.review) == reviewedSecrets else {
      throw ImageBuildSecretError.reviewMismatch
    }
    for lease in leases {
      try Task.checkCancellation()
      try lease.revalidate()
    }
    do {
      return try ContainerBuildSecretSourcePayload(
        entries: leases.map { $0 as any ContainerBuildSecretStreamingEntry }
      )
    } catch {
      throw ImageBuildSecretError.reviewMismatch
    }
  }

  func discard(reviewID: UUID) {
    reviews.removeValue(forKey: reviewID)
  }
}

private struct BuildSecretFileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let fileType: UInt16
  let permissions: UInt16
  let owner: UInt32
  let linkCount: UInt64
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64

  init(metadata: stat) {
    device = UInt64(metadata.st_dev)
    inode = UInt64(metadata.st_ino)
    fileType = UInt16(metadata.st_mode & mode_t(S_IFMT))
    permissions = UInt16(metadata.st_mode & 0o7777)
    owner = UInt32(metadata.st_uid)
    linkCount = UInt64(metadata.st_nlink)
    size = Int64(metadata.st_size)
    modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
    modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
    changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
  }
}

private final class BuildSecretSourceLease:
  ContainerBuildSecretStreamingEntry, @unchecked Sendable
{
  let id: String
  let sourceURL: URL
  let descriptor: Int32
  let identity: BuildSecretFileIdentity
  let securityScopeWasStarted: Bool

  var byteCount: Int { Int(identity.size) }

  var review: ImageBuildSecretReview {
    ImageBuildSecretReview(
      id: id,
      displayPath: (sourceURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
      byteCount: identity.size
    )
  }

  var excludedContextFile: BuildContextExcludedFileIdentity {
    BuildContextExcludedFileIdentity(device: identity.device, inode: identity.inode)
  }

  private init(
    id: String,
    sourceURL: URL,
    descriptor: Int32,
    identity: BuildSecretFileIdentity,
    securityScopeWasStarted: Bool
  ) {
    self.id = id
    self.sourceURL = sourceURL
    self.descriptor = descriptor
    self.identity = identity
    self.securityScopeWasStarted = securityScopeWasStarted
  }

  deinit {
    Darwin.close(descriptor)
    if securityScopeWasStarted {
      sourceURL.stopAccessingSecurityScopedResource()
    }
  }

  static func open(_ selection: ImageBuildSecretSelection) throws -> BuildSecretSourceLease {
    let sourceURL = selection.sourceURL.standardizedFileURL
    let startedScope = sourceURL.startAccessingSecurityScopedResource()
    let descriptor = Darwin.open(
      sourceURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      if startedScope { sourceURL.stopAccessingSecurityScopedResource() }
      throw ImageBuildSecretError.sourceUnavailable(selection.id)
    }

    do {
      let pathIdentity = try identityAtPath(sourceURL, id: selection.id)
      let descriptorIdentity = try identityForDescriptor(descriptor, id: selection.id)
      guard pathIdentity == descriptorIdentity else {
        throw ImageBuildSecretError.sourceChanged(selection.id)
      }
      try validatePrivateSource(descriptorIdentity, id: selection.id)
      return BuildSecretSourceLease(
        id: selection.id,
        sourceURL: sourceURL,
        descriptor: descriptor,
        identity: descriptorIdentity,
        securityScopeWasStarted: startedScope
      )
    } catch {
      Darwin.close(descriptor)
      if startedScope { sourceURL.stopAccessingSecurityScopedResource() }
      throw error
    }
  }

  func revalidate() throws {
    let pathIdentity = try Self.identityAtPath(sourceURL, id: id)
    let descriptorIdentity = try Self.identityForDescriptor(descriptor, id: id)
    guard pathIdentity == identity, descriptorIdentity == identity else {
      throw ImageBuildSecretError.sourceChanged(id)
    }
  }

  func writeBytes(to outputDescriptor: Int32) throws {
    try revalidate()
    let bufferSize = min(64 * 1_024, max(1, byteCount))
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    defer {
      buffer.withUnsafeMutableBytes { bytes in
        if let baseAddress = bytes.baseAddress {
          _ = memset_s(baseAddress, bytes.count, 0, bytes.count)
        }
      }
    }

    var offset = 0
    while offset < byteCount {
      try Task.checkCancellation()
      let requested = min(buffer.count, byteCount - offset)
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor,
          bytes.baseAddress,
          requested,
          off_t(offset)
        )
      }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw ImageBuildSecretError.sourceUnavailable(id)
      }
      guard readCount > 0 else {
        throw ImageBuildSecretError.sourceChanged(id)
      }
      try Self.writeAll(
        buffer,
        count: readCount,
        to: outputDescriptor
      )
      offset += readCount
    }
    try revalidate()
  }

  private static func writeAll(
    _ buffer: [UInt8],
    count: Int,
    to descriptor: Int32
  ) throws {
    var offset = 0
    try buffer.withUnsafeBytes { bytes in
      while offset < count {
        let written = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: errno)
        }
        guard written > 0 else {
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: EIO)
        }
        offset += written
      }
    }
  }

  private static func identityAtPath(
    _ url: URL,
    id: String
  ) throws -> BuildSecretFileIdentity {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 else {
      throw ImageBuildSecretError.sourceUnavailable(id)
    }
    return BuildSecretFileIdentity(metadata: metadata)
  }

  private static func identityForDescriptor(
    _ descriptor: Int32,
    id: String
  ) throws -> BuildSecretFileIdentity {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw ImageBuildSecretError.sourceUnavailable(id)
    }
    return BuildSecretFileIdentity(metadata: metadata)
  }

  private static func validatePrivateSource(
    _ identity: BuildSecretFileIdentity,
    id: String
  ) throws {
    guard
      identity.fileType == UInt16(S_IFREG),
      identity.size >= 0,
      identity.owner == UInt32(geteuid()),
      identity.linkCount == 1,
      identity.permissions & UInt16(S_IRWXG | S_IRWXO) == 0
    else {
      throw ImageBuildSecretError.sourceNotPrivate(id)
    }
    guard identity.size <= Int64(ImageBuildSecretPolicy.maximumSecretBytes) else {
      throw ImageBuildSecretError.sourceTooLarge(
        id: id,
        byteCount: identity.size,
        maximum: ImageBuildSecretPolicy.maximumSecretBytes
      )
    }
  }
}
