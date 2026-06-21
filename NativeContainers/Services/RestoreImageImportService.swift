import Foundation

struct RestoreImageImportLease: Equatable, Sendable {
  let fileURL: URL
  fileprivate let token: UUID?

  init(fileURL: URL, token: UUID? = nil) {
    self.fileURL = fileURL
    self.token = token
  }
}

protocol MacRestoreImageImporting: Sendable {
  func importImage(
    at sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageImportLease
  func commitImport(_ lease: RestoreImageImportLease) async
  func discardImport(_ lease: RestoreImageImportLease) async throws
  func recoverPendingImports(referencedURLs: Set<URL>) async throws
}

extension MacRestoreImageImporting {
  func importImage(at sourceURL: URL) async throws -> RestoreImageImportLease {
    try await importImage(at: sourceURL) { _ in }
  }

  func commitImport(_ lease: RestoreImageImportLease) async {}

  func discardImport(_ lease: RestoreImageImportLease) async throws {}

  func recoverPendingImports(referencedURLs: Set<URL>) async throws {}
}

actor RestoreImageImportService: MacRestoreImageImporting {
  static let copyChunkSize = 4 * 1_024 * 1_024
  static let pendingMarkerSuffix = ".import-pending"
  static let operationLockFilename = ".operations.lock"

  private struct PendingImport {
    let fileURL: URL
    let partialURL: URL
    let markerURL: URL
  }

  private let cacheDirectoryURL: URL
  private let fileManager: FileManager
  private var pendingImports: [UUID: PendingImport] = [:]
  private var operationLockLease: AdvisoryFileLockLease?
  private var activeImportTokens = Set<UUID>()

  init(
    cacheDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.cacheDirectoryURL =
      cacheDirectoryURL ?? RestoreImageCacheDirectory.defaultURL(fileManager: fileManager)
    self.fileManager = fileManager
  }

  func importImage(
    at sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageImportLease {
    guard sourceURL.isFileURL else {
      throw RestoreImageImportError.nonFileSource(sourceURL)
    }
    guard sourceURL.pathExtension.lowercased() == "ipsw" else {
      throw RestoreImageImportError.unsupportedFileType(sourceURL)
    }

    let sourceURL = sourceURL.standardizedFileURL
    let sourceValues: URLResourceValues
    do {
      sourceValues = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    } catch {
      throw RestoreImageImportError.invalidSource(sourceURL)
    }
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw RestoreImageImportError.invalidSource(sourceURL)
    }

    let sourceSize = Int64(sourceValues.fileSize ?? 0)
    guard sourceSize > 0 else {
      throw RestoreImageImportError.emptySource(sourceURL)
    }

    try fileManager.createDirectory(
      at: cacheDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    if isDescendant(sourceURL, of: cacheDirectoryURL) {
      guard !fileManager.fileExists(atPath: pendingMarkerURL(for: sourceURL).path) else {
        throw RestoreImageImportError.cacheInUse
      }
      await progress(
        RestoreImageDownloadProgress(receivedBytes: sourceSize, totalBytes: sourceSize)
      )
      return RestoreImageImportLease(fileURL: sourceURL, token: nil)
    }

    let token = UUID()
    try acquireImportAccess(token: token)

    let filename = "\(UUID().uuidString)-\(safeFilename(sourceURL.lastPathComponent))"
    let destinationURL = cacheDirectoryURL.appending(path: filename, directoryHint: .notDirectory)
    let partialURL = destinationURL.appendingPathExtension(
      RestoreImageDownloadService.partialFileExtension
    )
    let markerURL = pendingMarkerURL(for: destinationURL)
    var promoted = false
    defer {
      if !promoted {
        try? fileManager.removeItem(at: partialURL)
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.removeItem(at: markerURL)
        releaseImportAccess(token: token)
      }
    }

    try Data().write(to: markerURL, options: [.atomic])
    guard
      fileManager.createFile(
        atPath: partialURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw RestoreImageImportError.unableToCreateDestination(partialURL)
    }

    let input = try FileHandle(forReadingFrom: sourceURL)
    let output = try FileHandle(forWritingTo: partialURL)
    defer {
      try? input.close()
      try? output.close()
    }

    var copiedBytes: Int64 = 0
    do {
      while true {
        try Task.checkCancellation()
        guard let data = try input.read(upToCount: Self.copyChunkSize), !data.isEmpty else {
          break
        }
        try output.write(contentsOf: data)
        copiedBytes += Int64(data.count)
        await progress(
          RestoreImageDownloadProgress(
            receivedBytes: copiedBytes,
            totalBytes: sourceSize
          )
        )
      }
      try Task.checkCancellation()
      guard copiedBytes == sourceSize else {
        throw RestoreImageImportError.incompleteCopy(
          expected: sourceSize,
          actual: copiedBytes
        )
      }
      try output.synchronize()
      try output.close()
      try input.close()
      try fileManager.moveItem(at: partialURL, to: destinationURL)
      promoted = true
      pendingImports[token] = PendingImport(
        fileURL: destinationURL,
        partialURL: partialURL,
        markerURL: markerURL
      )
      return RestoreImageImportLease(fileURL: destinationURL, token: token)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw error
    }
  }

  func commitImport(_ lease: RestoreImageImportLease) async {
    guard let token = lease.token,
      let pendingImport = pendingImports[token],
      pendingImport.fileURL == lease.fileURL
    else {
      return
    }
    defer { releaseImportAccess(token: token) }
    try? fileManager.removeItem(at: pendingImport.markerURL)
    pendingImports.removeValue(forKey: token)
  }

  func discardImport(_ lease: RestoreImageImportLease) async throws {
    guard let token = lease.token,
      let pendingImport = pendingImports[token],
      pendingImport.fileURL == lease.fileURL
    else {
      return
    }
    defer { releaseImportAccess(token: token) }
    if fileManager.fileExists(atPath: pendingImport.fileURL.path) {
      try fileManager.removeItem(at: pendingImport.fileURL)
    }
    try? fileManager.removeItem(at: pendingImport.partialURL)
    if fileManager.fileExists(atPath: pendingImport.markerURL.path) {
      try fileManager.removeItem(at: pendingImport.markerURL)
    }
    pendingImports.removeValue(forKey: token)
  }

  func recoverPendingImports(referencedURLs: Set<URL>) async throws {
    guard activeImportTokens.isEmpty else { return }
    guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else { return }
    let recoveryToken = UUID()
    guard try acquireRecoveryAccess(token: recoveryToken) else { return }
    defer { releaseImportAccess(token: recoveryToken) }

    let entries = try fileManager.contentsOfDirectory(
      at: cacheDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    let entriesByName = Dictionary(
      uniqueKeysWithValues: entries.map { ($0.lastPathComponent, $0) }
    )
    let referencedURLs = Set(referencedURLs.map(\.standardizedFileURL))

    for markerURL in entries where isPendingMarker(markerURL.lastPathComponent) {
      try requireRegularRecoveryArtifact(markerURL)

      let filename = try pendingFilename(from: markerURL)
      let importedURL = cacheDirectoryURL.appending(
        path: filename,
        directoryHint: .notDirectory
      )
      let partialFilename =
        "\(filename).\(RestoreImageDownloadService.partialFileExtension)"

      if !referencedURLs.contains(importedURL.standardizedFileURL),
        let importedEntry = entriesByName[filename]
      {
        try removeRegularRecoveryArtifact(importedEntry)
      }
      if let partialEntry = entriesByName[partialFilename] {
        try removeRegularRecoveryArtifact(partialEntry)
      }
      try fileManager.removeItem(at: markerURL)
    }
  }

  private func pendingMarkerURL(for fileURL: URL) -> URL {
    cacheDirectoryURL.appending(
      path: ".\(fileURL.lastPathComponent)\(Self.pendingMarkerSuffix)",
      directoryHint: .notDirectory
    )
  }

  private func isPendingMarker(_ filename: String) -> Bool {
    filename.hasPrefix(".") && filename.hasSuffix(Self.pendingMarkerSuffix)
  }

  private func pendingFilename(from markerURL: URL) throws -> String {
    let markerName = markerURL.lastPathComponent
    let filename = String(
      markerName.dropFirst().dropLast(Self.pendingMarkerSuffix.count)
    )
    guard !filename.isEmpty,
      filename != ".",
      filename != "..",
      URL(filePath: filename).lastPathComponent == filename
    else {
      throw RestoreImageImportError.unsafeRecoveryArtifact(markerURL)
    }
    return filename
  }

  private func requireRegularRecoveryArtifact(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw RestoreImageImportError.unsafeRecoveryArtifact(url)
    }
  }

  private func removeRegularRecoveryArtifact(_ url: URL) throws {
    try requireRegularRecoveryArtifact(url)
    try fileManager.removeItem(at: url)
  }

  private func acquireImportAccess(token: UUID) throws {
    guard activeImportTokens.insert(token).inserted else {
      throw RestoreImageImportError.cacheInUse
    }
    guard operationLockLease == nil else { return }

    do {
      guard
        let lease = try AdvisoryFileLock.acquire(
          at: cacheDirectoryURL.appending(path: Self.operationLockFilename)
        )
      else {
        activeImportTokens.remove(token)
        throw RestoreImageImportError.cacheInUse
      }
      operationLockLease = lease
    } catch {
      activeImportTokens.remove(token)
      throw error
    }
  }

  private func acquireRecoveryAccess(token: UUID) throws -> Bool {
    guard activeImportTokens.insert(token).inserted else { return false }
    do {
      guard
        let lease = try AdvisoryFileLock.acquire(
          at: cacheDirectoryURL.appending(path: Self.operationLockFilename)
        )
      else {
        activeImportTokens.remove(token)
        return false
      }
      operationLockLease = lease
      return true
    } catch {
      activeImportTokens.remove(token)
      throw error
    }
  }

  private func releaseImportAccess(token: UUID) {
    guard activeImportTokens.remove(token) != nil else { return }
    guard activeImportTokens.isEmpty else { return }
    operationLockLease?.release()
    operationLockLease = nil
  }

  private func safeFilename(_ filename: String) -> String {
    let candidate = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
      return "RestoreImage.ipsw"
    }
    return candidate
  }

  private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let directoryComponents =
      directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let candidateComponents =
      candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard candidateComponents.count > directoryComponents.count else { return false }
    return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
  }
}

