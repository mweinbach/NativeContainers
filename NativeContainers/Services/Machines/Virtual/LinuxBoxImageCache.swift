import Compression
import CryptoKit
import Darwin
import Foundation

struct LinuxBoxCachedImage: Equatable, Sendable {
  let image: LinuxBoxImageRecord
  let templateURL: URL
}

protocol LinuxBoxImageDownloading: Sendable {
  func download(from sourceURL: URL, to destinationURL: URL) async throws
}

protocol LinuxBoxImagePreparing: Sendable {
  func prepare(image: LinuxBoxImageRecord) async throws -> LinuxBoxCachedImage
}

private final class BoundedLinuxBoxDownloadDelegate: NSObject,
  URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let maximumBytes: Int64
  private let lock = NSLock()
  private var exceededBound = false

  init(maximumBytes: UInt64) {
    self.maximumBytes = Int64(maximumBytes)
  }

  var didExceedBound: Bool {
    lock.withLock { exceededBound }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten > maximumBytes
      || totalBytesExpectedToWrite > maximumBytes
    else { return }
    lock.withLock { exceededBound = true }
    downloadTask.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

struct URLSessionLinuxBoxImageDownloader: LinuxBoxImageDownloading {
  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let delegate = BoundedLinuxBoxDownloadDelegate(
      maximumBytes: LinuxBoxImageCache.maximumCompressedBytes
    )
    let temporaryURL: URL
    let response: URLResponse
    do {
      (temporaryURL, response) = try await URLSession.shared.download(
        from: sourceURL,
        delegate: delegate
      )
    } catch {
      try Task.checkCancellation()
      if delegate.didExceedBound {
        throw LinuxBoxImageCacheError.sizeLimitExceeded
      }
      throw LinuxBoxImageCacheError.downloadFailed
    }
    guard !delegate.didExceedBound,
      (response as? HTTPURLResponse)?.statusCode == 200
    else {
      throw delegate.didExceedBound
        ? LinuxBoxImageCacheError.sizeLimitExceeded
        : LinuxBoxImageCacheError.downloadFailed
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
  }
}

enum LinuxBoxImageCachePhase: String, CaseIterable, Sendable {
  case directoryCreated
  case compressedDownloaded
  case compressedVerified
  case decompressed
  case rawVerified
  case promoted
}

protocol LinuxBoxImageCacheFailureInjecting: Sendable {
  func fail(after phase: LinuxBoxImageCachePhase) throws
}

struct NoLinuxBoxImageCacheFailure: LinuxBoxImageCacheFailureInjecting {
  func fail(after phase: LinuxBoxImageCachePhase) throws {}
}

private struct LinuxBoxLZFSEStepResult {
  let data: Data
  let status: compression_status
  let sourceBytesRemaining: Int
}

private func linuxBoxLZFSEStep(
  source: Data?,
  sourceOffset: Int,
  scratch: UnsafePointer<UInt8>,
  stream: inout compression_stream,
  outputBuffer: inout [UInt8],
  flags: Int32
) -> LinuxBoxLZFSEStepResult {
  precondition(sourceOffset >= 0 && sourceOffset <= (source?.count ?? 0))
  var produced = 0
  var status = COMPRESSION_STATUS_OK

  if let source {
    source.withUnsafeBytes { sourceBuffer in
      if sourceOffset < sourceBuffer.count {
        stream.src_ptr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress!
          .advanced(by: sourceOffset)
        stream.src_size = sourceBuffer.count - sourceOffset
      } else {
        stream.src_ptr = scratch
        stream.src_size = 0
      }
      outputBuffer.withUnsafeMutableBytes { destination in
        stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
        stream.dst_size = destination.count
        status = compression_stream_process(&stream, flags)
        produced = destination.count - stream.dst_size
      }
    }
  } else {
    stream.src_ptr = scratch
    stream.src_size = 0
    outputBuffer.withUnsafeMutableBytes { destination in
      stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
      stream.dst_size = destination.count
      status = compression_stream_process(&stream, flags)
      produced = destination.count - stream.dst_size
    }
  }

  return LinuxBoxLZFSEStepResult(
    data: produced > 0 ? Data(outputBuffer[0..<produced]) : Data(),
    status: status,
    sourceBytesRemaining: stream.src_size
  )
}


actor LinuxBoxImageCache: LinuxBoxImagePreparing {
  static let applicationCacheDirectoryName = "com.nativecontainers.app"
  static let imageDirectoryName = "LinuxBoxImages"
  static let chunkSize = 1 * 1_024 * 1_024
  static let maximumCompressedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
  static let maximumLogicalBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024

  private let rootURL: URL
  private let fileManager: FileManager
  private let downloader: any LinuxBoxImageDownloading
  private let failureInjector: any LinuxBoxImageCacheFailureInjecting

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    downloader: any LinuxBoxImageDownloading = URLSessionLinuxBoxImageDownloader(),
    failureInjector: any LinuxBoxImageCacheFailureInjecting = NoLinuxBoxImageCacheFailure()
  ) {
    self.fileManager = fileManager
    self.downloader = downloader
    self.failureInjector = failureInjector
    if let rootURL {
      self.rootURL = rootURL
    } else {
      let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      self.rootURL = caches
        .appending(path: Self.applicationCacheDirectoryName, directoryHint: .isDirectory)
        .appending(path: Self.imageDirectoryName, directoryHint: .isDirectory)
    }
  }

  func prepare(image: LinuxBoxImageRecord) async throws -> LinuxBoxCachedImage {
    try image.validate()
    guard image.published else { throw LinuxBoxImageCacheError.imageNotPublished }
    guard image.compressedSizeBytes <= Self.maximumCompressedBytes,
      image.logicalSizeBytes <= Self.maximumLogicalBytes
    else { throw LinuxBoxImageCacheError.sizeLimitExceeded }

    try createSecureDirectory(rootURL)
    let directory = rootURL.appending(path: image.imageID, directoryHint: .isDirectory)
    try createSecureDirectory(directory, withIntermediateDirectories: false)
    try failureInjector.fail(after: .directoryCreated)
    let promoted = directory.appending(path: "template.raw")
    if fileManager.fileExists(atPath: promoted.path) {
      do {
        try validateRaw(promoted, image: image, requiredMode: 0o444)
        return LinuxBoxCachedImage(image: image, templateURL: promoted)
      } catch {
        try fileManager.removeItem(at: promoted)
        try synchronizeParent(directory)
      }
    }

    let operation = UUID().uuidString.lowercased()
    let compressed = directory.appending(path: ".\(operation).compressed.partial")
    let raw = directory.appending(path: ".\(operation).raw.partial")
    do {
      try await downloader.download(from: image.releaseAssetURL, to: compressed)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: compressed.path)
      try failureInjector.fail(after: .compressedDownloaded)
      try Task.checkCancellation()
      try verifyCompressed(compressed, image: image)
      try failureInjector.fail(after: .compressedVerified)
      try decompress(compressed, to: raw, image: image)
      try Task.checkCancellation()
      try failureInjector.fail(after: .decompressed)
      try validateRaw(raw, image: image, requiredMode: 0o600)
      try failureInjector.fail(after: .rawVerified)
      try Task.checkCancellation()
      try secureReadOnly(raw)
      try synchronizeFile(raw)
      try synchronizeParent(directory)
      guard !fileManager.fileExists(atPath: promoted.path) else {
        throw LinuxBoxImageCacheError.alreadyPromoted
      }
      try Task.checkCancellation()
      try fileManager.moveItem(at: raw, to: promoted)
      try synchronizeParent(directory)
      try failureInjector.fail(after: .promoted)
      try? fileManager.removeItem(at: compressed)
      return LinuxBoxCachedImage(image: image, templateURL: promoted)
    } catch {
      try? fileManager.removeItem(at: compressed)
      try? fileManager.removeItem(at: raw)
      throw error
    }
  }

  func recover(catalog: LinuxBoxImageCatalog) throws {
    try catalog.validate()
    try createSecureDirectory(rootURL)
    let directories = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for directory in directories {
      guard let image = catalog.images.first(where: {
        $0.imageID == directory.lastPathComponent
      }) else { continue }
      try requireSecureDirectory(directory)
      let entries = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      )
      for entry in entries where isOwnedCachePartial(entry) {
        try fileManager.removeItem(at: entry)
      }
      let promoted = directory.appending(path: "template.raw")
      guard fileManager.fileExists(atPath: promoted.path) else { continue }
      do {
        try validateRaw(promoted, image: image, requiredMode: 0o444)
      } catch {
        try fileManager.removeItem(at: promoted)
      }
      try synchronizeParent(directory)
    }
  }

  func cacheDirectory(for imageID: String) -> URL {
    rootURL.appending(path: imageID, directoryHint: .isDirectory)
  }

  private func createSecureDirectory(
    _ url: URL,
    withIntermediateDirectories: Bool = true
  ) throws {
    var metadata = Darwin.stat()
    if Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 {
      try requireSecureDirectory(url)
    } else {
      guard errno == ENOENT else {
        throw LinuxBoxImageCacheError.invalidCacheDirectory
      }
      do {
        try fileManager.createDirectory(
          at: url,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
        try requireSecureDirectory(url)
      } catch let error as LinuxBoxImageCacheError {
        throw error
      } catch {
        throw LinuxBoxImageCacheError.invalidCacheDirectory
      }
    }
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutableURL = url
    do {
      try mutableURL.setResourceValues(excluded)
    } catch {
      throw LinuxBoxImageCacheError.invalidCacheDirectory
    }
  }

  private func verifyCompressed(_ url: URL, image: LinuxBoxImageRecord) throws {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, UInt64(size) == image.compressedSizeBytes else {
      throw LinuxBoxImageCacheError.compressedSizeMismatch
    }
    let digest = try digest(url, algorithm: .sha256)
    guard digest == image.compressedSHA256 else {
      throw LinuxBoxImageCacheError.compressedDigestMismatch
    }
  }

  private func validateRaw(
    _ url: URL,
    image: LinuxBoxImageRecord,
    requiredMode: mode_t
  ) throws {
    var metadata = Darwin.stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & 0o7777 == requiredMode
    else {
      throw LinuxBoxImageCacheError.invalidCachedArtifact
    }
    guard metadata.st_size >= 0,
      UInt64(metadata.st_size) == image.logicalSizeBytes
    else {
      throw LinuxBoxImageCacheError.logicalSizeMismatch
    }
    guard try digest(url, algorithm: .sha512) == image.rawSHA512 else {
      throw LinuxBoxImageCacheError.rawDigestMismatch
    }
  }

  private func requireSecureDirectory(_ url: URL) throws {
    var metadata = Darwin.stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o7777 == 0o700
    else {
      throw LinuxBoxImageCacheError.invalidCacheDirectory
    }
  }

  private func isOwnedCachePartial(_ url: URL) -> Bool {
    let components = url.lastPathComponent.split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard components.count == 4,
      components[0].isEmpty,
      components[2] == "compressed" || components[2] == "raw",
      components[3] == "partial",
      let operationID = UUID(uuidString: String(components[1])),
      operationID.uuidString.lowercased() == components[1]
    else { return false }
    var metadata = Darwin.stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFREG
      && metadata.st_uid == getuid()
      && metadata.st_nlink == 1
  }

  private enum DigestAlgorithm { case sha256, sha512 }

  private func digest(_ url: URL, algorithm: DigestAlgorithm) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var sha256 = SHA256()
    var sha512 = SHA512()
    while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
      switch algorithm {
      case .sha256: sha256.update(data: data)
      case .sha512: sha512.update(data: data)
      }
    }
    switch algorithm {
    case .sha256: return sha256.finalize().map { String(format: "%02x", $0) }.joined()
    case .sha512: return sha512.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  private func decompress(_ source: URL, to destination: URL, image: LinuxBoxImageRecord) throws {
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw LinuxBoxImageCacheError.partialCreationFailed
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? input.close(); try? output.close() }
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { scratch.deallocate() }
    var stream = compression_stream(
      dst_ptr: scratch,
      dst_size: 0,
      src_ptr: UnsafePointer(scratch),
      src_size: 0,
      state: nil
    )
    guard compression_stream_init(
      &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK
    else {
      throw LinuxBoxImageCacheError.decompressionFailed
    }
    defer { compression_stream_destroy(&stream) }
    var outputBuffer = [UInt8](repeating: 0, count: Self.chunkSize)
    var logicalBytes: UInt64 = 0
    var ended = false

    func store(_ data: Data) throws {
      guard logicalBytes <= image.logicalSizeBytes,
        UInt64(data.count) <= image.logicalSizeBytes - logicalBytes
      else {
        throw LinuxBoxImageCacheError.decompressionOverrun
      }
      guard !data.isEmpty else { return }
      if data.contains(where: { $0 != 0 }) {
        try output.seek(toOffset: logicalBytes)
        try output.write(contentsOf: data)
      } else {
        try output.seek(toOffset: logicalBytes + UInt64(data.count))
      }
      logicalBytes += UInt64(data.count)
    }

    while !ended, let inputData = try input.read(upToCount: Self.chunkSize),
      !inputData.isEmpty
    {
      try Task.checkCancellation()
      var sourceOffset = 0
      var sourceBytesRemaining = inputData.count
      var produced = 0
      repeat {
        try Task.checkCancellation()
        let sourceBytesBefore = sourceBytesRemaining
        let result = linuxBoxLZFSEStep(
          source: inputData,
          sourceOffset: sourceOffset,
          scratch: UnsafePointer(scratch),
          stream: &stream,
          outputBuffer: &outputBuffer,
          flags: 0
        )
        guard result.status != COMPRESSION_STATUS_ERROR,
          result.sourceBytesRemaining <= sourceBytesBefore
        else {
          throw LinuxBoxImageCacheError.decompressionFailed
        }
        sourceBytesRemaining = result.sourceBytesRemaining
        sourceOffset = inputData.count - sourceBytesRemaining
        produced = result.data.count
        try store(result.data)
        if result.status == COMPRESSION_STATUS_END {
          guard sourceBytesRemaining == 0 else {
            throw LinuxBoxImageCacheError.trailingCompressedData
          }
          ended = true
          break
        }
        if produced == 0, sourceBytesRemaining == sourceBytesBefore {
          guard sourceBytesRemaining == 0 else {
            throw LinuxBoxImageCacheError.decompressionFailed
          }
          break
        }
      } while sourceBytesRemaining > 0 || produced == outputBuffer.count
    }

    if !ended {
      repeat {
        try Task.checkCancellation()
        let result = linuxBoxLZFSEStep(
          source: nil,
          sourceOffset: 0,
          scratch: UnsafePointer(scratch),
          stream: &stream,
          outputBuffer: &outputBuffer,
          flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        )
        guard result.status != COMPRESSION_STATUS_ERROR else {
          throw LinuxBoxImageCacheError.decompressionFailed
        }
        try store(result.data)
        if result.status == COMPRESSION_STATUS_END {
          ended = true
          break
        }
        guard !result.data.isEmpty else {
          throw LinuxBoxImageCacheError.decompressionFailed
        }
      } while !ended
    }

    if ended, let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
      throw LinuxBoxImageCacheError.trailingCompressedData
    }
    guard ended, logicalBytes == image.logicalSizeBytes else {
      throw LinuxBoxImageCacheError.decompressionSizeMismatch
    }
    try output.truncate(atOffset: image.logicalSizeBytes)
    try output.synchronize()
  }

  private func secureReadOnly(_ url: URL) throws {
    try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
  }

  private func synchronizeFile(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw LinuxBoxImageCacheError.syncFailed }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw LinuxBoxImageCacheError.syncFailed
    }
  }

  private func synchronizeParent(_ url: URL) throws {
    let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw LinuxBoxImageCacheError.syncFailed }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw LinuxBoxImageCacheError.syncFailed }
  }
}

