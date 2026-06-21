import Darwin
import Foundation

protocol BuildContextStaging: Sendable {
  func stage(
    sourceDirectory: URL,
    dockerfile: URL?,
    dockerignore: BuildContextDockerignoreSelection,
    excludingFileIdentities: Set<BuildContextExcludedFileIdentity>
  ) async throws -> StagedBuildContext
  func validate(_ context: StagedBuildContext) async throws
  func discard(_ context: StagedBuildContext) async throws
}

extension BuildContextStaging {
  func stage(sourceDirectory: URL) async throws -> StagedBuildContext {
    try await stage(
      sourceDirectory: sourceDirectory,
      dockerfile: nil,
      dockerignore: .conventional,
      excludingFileIdentities: []
    )
  }
}

enum BuildContextDockerignoreSelection: Equatable, Sendable {
  case none
  case conventional
  case dockerfileSibling
}

struct BuildContextExcludedFileIdentity: Equatable, Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
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
  case excludedSecretSource(String)
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
    case .excludedSecretSource(let path):
      "The build context contains a selected secret source at \(path). Move the secret outside the context."
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
    self.stagingRoot =
      (stagingRoot ?? BuildContextFileSystem.defaultStagingRoot()).standardizedFileURL
  }

  func stage(
    sourceDirectory: URL,
    dockerfile: URL? = nil,
    dockerignore: BuildContextDockerignoreSelection = .conventional,
    excludingFileIdentities: Set<BuildContextExcludedFileIdentity> = []
  ) async throws -> StagedBuildContext {
    try Task.checkCancellation()
    let stagingRoot = stagingRoot
    let operation = Task.detached(priority: .utility) {
      try Self.stageSynchronously(
        sourceDirectory: sourceDirectory,
        dockerfile: dockerfile,
        dockerignore: dockerignore,
        excludingFileIdentities: excludingFileIdentities,
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
    excludingFileIdentities: Set<BuildContextExcludedFileIdentity>,
    stagingRoot: URL
  ) throws -> StagedBuildContext {
    try Task.checkCancellation()
    try BuildContextFileSystem.requireFileURL(sourceDirectory)
    try BuildContextFileSystem.requireFileURL(stagingRoot)

    let sourceURL = sourceDirectory.standardizedFileURL
    let rootURL = stagingRoot.standardizedFileURL
    let sourceSnapshot = try BuildContextFileSystem.snapshot(at: sourceURL, displayPath: ".")
    guard sourceSnapshot.kind == .directory else {
      throw BuildContextStagingError.sourceNotDirectory(sourceURL)
    }
    // Resolve existing ancestor aliases only for boundary comparison. Entries beneath the
    // source are still inspected and opened without following links.
    let sourceBoundaryURL = sourceURL.resolvingSymlinksInPath()
    let rootBoundaryURL = rootURL.resolvingSymlinksInPath()
    guard !BuildContextFileSystem.pathsOverlap(sourceBoundaryURL, rootBoundaryURL) else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }

    let dockerfileSourceURL = try normalizedDockerfileURL(
      dockerfile,
      sourceURL: sourceURL
    )
    let dockerfileRelativePath = try BuildContextFileSystem.relativePath(
      for: dockerfileSourceURL,
      within: sourceURL,
      outsideError: .dockerfileOutsideContext(dockerfileSourceURL)
    )
    let dockerignoreRelativePath = try selectedDockerignoreRelativePath(
      dockerignore,
      dockerfileURL: dockerfileSourceURL,
      sourceURL: sourceURL
    )

    try BuildContextFileSystem.ensurePrivateDirectory(rootURL, withIntermediateDirectories: true)
    guard !BuildContextFileSystem.pathsOverlap(sourceBoundaryURL, rootURL.resolvingSymlinksInPath())
    else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }
    let identifier = UUID()
    let destinationURL = rootURL.appending(
      path: identifier.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    guard
      !BuildContextFileSystem.isContained(
        destinationURL.resolvingSymlinksInPath(), by: sourceBoundaryURL)
    else {
      throw BuildContextStagingError.stagingRootOverlapsSource
    }

    do {
      try BuildContextFileSystem.ensurePrivateDirectory(
        destinationURL, withIntermediateDirectories: false)
      let destinationSnapshot = try BuildContextFileSystem.snapshot(
        at: destinationURL,
        displayPath: destinationURL.lastPathComponent
      )
      guard destinationSnapshot.kind == .directory,
        destinationSnapshot.owner == geteuid()
      else {
        throw BuildContextStagingError.stagingDirectoryNotOwned
      }

      var entries: [BuildContextStagedEntry] = []
      try BuildContextTreeService.copyDirectoryContents(
        from: sourceURL,
        to: destinationURL,
        relativePrefix: "",
        excludingFileIdentities: excludingFileIdentities,
        entries: &entries
      )
      guard try BuildContextFileSystem.snapshot(at: sourceURL, displayPath: ".") == sourceSnapshot
      else {
        throw BuildContextStagingError.sourceChanged(".")
      }
      try BuildContextFileSystem.setModificationTime(
        at: destinationURL,
        from: sourceSnapshot,
        displayPath: "."
      )
      let stagedRootSnapshot = try BuildContextFileSystem.snapshot(
        at: destinationURL, displayPath: ".")

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

      let dockerfileData = try BuildContextFingerprint.regularFileData(
        at: stagedDockerfileURL,
        expected: dockerfileEntry.snapshot,
        displayPath: dockerfileRelativePath,
        expectedByteCount: dockerfileByteCount
      )
      guard !BuildContextFingerprint.hasCustomSyntaxDirective(dockerfileData) else {
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
        dockerignoreSHA256 = try BuildContextFingerprint.hashRegularFile(
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
        dockerfileSHA256: BuildContextFingerprint.sha256(dockerfileData),
        dockerignoreURL: stagedDockerignoreURL,
        dockerignoreSHA256: dockerignoreSHA256,
        fingerprint: try BuildContextFingerprint.tree(entries, rootSnapshot: stagedRootSnapshot)
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
      let contextSnapshot = try BuildContextFileSystem.optionalSnapshot(
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

    let rootSnapshot = try BuildContextFileSystem.snapshot(
      at: rootURL, displayPath: rootURL.lastPathComponent)
    guard rootSnapshot.kind == .directory,
      rootSnapshot.owner == geteuid(),
      rootSnapshot.permissions & 0o077 == 0
    else {
      throw BuildContextStagingError.stagingDirectoryNotOwned
    }
    let contextSnapshot = try BuildContextFileSystem.snapshot(
      at: contextURL, displayPath: contextURL.lastPathComponent)
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

    var entries: [BuildContextStagedEntry] = []
    try BuildContextTreeService.inspectPrivateDirectoryContents(
      at: contextURL,
      relativePrefix: "",
      entries: &entries
    )
    guard try BuildContextFileSystem.snapshot(at: contextURL, displayPath: ".") == contextSnapshot
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }

    let dockerfileRelativePath = try BuildContextFileSystem.relativePath(
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
    let dockerfileData = try BuildContextFingerprint.regularFileData(
      at: context.dockerfileURL,
      expected: dockerfileEntry.snapshot,
      displayPath: dockerfileRelativePath,
      expectedByteCount: dockerfileByteCount
    )
    guard !BuildContextFingerprint.hasCustomSyntaxDirective(dockerfileData) else {
      throw BuildContextStagingError.customDockerfileSyntax
    }
    guard BuildContextFingerprint.sha256(dockerfileData) == context.dockerfileSHA256 else {
      throw BuildContextStagingError.stagedDockerfileHashMismatch
    }

    switch (context.dockerignoreURL, context.dockerignoreSHA256) {
    case (nil, nil):
      break
    case (let ignoreURL?, let expectedHash?):
      let relativePath = try BuildContextFileSystem.relativePath(
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
      let actualHash = try BuildContextFingerprint.hashRegularFile(
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
      try BuildContextFingerprint.tree(entries, rootSnapshot: contextSnapshot)
        == context.fingerprint
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }

    var revalidatedEntries: [BuildContextStagedEntry] = []
    try BuildContextTreeService.inspectPrivateDirectoryContents(
      at: contextURL,
      relativePrefix: "",
      entries: &revalidatedEntries
    )
    guard
      BuildContextFingerprint.normalizedEntries(entries)
        == BuildContextFingerprint.normalizedEntries(revalidatedEntries),
      try BuildContextFileSystem.snapshot(at: contextURL, displayPath: ".") == contextSnapshot
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }
  }

  private static func normalizedDockerfileURL(
    _ dockerfile: URL?,
    sourceURL: URL
  ) throws -> URL {
    let url = dockerfile ?? sourceURL.appending(path: "Dockerfile", directoryHint: .notDirectory)
    try BuildContextFileSystem.requireFileURL(url)
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

    let relativePath = try BuildContextFileSystem.relativePath(
      for: candidateURL.standardizedFileURL,
      within: sourceURL,
      outsideError: .dockerfileOutsideContext(candidateURL)
    )
    return try BuildContextFileSystem.optionalSnapshot(at: candidateURL, displayPath: relativePath)
      == nil
      ? nil : relativePath
  }
}
