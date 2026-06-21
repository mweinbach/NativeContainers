import Darwin
import Foundation

protocol MacRestoreImageImporting: Sendable {
  func importImage(
    at sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease
}

extension MacRestoreImageImporting {
  func importImage(at sourceURL: URL) async throws -> RestoreImageCacheLease {
    try await importImage(at: sourceURL) { _ in }
  }
}

actor RestoreImageImportService: MacRestoreImageImporting {
  static let copyChunkSize = 4 * 1_024 * 1_024
  static let pendingMarkerSuffix = RestoreImageCacheService.legacyImportMarkerSuffix
  static let operationLockFilename = RestoreImageCacheService.operationLockFilename

  private let cacheDirectoryURL: URL
  private let fileManager: FileManager
  private let cache: any RestoreImageCacheManaging

  init(
    cacheDirectoryURL: URL? = nil,
    fileManager: FileManager = .default,
    cache: (any RestoreImageCacheManaging)? = nil
  ) {
    let cacheDirectoryURL =
      (cacheDirectoryURL
      ?? RestoreImageStoreLocations.standard(fileManager: fileManager).current)
      .standardizedFileURL
    self.cacheDirectoryURL = cacheDirectoryURL
    self.fileManager = fileManager
    self.cache =
      cache
      ?? RestoreImageCacheService(
        cacheDirectoryURL: cacheDirectoryURL
      )
  }

  func importImage(
    at sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease {
    guard sourceURL.isFileURL else {
      throw RestoreImageImportError.nonFileSource(sourceURL)
    }
    guard sourceURL.pathExtension.lowercased() == "ipsw" else {
      throw RestoreImageImportError.unsupportedFileType(sourceURL)
    }

    let sourceURL = sourceURL.standardizedFileURL
    if sourceURL.deletingLastPathComponent().standardizedFileURL == cacheDirectoryURL {
      let lease = try await cache.acquireLease(
        for: sourceURL,
        purpose: .existingCachedImage,
        abandonPolicy: .retainArtifacts
      )
      do {
        let input = try openSource(sourceURL)
        defer { try? input.handle.close() }
        await progress(
          RestoreImageDownloadProgress(
            receivedBytes: input.size,
            totalBytes: input.size
          )
        )
        return lease
      } catch {
        try? await cache.abandon(lease)
        throw error
      }
    }

    let input = try openSource(sourceURL)
    defer { try? input.handle.close() }

    let filename = "\(UUID().uuidString)-\(safeFilename(sourceURL.lastPathComponent))"
    let destinationURL = cacheDirectoryURL.appending(
      path: filename,
      directoryHint: .notDirectory
    )
    let lease = try await cache.acquireLease(
      for: destinationURL,
      purpose: .localImport,
      abandonPolicy: .discardArtifacts
    )

    do {
      try await copy(
        input: input.handle,
        expectedSize: input.size,
        to: lease,
        progress: progress
      )
      return lease
    } catch {
      let operationError = error
      do {
        try await cache.abandon(lease)
      } catch {
        throw RestoreImageAcquisitionError.cleanupFailed(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      throw operationError
    }
  }

  private func openSource(_ sourceURL: URL) throws -> (handle: FileHandle, size: Int64) {
    let descriptor = Darwin.open(
      sourceURL.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw RestoreImageImportError.invalidSource(sourceURL)
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      Darwin.close(descriptor)
      throw RestoreImageImportError.invalidSource(sourceURL)
    }
    guard metadata.st_size > 0 else {
      Darwin.close(descriptor)
      throw RestoreImageImportError.emptySource(sourceURL)
    }
    return (
      FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
      Int64(metadata.st_size)
    )
  }

  private func copy(
    input: FileHandle,
    expectedSize: Int64,
    to lease: RestoreImageCacheLease,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws {
    let outputDescriptor = Darwin.open(
      lease.partialURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard outputDescriptor >= 0 else {
      throw RestoreImageImportError.unableToCreateDestination(lease.partialURL)
    }
    let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
    defer { try? output.close() }

    var copiedBytes: Int64 = 0
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
          totalBytes: expectedSize
        )
      )
    }
    try Task.checkCancellation()
    guard copiedBytes == expectedSize else {
      throw RestoreImageImportError.incompleteCopy(
        expected: expectedSize,
        actual: copiedBytes
      )
    }
    try output.synchronize()
    try output.close()
    try input.close()
    guard !fileManager.fileExists(atPath: lease.fileURL.path) else {
      throw RestoreImageDownloadError.destinationAlreadyExists(lease.fileURL)
    }
    try fileManager.moveItem(at: lease.partialURL, to: lease.fileURL)
  }

  private func safeFilename(_ filename: String) -> String {
    let candidate = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
      return "RestoreImage.ipsw"
    }
    return candidate
  }
}

enum RestoreImageImportError: LocalizedError, Equatable, Sendable {
  case nonFileSource(URL)
  case unsupportedFileType(URL)
  case invalidSource(URL)
  case emptySource(URL)
  case unableToCreateDestination(URL)
  case incompleteCopy(expected: Int64, actual: Int64)

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
    }
  }
}