enum LinuxBoxImageCacheError: LocalizedError, Equatable, Sendable {
  case imageNotPublished, sizeLimitExceeded, downloadFailed
  case compressedSizeMismatch, compressedDigestMismatch
  case logicalSizeMismatch, rawDigestMismatch
  case invalidCacheDirectory, invalidCachedArtifact
  case partialCreationFailed, decompressionFailed, decompressionOverrun
  case trailingCompressedData, decompressionSizeMismatch, alreadyPromoted
  case syncFailed

  var errorDescription: String? {
    switch self {
    case .imageNotPublished: "The requested Linux box image is not published."
    case .sizeLimitExceeded: "The Linux box image exceeds the cache safety bound."
    case .downloadFailed: "The Linux box image download failed."
    case .compressedSizeMismatch: "The compressed Linux box image size did not match the catalog."
    case .compressedDigestMismatch: "The compressed Linux box image digest did not match the catalog."
    case .logicalSizeMismatch: "The decompressed Linux box image size did not match the catalog."
    case .rawDigestMismatch: "The decompressed Linux box image digest did not match the pinned source."
    case .invalidCacheDirectory: "The Linux box image cache directory is not owner-only."
    case .invalidCachedArtifact: "The cached Linux box image is not a trusted owner-only regular file."
    case .partialCreationFailed: "The Linux box image cache could not create a partial."
    case .decompressionFailed: "The Linux box image could not be LZFSE decompressed."
    case .decompressionOverrun: "The Linux box image decompressor exceeded its logical size bound."
    case .trailingCompressedData: "The Linux box image contained trailing compressed data."
    case .decompressionSizeMismatch: "The Linux box image decompressor ended at the wrong size."
    case .alreadyPromoted: "The Linux box image was promoted concurrently."
    case .syncFailed: "The Linux box image cache could not synchronize durable metadata."
    }
  }
}
