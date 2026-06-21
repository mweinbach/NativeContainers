import Foundation

protocol MacRestoreImageImporting: Sendable {
  func importImage(
    at sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> URL
}

extension MacRestoreImageImporting {
  func importImage(at sourceURL: URL) async throws -> URL {
    try await importImage(at: sourceURL) { _ in }
  }
}

actor RestoreImageImportService: MacRestoreImageImporting {
  static let copyChunkSize = 4 * 1_024 * 1_024

  private let cacheDirectoryURL: URL
  private let fileManager: FileManager

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
  ) async throws -> URL {
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
      await progress(
        RestoreImageDownloadProgress(receivedBytes: sourceSize, totalBytes: sourceSize)
      )
      return sourceURL
    }

    let filename = "\(UUID().uuidString)-\(safeFilename(sourceURL.lastPathComponent))"
    let destinationURL = cacheDirectoryURL.appending(path: filename, directoryHint: .notDirectory)
    let partialURL = destinationURL.appendingPathExtension(
      RestoreImageDownloadService.partialFileExtension
    )
    var promoted = false
    defer {
      if !promoted {
        try? fileManager.removeItem(at: partialURL)
      }
    }

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
      return destinationURL
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw error
    }
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
