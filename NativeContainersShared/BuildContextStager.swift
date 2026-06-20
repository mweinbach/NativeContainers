import CryptoKit
import Darwin
import Foundation

protocol BuildContextStaging: Sendable {
  func stage(
    sourceDirectory: URL,
    dockerfile: URL?,
    dockerignore: BuildContextDockerignoreSelection
  ) async throws -> StagedBuildContext
  func validate(_ context: StagedBuildContext) async throws
  func discard(_ context: StagedBuildContext) async throws
}

extension BuildContextStaging {
  func stage(sourceDirectory: URL) async throws -> StagedBuildContext {
    try await stage(
      sourceDirectory: sourceDirectory,
      dockerfile: nil,
      dockerignore: .conventional
    )
  }
}

enum BuildContextDockerignoreSelection: Equatable, Sendable {
  case none
  case conventional
  case dockerfileSibling
}

struct StagedBuildContext: Equatable, Sendable {
  let id: UUID
  let contextURL: URL
  let dockerfileURL: URL
  let dockerfileSHA256: String
  let dockerignoreURL: URL?
  let dockerignoreSHA256: String?
  let fingerprint: String
}

enum BuildContextUnsupportedEntryKind: String, Equatable, Sendable {
  case blockDevice
  case characterDevice
  case fifo
  case socket
  case symbolicLink
  case unknown
}

enum BuildContextStagingError: LocalizedError, Equatable, Sendable {
  case nonFileURL(URL)
  case sourceNotDirectory(URL)
  case stagingRootOverlapsSource
  case dockerfileOutsideContext(URL)
  case dockerfileMissing(String)
  case dockerfileNotRegular(String)
  case dockerfileTooLarge(Int)
  case customDockerfileSyntax
  case dockerignoreNotRegular(String)
  case unsupportedEntry(path: String, kind: BuildContextUnsupportedEntryKind)
  case sourceChanged(String)
  case invalidPath(String)
  case stagingDirectoryNotOwned
  case stagedEntryNotPrivate(String)
  case stagedFingerprintMismatch
  case stagedDockerfileHashMismatch
  case stagedDockerignoreHashMismatch
  case stagedDockerignoreMetadataMismatch
  case discardOutsideStagingRoot(URL)
  case ioFailure(operation: String, path: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .nonFileURL(let url):
      "Build context URLs must be local file URLs: \(url.absoluteString)"
    case .sourceNotDirectory(let url):
      "The selected build context is not a directory: \(url.path)"
    case .stagingRootOverlapsSource:
      "The private build staging root must not overlap the selected source directory."
    case .dockerfileOutsideContext(let url):
      "The selected Dockerfile must be inside the build context: \(url.path)"
    case .dockerfileMissing(let path):
      "The selected Dockerfile does not exist in the build context: \(path)"
    case .dockerfileNotRegular(let path):
      "The selected Dockerfile is not a regular file: \(path)"
    case .dockerfileTooLarge(let byteCount):
      "The Dockerfile is \(byteCount) bytes; Apple container requires it to be below 16 KiB."
    case .customDockerfileSyntax:
      "Custom Dockerfile syntax frontends are not allowed."
    case .dockerignoreNotRegular(let path):
      "The selected Docker ignore file is not a regular file: \(path)"
    case .unsupportedEntry(let path, let kind):
      "The build context contains an unsupported \(kind.rawValue) entry: \(path)"
    case .sourceChanged(let path):
      "The build context changed while it was being staged: \(path)"
    case .invalidPath(let path):
      "The build context contains an invalid path: \(path)"
    case .stagingDirectoryNotOwned:
      "The private build staging directory is not owned by the current user."
    case .stagedEntryNotPrivate(let path):
      "The staged build context entry is not private to the current user: \(path)"
    case .stagedFingerprintMismatch:
      "The staged build context changed after review."
    case .stagedDockerfileHashMismatch:
      "The staged Dockerfile changed after review."
    case .stagedDockerignoreHashMismatch:
      "The staged Docker ignore file changed after review."
    case .stagedDockerignoreMetadataMismatch:
      "The staged Docker ignore file metadata is inconsistent."
    case .discardOutsideStagingRoot(let url):
      "Refused to discard a directory outside the private build staging root: \(url.path)"
    case .ioFailure(let operation, let path, let code):
      "\(operation) failed for \(path) (errno \(code))."
    }
  }
}

