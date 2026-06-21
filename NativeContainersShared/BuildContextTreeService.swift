import Darwin
import Foundation

enum BuildContextTreeService {
  static func copyDirectoryContents(
    from sourceDirectory: URL,
    to destinationDirectory: URL,
    relativePrefix: String,
    excludingFileIdentities: Set<BuildContextExcludedFileIdentity>,
    entries: inout [BuildContextStagedEntry]
  ) throws {
    try Task.checkCancellation()
    let displayPath = relativePrefix.isEmpty ? "." : relativePrefix
    let before = try BuildContextFileSystem.snapshot(
      at: sourceDirectory,
      displayPath: displayPath
    )
    guard before.kind == .directory else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }

    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: sourceDirectory,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted(by: BuildContextFileSystem.pathByteOrder)
    } catch {
      throw BuildContextFileSystem.ioError(
        "list directory",
        sourceDirectory,
        fallback: error
      )
    }

    for sourceURL in children {
      try Task.checkCancellation()
      let name = sourceURL.lastPathComponent
      guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/")
      else {
        throw BuildContextStagingError.invalidPath(name)
      }
      let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
      let sourceSnapshot = try BuildContextFileSystem.snapshot(
        at: sourceURL,
        displayPath: relativePath
      )
      let destinationURL = destinationDirectory.appending(
        path: name,
        directoryHint: sourceSnapshot.kind == .directory ? .isDirectory : .notDirectory
      )

      switch sourceSnapshot.kind {
      case .directory:
        try BuildContextFileSystem.ensurePrivateDirectory(
          destinationURL,
          withIntermediateDirectories: false
        )
        try copyDirectoryContents(
          from: sourceURL,
          to: destinationURL,
          relativePrefix: relativePath,
          excludingFileIdentities: excludingFileIdentities,
          entries: &entries
        )
        try BuildContextFileSystem.setPermissions(
          at: destinationURL,
          from: sourceSnapshot,
          displayPath: relativePath
        )
        try BuildContextFileSystem.setModificationTime(
          at: destinationURL,
          from: sourceSnapshot,
          displayPath: relativePath
        )
        entries.append(
          BuildContextStagedEntry(
            relativePath: relativePath,
            url: destinationURL,
            kind: .directory,
            snapshot: try BuildContextFileSystem.snapshot(
              at: destinationURL,
              displayPath: relativePath
            )
          )
        )
      case .regularFile:
        let sourceIdentity = BuildContextExcludedFileIdentity(
          device: UInt64(sourceSnapshot.device),
          inode: UInt64(sourceSnapshot.inode)
        )
        guard !excludingFileIdentities.contains(sourceIdentity) else {
          throw BuildContextStagingError.excludedSecretSource(relativePath)
        }
        let destinationSnapshot = try BuildContextFileSystem.copyRegularFile(
          from: sourceURL,
          sourceSnapshot: sourceSnapshot,
          to: destinationURL,
          displayPath: relativePath
        )
        entries.append(
          BuildContextStagedEntry(
            relativePath: relativePath,
            url: destinationURL,
            kind: .regularFile,
            snapshot: destinationSnapshot
          )
        )
      case .blockDevice:
        throw BuildContextFileSystem.unsupported(relativePath, .blockDevice)
      case .characterDevice:
        throw BuildContextFileSystem.unsupported(relativePath, .characterDevice)
      case .fifo:
        throw BuildContextFileSystem.unsupported(relativePath, .fifo)
      case .socket:
        throw BuildContextFileSystem.unsupported(relativePath, .socket)
      case .symbolicLink:
        throw BuildContextFileSystem.unsupported(relativePath, .symbolicLink)
      case .unknown:
        throw BuildContextFileSystem.unsupported(relativePath, .unknown)
      }
    }

    guard
      try BuildContextFileSystem.snapshot(
        at: sourceDirectory,
        displayPath: displayPath
      ) == before
    else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
  }

  static func inspectPrivateDirectoryContents(
    at directoryURL: URL,
    relativePrefix: String,
    entries: inout [BuildContextStagedEntry]
  ) throws {
    try Task.checkCancellation()
    let displayPath = relativePrefix.isEmpty ? "." : relativePrefix
    let before = try BuildContextFileSystem.snapshot(
      at: directoryURL,
      displayPath: displayPath
    )
    guard before.kind == .directory, before.owner == geteuid() else {
      throw BuildContextStagingError.stagedEntryNotPrivate(displayPath)
    }

    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted(by: BuildContextFileSystem.pathByteOrder)
    } catch {
      throw BuildContextFileSystem.ioError(
        "list staged directory",
        directoryURL,
        fallback: error
      )
    }

    for entryURL in children {
      try Task.checkCancellation()
      let name = entryURL.lastPathComponent
      guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/")
      else {
        throw BuildContextStagingError.invalidPath(name)
      }
      let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
      let entrySnapshot = try BuildContextFileSystem.snapshot(
        at: entryURL,
        displayPath: relativePath
      )
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
        let after = try BuildContextFileSystem.snapshot(
          at: entryURL,
          displayPath: relativePath
        )
        guard after == entrySnapshot else {
          throw BuildContextStagingError.stagedFingerprintMismatch
        }
        entries.append(
          BuildContextStagedEntry(
            relativePath: relativePath,
            url: entryURL,
            kind: .directory,
            snapshot: after
          )
        )
      case .regularFile:
        entries.append(
          BuildContextStagedEntry(
            relativePath: relativePath,
            url: entryURL,
            kind: .regularFile,
            snapshot: entrySnapshot
          )
        )
      case .blockDevice:
        throw BuildContextFileSystem.unsupported(relativePath, .blockDevice)
      case .characterDevice:
        throw BuildContextFileSystem.unsupported(relativePath, .characterDevice)
      case .fifo:
        throw BuildContextFileSystem.unsupported(relativePath, .fifo)
      case .socket:
        throw BuildContextFileSystem.unsupported(relativePath, .socket)
      case .symbolicLink:
        throw BuildContextFileSystem.unsupported(relativePath, .symbolicLink)
      case .unknown:
        throw BuildContextFileSystem.unsupported(relativePath, .unknown)
      }
    }

    guard
      try BuildContextFileSystem.snapshot(
        at: directoryURL,
        displayPath: displayPath
      ) == before
    else {
      throw BuildContextStagingError.stagedFingerprintMismatch
    }
  }
}