enum RestoreImageCacheDirectory {
  static func defaultURL(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Restore Images", directoryHint: .isDirectory)
  }
}

enum RestoreImageImportError: LocalizedError, Equatable, Sendable {
  case nonFileSource(URL)
  case unsupportedFileType(URL)
  case invalidSource(URL)
  case emptySource(URL)
  case unableToCreateDestination(URL)
  case incompleteCopy(expected: Int64, actual: Int64)
  case cleanupFailed(operation: String, cleanup: String)
  case unsafeRecoveryArtifact(URL)
  case cacheInUse

  var errorDescription: String? {
    switch self {
    case .nonFileSource(let url):
      "The selected restore image is not a local file: \(url.absoluteString)"
    case .unsupportedFileType(let url):
      "The selected restore image must be an IPSW file: \(url.lastPathComponent)"
    case .invalidSource(let url):
      "The selected restore image is missing, symbolic, or not a regular file: \(url.path)"
    case .emptySource(let url):
      "The selected restore image is empty: \(url.path)"
    case .unableToCreateDestination(let url):
      "Could not create the private restore-image copy at \(url.path)."
    case .incompleteCopy(let expected, let actual):
      "The restore-image import is incomplete (expected \(expected) bytes, copied \(actual))."
    case .cleanupFailed(let operation, let cleanup):
      "Restore-image preparation ended (\(operation)), and its private cache copy could not be removed (\(cleanup))."
    case .unsafeRecoveryArtifact(let url):
      "Restore-image recovery refused to remove an unsafe cache artifact at \(url.path)."
    case .cacheInUse:
      "Another NativeContainers process is importing a restore image. Try again when it finishes."
    }
  }
}