/// Copies an untrusted local build context into an app-owned, immutable-by-convention boundary.
///
/// The returned hashes describe the staged copy, never the caller-owned source. Registry
/// credentials are deliberately outside this type's API and never enter the staged tree.
struct BuildContextStager: BuildContextStaging, Sendable {
  static let maximumDockerfileBytes = 16 * 1_024

  let stagingRoot: URL

  init(stagingRoot: URL? = nil) {
    self.stagingRoot = (stagingRoot ?? Self.defaultStagingRoot()).standardizedFileURL
  }

  func stage(
    sourceDirectory: URL,
    dockerfile: URL? = nil,
    dockerignore: BuildContextDockerignoreSelection = .conventional
  ) async throws -> StagedBuildContext {
    try Task.checkCancellation()
    let stagingRoot = stagingRoot
    let operation = Task.detached(priority: .utility) {
      try Self.stageSynchronously(
        sourceDirectory: sourceDirectory,
        dockerfile: dockerfile,
        dockerignore: dockerignore,
        stagingRoot: stagingRoot
      )
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  func discard(_ context: StagedBuildContext) async throws {
    let stagingRoot = stagingRoot
    try await Task.detached(priority: .utility) {
      try Self.discardSynchronously(context, stagingRoot: stagingRoot)
    }.value
  }

  func validate(_ context: StagedBuildContext) async throws {
    try Task.checkCancellation()
    let stagingRoot = stagingRoot
    let operation = Task.detached(priority: .utility) {
      try Self.validateSynchronously(context, stagingRoot: stagingRoot)
    }
    try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private static func stageSynchronously(
    sourceDirectory: URL,
    dockerfile: URL?,
    dockerignore: BuildContextDockerignoreSelection,
    stagingRoot: URL
  ) throws -> StagedBuildContext {
    try Task.checkCancellation()
    try requireFileURL(sourceDirectory)
    try requireFileURL(stagingRoot)

    let sourceURL = sourceDirectory.standardizedFileURL
    let rootURL = stagingRoot.standardizedFileURL
    let sourceSnapshot = try snapshot(at: sourceURL, displayPath: ".")
    guard sourceSnapshot.kind == .directory else {
      throw BuildContextStagingError.sourceNotDirectory(sourceURL)
    }
    // Resolve existing ancestor aliases only for boundary comparison. Entries beneath the
    // source are still inspected and opened without following links.
    let sourceBoundaryURL = sourceURL.resolvingSymlinksInPath()
    let rootBoundaryURL = rootURL.resolvingSymlinksInPath()
    guard !pathsOverlap(sourceBoundaryURL, rootBoundaryURL) else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }

    let dockerfileSourceURL = try normalizedDockerfileURL(
      dockerfile,
      sourceURL: sourceURL
    )
    let dockerfileRelativePath = try relativePath(
      for: dockerfileSourceURL,
      within: sourceURL,
      outsideError: .dockerfileOutsideContext(dockerfileSourceURL)
    )
    let dockerignoreRelativePath = try selectedDockerignoreRelativePath(
      dockerignore,
      dockerfileURL: dockerfileSourceURL,
      sourceURL: sourceURL
    )

    try ensurePrivateDirectory(rootURL, withIntermediateDirectories: true)
    guard !pathsOverlap(sourceBoundaryURL, rootURL.resolvingSymlinksInPath()) else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }
    let identifier = UUID()
    let destinationURL = rootURL.appending(
      path: identifier.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    guard !isContained(destinationURL.resolvingSymlinksInPath(), by: sourceBoundaryURL) else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }

    do {
      try ensurePrivateDirectory(destinationURL, withIntermediateDirectories: false)
      let destinationSnapshot = try snapshot(
        at: destinationURL,
        displayPath: destinationURL.lastPathComponent
      )
      guard destinationSnapshot.kind == .directory,
        destinationSnapshot.owner == geteuid()
      else {
        throw BuildContextStagingError.stagingDirectoryNotOwned
      }

      var entries: [StagedEntry] = []
      try copyDirectoryContents(
        from: sourceURL,
        to: destinationURL,
        relativePrefix: "",
        entries: &entries
      )
      guard try snapshot(at: sourceURL, displayPath: ".") == sourceSnapshot else {
        throw BuildContextStagingError.sourceChanged(".")
      }
      try setModificationTime(
        at: destinationURL,
        from: sourceSnapshot,
        displayPath: "."
      )
      let stagedRootSnapshot = try snapshot(at: destinationURL, displayPath: ".")

      let stagedDockerfileURL = destinationURL.appending(
        path: dockerfileRelativePath,
        directoryHint: .notDirectory
      )
      guard
        let dockerfileEntry = entries.first(where: {
          $0.relativePath == dockerfileRelativePath
        })
      else {
        throw BuildContextStagingError.dockerfileMissing(dockerfileRelativePath)
      }
      guard dockerfileEntry.kind == .regularFile else {
        throw BuildContextStagingError.dockerfileNotRegular(dockerfileRelativePath)
      }
      guard dockerfileEntry.snapshot.size >= 0,
        dockerfileEntry.snapshot.size < Int64(maximumDockerfileBytes),
        let dockerfileByteCount = Int(exactly: dockerfileEntry.snapshot.size)
      else {
        let byteCount = Int(exactly: dockerfileEntry.snapshot.size) ?? Int.max
        throw BuildContextStagingError.dockerfileTooLarge(byteCount)
      }

      let dockerfileData = try regularFileData(
        at: stagedDockerfileURL,
        expected: dockerfileEntry.snapshot,
        displayPath: dockerfileRelativePath,
        expectedByteCount: dockerfileByteCount
      )
      guard !hasCustomSyntaxDirective(dockerfileData) else {
        throw BuildContextStagingError.customDockerfileSyntax
      }

      let stagedDockerignoreURL: URL?
      let dockerignoreSHA256: String?
      if let dockerignoreRelativePath {
        guard
          let ignoreEntry = entries.first(where: {
            $0.relativePath == dockerignoreRelativePath
          })
        else {
          throw BuildContextStagingError.dockerignoreNotRegular(dockerignoreRelativePath)
        }
        guard ignoreEntry.kind == .regularFile else {
          throw BuildContextStagingError.dockerignoreNotRegular(dockerignoreRelativePath)
        }
        let url = destinationURL.appending(
          path: dockerignoreRelativePath,
          directoryHint: .notDirectory
        )
        stagedDockerignoreURL = url
        dockerignoreSHA256 = try hashRegularFile(
          at: url,
          expected: ignoreEntry.snapshot,
          displayPath: dockerignoreRelativePath
        )
      } else {
        stagedDockerignoreURL = nil
        dockerignoreSHA256 = nil
      }

      return StagedBuildContext(
        id: identifier,
        contextURL: destinationURL,
        dockerfileURL: stagedDockerfileURL,
        dockerfileSHA256: sha256(dockerfileData),
        dockerignoreURL: stagedDockerignoreURL,
        dockerignoreSHA256: dockerignoreSHA256,
        fingerprint: try treeFingerprint(entries, rootSnapshot: stagedRootSnapshot)
      )
    } catch {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }
  }

  private static func discardSynchronously(
    _ context: StagedBuildContext,
    stagingRoot: URL
  ) throws {
    try Task.checkCancellation()
    let rootURL = stagingRoot.standardizedFileURL
    let contextURL = context.contextURL.standardizedFileURL
    let expectedName = context.id.uuidString.lowercased()
    guard contextURL.deletingLastPathComponent() == rootURL,
      contextURL.lastPathComponent == expectedName
    else {
      throw BuildContextStagingError.discardOutsideStagingRoot(contextURL)
    }

    guard
      let contextSnapshot = try optionalSnapshot(
        at: contextURL,
        displayPath: contextURL.lastPathComponent
      )
    else {
      return
    }
    guard contextSnapshot.kind == .directory,
      contextSnapshot.owner == geteuid()
    else {
      throw BuildContextStagingError.discardOutsideStagingRoot(contextURL)
    }
    try FileManager.default.removeItem(at: contextURL)
  }

  private static func validateSynchronously(
    _ context: StagedBuildContext,
    stagingRoot: URL
  ) throws {
    try Task.checkCancellation()
    let rootURL = stagingRoot.standardizedFileURL
    let contextURL = context.contextURL.standardizedFileURL
    let expectedName = context.id.uuidString.lowercased()
    guard contextURL.deletingLastPathComponent() == rootURL,
      contextURL.lastPathComponent == expectedName
    else {
      throw BuildContextStagingError.discardOutsideStagingRoot(contextURL)
    }

    let rootSnapshot = try snapshot(at: rootURL, displayPath: rootURL.lastPathComponent)
    guard rootSnapshot.kind == .directory,
      rootSnapshot.owner == geteuid(),
      rootSnapshot.permissions & 0o077 == 0
    else {
      throw BuildContextStagingError.stagingDirectoryNotOwned
    }
    let contextSnapshot = try snapshot(at: contextURL, displayPath: contextURL.lastPathComponent)
    guard contextSnapshot.kind == .directory,
      contextSnapshot.owner == geteuid(),
      contextSnapshot.permissions & 0o077 == 0
    else {
      throw BuildContextStagingError.stagingDirectoryNotOwned
    }
    let canonicalRoot = rootURL.resolvingSymlinksInPath()
    let canonicalContext = contextURL.resolvingSymlinksInPath()
    guard canonicalContext.deletingLastPathComponent() == canonicalRoot,
      canonicalContext.lastPathComponent == expectedName
    else {
      throw BuildContextStagingError.discardOutsideStagingRoot(contextURL)
    }

    var entries: [StagedEntry] = []
    try inspectPrivateDirectoryContents(
      at: contextURL,
      relativePrefix: "",
      entries: &entries
    )
    guard try snapshot(at: contextURL, displayPath: ".") == contextSnapshot else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }

    let dockerfileRelativePath = try relativePath(
      for: context.dockerfileURL.standardizedFileURL,
      within: contextURL,
      outsideError: .dockerfileOutsideContext(context.dockerfileURL)
    )
    guard
      let dockerfileEntry = entries.first(where: {
        $0.relativePath == dockerfileRelativePath
      }),
      dockerfileEntry.kind == .regularFile
    else {
      throw BuildContextStagingError.dockerfileNotRegular(dockerfileRelativePath)
    }
    guard dockerfileEntry.snapshot.size >= 0,
      dockerfileEntry.snapshot.size < Int64(maximumDockerfileBytes),
      let dockerfileByteCount = Int(exactly: dockerfileEntry.snapshot.size)
    else {
      let byteCount = Int(exactly: dockerfileEntry.snapshot.size) ?? Int.max
      throw BuildContextStagingError.dockerfileTooLarge(byteCount)
    }
    let dockerfileData = try regularFileData(
      at: context.dockerfileURL,
      expected: dockerfileEntry.snapshot,
      displayPath: dockerfileRelativePath,
      expectedByteCount: dockerfileByteCount
    )
    guard !hasCustomSyntaxDirective(dockerfileData) else {
      throw BuildContextStagingError.customDockerfileSyntax
    }
    guard sha256(dockerfileData) == context.dockerfileSHA256 else {
      throw BuildContextStagingError.stagedDockerfileHashMismatch
    }

    switch (context.dockerignoreURL, context.dockerignoreSHA256) {
    case (nil, nil):
      break
    case (let ignoreURL?, let expectedHash?):
      let relativePath = try relativePath(
        for: ignoreURL.standardizedFileURL,
        within: contextURL,
        outsideError: .stagedDockerignoreMetadataMismatch
      )
      guard
        let ignoreEntry = entries.first(where: { $0.relativePath == relativePath }),
        ignoreEntry.kind == .regularFile
      else {
        throw BuildContextStagingError.dockerignoreNotRegular(relativePath)
      }
      let actualHash = try hashRegularFile(
        at: ignoreURL,
        expected: ignoreEntry.snapshot,
        displayPath: relativePath
      )
      guard actualHash == expectedHash else {
        throw BuildContextStagingError.stagedDockerignoreHashMismatch
      }
    default:
      throw BuildContextStagingError.stagedDockerignoreMetadataMismatch
    }

    guard
      try treeFingerprint(entries, rootSnapshot: contextSnapshot) == context.fingerprint
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }

    var revalidatedEntries: [StagedEntry] = []
    try inspectPrivateDirectoryContents(
      at: contextURL,
      relativePrefix: "",
      entries: &revalidatedEntries
    )
    guard normalizedEntries(entries) == normalizedEntries(revalidatedEntries),
      try snapshot(at: contextURL, displayPath: ".") == contextSnapshot
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }
  }

  private static func normalizedDockerfileURL(
    _ dockerfile: URL?,
    sourceURL: URL
  ) throws -> URL {
    let url = dockerfile ?? sourceURL.appending(path: "Dockerfile", directoryHint: .notDirectory)
    try requireFileURL(url)
    return url.standardizedFileURL
  }

  private static func selectedDockerignoreRelativePath(
    _ selection: BuildContextDockerignoreSelection,
    dockerfileURL: URL,
    sourceURL: URL
  ) throws -> String? {
    let candidateURL: URL
    switch selection {
    case .none:
      return nil
    case .conventional:
      candidateURL = sourceURL.appending(path: ".dockerignore", directoryHint: .notDirectory)
    case .dockerfileSibling:
      candidateURL = dockerfileURL.appendingPathExtension("dockerignore")
    }

    let relativePath = try relativePath(
      for: candidateURL.standardizedFileURL,
      within: sourceURL,
      outsideError: .dockerfileOutsideContext(candidateURL)
    )
    return try optionalSnapshot(at: candidateURL, displayPath: relativePath) == nil
      ? nil : relativePath
  }

  private static func copyDirectoryContents(
    from sourceDirectory: URL,
    to destinationDirectory: URL,
    relativePrefix: String,
    entries: inout [StagedEntry]
  ) throws {
    try Task.checkCancellation()
    let displayPath = relativePrefix.isEmpty ? "." : relativePrefix
    let before = try snapshot(at: sourceDirectory, displayPath: displayPath)
    guard before.kind == .directory else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }

    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: sourceDirectory,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted(by: pathByteOrder)
    } catch {
      throw ioError("list directory", sourceDirectory, fallback: error)
    }

    for sourceURL in children {
      try Task.checkCancellation()
      let name = sourceURL.lastPathComponent
      guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/")
      else {
        throw BuildContextStagingError.invalidPath(name)
      }
      let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
      let sourceSnapshot = try snapshot(at: sourceURL, displayPath: relativePath)
      let destinationURL = destinationDirectory.appending(
        path: name,
        directoryHint: sourceSnapshot.kind == .directory ? .isDirectory : .notDirectory
      )

      switch sourceSnapshot.kind {
      case .directory:
        try ensurePrivateDirectory(destinationURL, withIntermediateDirectories: false)
        try copyDirectoryContents(
          from: sourceURL,
          to: destinationURL,
          relativePrefix: relativePath,
          entries: &entries
        )
        try setPermissions(
          at: destinationURL,
          from: sourceSnapshot,
          displayPath: relativePath
        )
        try setModificationTime(
          at: destinationURL,
          from: sourceSnapshot,
          displayPath: relativePath
        )
        entries.append(
          StagedEntry(
            relativePath: relativePath,
            url: destinationURL,
            kind: .directory,
            snapshot: try snapshot(at: destinationURL, displayPath: relativePath)
          )
        )
      case .regularFile:
        let destinationSnapshot = try copyRegularFile(
          from: sourceURL,
          sourceSnapshot: sourceSnapshot,
          to: destinationURL,
          displayPath: relativePath
        )
        entries.append(
          StagedEntry(
            relativePath: relativePath,
            url: destinationURL,
            kind: .regularFile,
            snapshot: destinationSnapshot
          )
        )
      case .blockDevice:
        throw unsupported(relativePath, .blockDevice)
      case .characterDevice:
        throw unsupported(relativePath, .characterDevice)
      case .fifo:
        throw unsupported(relativePath, .fifo)
      case .socket:
        throw unsupported(relativePath, .socket)
      case .symbolicLink:
        throw unsupported(relativePath, .symbolicLink)
      case .unknown:
        throw unsupported(relativePath, .unknown)
      }
    }

    guard try snapshot(at: sourceDirectory, displayPath: displayPath) == before else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
  }

  private static func inspectPrivateDirectoryContents(
    at directoryURL: URL,
    relativePrefix: String,
    entries: inout [StagedEntry]
  ) throws {
    try Task.checkCancellation()
    let displayPath = relativePrefix.isEmpty ? "." : relativePrefix
    let before = try snapshot(at: directoryURL, displayPath: displayPath)
    guard before.kind == .directory, before.owner == geteuid() else {
      throw BuildContextStagingError.stagedEntryNotPrivate(displayPath)
    }

    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted(by: pathByteOrder)
    } catch {
      throw ioError("list staged directory", directoryURL, fallback: error)
    }

    for entryURL in children {
      try Task.checkCancellation()
      let name = entryURL.lastPathComponent
      guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/")
      else {
        throw BuildContextStagingError.invalidPath(name)
      }
      let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
      let entrySnapshot = try snapshot(at: entryURL, displayPath: relativePath)
      guard entrySnapshot.owner == geteuid() else {
        throw BuildContextStagingError.stagedEntryNotPrivate(relativePath)
      }

      switch entrySnapshot.kind {
      case .directory:
        try inspectPrivateDirectoryContents(
          at: entryURL,
          relativePrefix: relativePath,
          entries: &entries
        )
        let after = try snapshot(at: entryURL, displayPath: relativePath)
        guard after == entrySnapshot else {
          throw BuildContextStagingError.stagedFingerprintMismatch
        }
        entries.append(
          StagedEntry(
            relativePath: relativePath,
            url: entryURL,
            kind: .directory,
            snapshot: after
          )
        )
      case .regularFile:
        entries.append(
          StagedEntry(
            relativePath: relativePath,
            url: entryURL,
            kind: .regularFile,
            snapshot: entrySnapshot
          )
        )
      case .blockDevice:
        throw unsupported(relativePath, .blockDevice)
      case .characterDevice:
        throw unsupported(relativePath, .characterDevice)
      case .fifo:
        throw unsupported(relativePath, .fifo)
      case .socket:
        throw unsupported(relativePath, .socket)
      case .symbolicLink:
        throw unsupported(relativePath, .symbolicLink)
      case .unknown:
        throw unsupported(relativePath, .unknown)
      }
    }

    guard try snapshot(at: directoryURL, displayPath: displayPath) == before else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }
  }

  private static func normalizedEntries(_ entries: [StagedEntry]) -> [StagedEntryIdentity] {
    entries.map {
      StagedEntryIdentity(
        relativePath: $0.relativePath,
        kind: $0.kind,
        snapshot: $0.snapshot
      )
    }.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
  }

  private static func copyRegularFile(
    from sourceURL: URL,
    sourceSnapshot: FileSnapshot,
    to destinationURL: URL,
    displayPath: String
  ) throws -> FileSnapshot {
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

    let destinationMode: mode_t = 0o600
    let destinationDescriptor = Darwin.open(
      destinationURL.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      destinationMode
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

  private static func treeFingerprint(
    _ entries: [StagedEntry],
    rootSnapshot: FileSnapshot
  ) throws -> String {
    var hasher = SHA256()
    hasher.update(data: Data("NativeContainers.BuildContext.v2\0".utf8))
    updateFingerprintMetadata(rootSnapshot, hasher: &hasher)

    for entry in entries.sorted(by: entryByteOrder) {
      try Task.checkCancellation()
      let pathData = Data(entry.relativePath.utf8)
      hasher.update(data: Data([entry.kind == .directory ? 0x44 : 0x46]))
      hasher.update(data: encodedUInt64(UInt64(pathData.count)))
      hasher.update(data: pathData)
      updateFingerprintMetadata(entry.snapshot, hasher: &hasher)

      guard entry.kind == .regularFile else { continue }
      guard entry.snapshot.size >= 0 else {
        throw BuildContextStagingError.sourceChanged(entry.relativePath)
      }
      hasher.update(data: encodedUInt64(UInt64(entry.snapshot.size)))
      try streamRegularFile(
        at: entry.url,
        expected: entry.snapshot,
        displayPath: entry.relativePath
      ) { data in
        hasher.update(data: data)
      }
    }
    return hex(hasher.finalize())
  }

  private static func updateFingerprintMetadata(
    _ snapshot: FileSnapshot,
    hasher: inout SHA256
  ) {
    hasher.update(data: encodedUInt64(UInt64(snapshot.permissions)))
    hasher.update(data: encodedUInt64(UInt64(snapshot.owner)))
    hasher.update(data: encodedUInt64(UInt64(snapshot.group)))
    hasher.update(data: encodedInt64(Int64(snapshot.size)))
    hasher.update(data: encodedInt64(Int64(snapshot.modifiedSeconds)))
    hasher.update(data: encodedInt64(Int64(snapshot.modifiedNanoseconds)))
  }

  private static func regularFileData(
    at url: URL,
    expected: FileSnapshot,
    displayPath: String,
    expectedByteCount: Int
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(expectedByteCount)
    try streamRegularFile(at: url, expected: expected, displayPath: displayPath) { data in
      result.append(data)
    }
    return result
  }

  private static func hashRegularFile(
    at url: URL,
    expected: FileSnapshot,
    displayPath: String
  ) throws -> String {
    var hasher = SHA256()
    try streamRegularFile(at: url, expected: expected, displayPath: displayPath) { data in
      hasher.update(data: data)
    }
    return hex(hasher.finalize())
  }

  private static func streamRegularFile(
    at url: URL,
    expected: FileSnapshot,
    displayPath: String,
    consume: (Data) -> Void
  ) throws {
    guard expected.kind == .regularFile else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw posixError("open staged file", url)
    }
    defer { Darwin.close(descriptor) }
    guard try snapshot(descriptor: descriptor, displayPath: displayPath) == expected else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      guard bytesRead >= 0 else {
        throw posixError("read staged file", url)
      }
      if bytesRead == 0 { break }
      consume(Data(buffer[0..<bytesRead]))
    }
    guard try snapshot(descriptor: descriptor, displayPath: displayPath) == expected,
      try snapshot(at: url, displayPath: displayPath) == expected
    else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
  }

  private static func hasCustomSyntaxDirective(_ data: Data) -> Bool {
    var contents = String(decoding: data, as: UTF8.self)
    if contents.first == "\u{feff}" {
      contents.removeFirst()
    }

    for line in contents.split(
      omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
    {
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
      if trimmed.isEmpty { continue }
      guard trimmed.first == "#" else { return false }

      let comment = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
      let lowercased = comment.lowercased()
      guard lowercased.hasPrefix("syntax") else { continue }
      let suffix = comment.dropFirst("syntax".count)
      guard suffix.first.map({ $0 == "=" || $0 == " " || $0 == "\t" }) == true else {
        continue
      }
      if suffix.drop(while: { $0 == " " || $0 == "\t" }).first == "=" {
        return true
      }
    }
    return false
  }

  private static func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  private static func encodedUInt64(_ value: UInt64) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func encodedInt64(_ value: Int64) -> Data {
    encodedUInt64(UInt64(bitPattern: value))
  }

  private static func setModificationTime(
    at url: URL,
    from source: FileSnapshot,
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

  private static func setPermissions(
    at url: URL,
    from source: FileSnapshot,
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

  private static func setModificationTime(
    descriptor: Int32,
    from source: FileSnapshot,
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

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func ensurePrivateDirectory(
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

  private static func snapshot(at url: URL, displayPath: String) throws -> FileSnapshot {
    guard let value = try optionalSnapshot(at: url, displayPath: displayPath) else {
      throw BuildContextStagingError.ioFailure(
        operation: "inspect path",
        path: displayPath,
        code: ENOENT
      )
    }
    return value
  }

  private static func optionalSnapshot(
    at url: URL,
    displayPath: String
  ) throws -> FileSnapshot? {
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
    return FileSnapshot(value)
  }

  private static func snapshot(descriptor: Int32, displayPath: String) throws -> FileSnapshot {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
      throw BuildContextStagingError.ioFailure(
        operation: "inspect open file",
        path: displayPath,
        code: errno
      )
    }
    return FileSnapshot(value)
  }

  private static func requireFileURL(_ url: URL) throws {
    guard url.isFileURL else {
      throw BuildContextStagingError.nonFileURL(url)
    }
  }

  private static func relativePath(
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

  private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    isContained(lhs, by: rhs) || isContained(rhs, by: lhs)
  }

  private static func isContained(_ child: URL, by parent: URL) -> Bool {
    let childComponents = child.standardizedFileURL.pathComponents
    let parentComponents = parent.standardizedFileURL.pathComponents
    return childComponents.count >= parentComponents.count
      && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
  }

  private static func pathByteOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
  }

  private static func entryByteOrder(_ lhs: StagedEntry, _ rhs: StagedEntry) -> Bool {
    lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
  }

  private static func unsupported(
    _ path: String,
    _ kind: BuildContextUnsupportedEntryKind
  ) -> BuildContextStagingError {
    .unsupportedEntry(path: path, kind: kind)
  }

  private static func posixError(_ operation: String, _ url: URL) -> BuildContextStagingError {
    .ioFailure(operation: operation, path: url.path, code: errno)
  }

  private static func ioError(
    _ operation: String,
    _ url: URL,
    fallback: any Error
  ) -> BuildContextStagingError {
    let code =
      (fallback as NSError).domain == NSPOSIXErrorDomain
      ? Int32((fallback as NSError).code) : EIO
    return .ioFailure(operation: operation, path: url.path, code: code)
  }

  private static func defaultStagingRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Build Contexts", directoryHint: .isDirectory)
  }
}

private enum BuildContextFileKind: Equatable {
  case blockDevice
  case characterDevice
  case directory
  case fifo
  case regularFile
  case socket
  case symbolicLink
  case unknown
}

private struct FileSnapshot: Equatable {
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

extension BuildContextFileKind {
  fileprivate init(mode: mode_t) {
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

private struct StagedEntry {
  let relativePath: String
  let url: URL
  let kind: BuildContextFileKind
  let snapshot: FileSnapshot
}

private struct StagedEntryIdentity: Equatable {
  let relativePath: String
  let kind: BuildContextFileKind
  let snapshot: FileSnapshot
}
