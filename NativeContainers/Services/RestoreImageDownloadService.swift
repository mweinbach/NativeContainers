import CryptoKit
import Darwin
import Foundation

protocol MacRestoreImageDownloading: Sendable {
  func download(
    from sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease
}

extension MacRestoreImageDownloading {
  func download(from sourceURL: URL) async throws -> RestoreImageCacheLease {
    try await download(from: sourceURL) { _ in }
  }
}

actor RestoreImageDownloadService: MacRestoreImageDownloading {
  static let partialFileExtension = "partial"

  private let downloadDirectoryURL: URL
  private let cache: any RestoreImageCacheManaging
  private let sessionConfiguration: URLSessionConfiguration
  private let fileManager: FileManager
  private var activeDestinations = Set<URL>()

  init(
    downloadDirectoryURL: URL? = nil,
    sessionConfiguration: URLSessionConfiguration = .default,
    fileManager: FileManager = .default,
    cache: (any RestoreImageCacheManaging)? = nil
  ) {
    let downloadDirectoryURL =
      (downloadDirectoryURL ?? RestoreImageCacheDirectory.defaultURL(fileManager: fileManager))
      .standardizedFileURL
    self.downloadDirectoryURL = downloadDirectoryURL
    self.cache =
      cache
      ?? RestoreImageCacheService(
        cacheDirectoryURL: downloadDirectoryURL
      )
    self.sessionConfiguration = sessionConfiguration.copy() as! URLSessionConfiguration
    self.fileManager = fileManager
  }

  func download(
    from sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease {
    let destinationURL = Self.destinationURL(
      for: sourceURL,
      in: downloadDirectoryURL
    )
    let lease = try await cache.acquireLease(
      for: destinationURL,
      purpose: .remoteDownload,
      abandonPolicy: .retainArtifacts
    )

    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        let byteCount = try completedByteCount(at: destinationURL)
        try removeRegularPartialIfPresent(at: lease.partialURL)
        await progress(
          RestoreImageDownloadProgress(
            receivedBytes: byteCount,
            totalBytes: byteCount
          )
        )
        return lease
      }

      _ = try await download(
        from: sourceURL,
        to: destinationURL,
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

  func download(
    from sourceURL: URL,
    to destinationURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageDownloadResult {
    guard let scheme = sourceURL.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      throw RestoreImageDownloadError.unsupportedSourceURL(sourceURL)
    }
    guard destinationURL.isFileURL else {
      throw RestoreImageDownloadError.nonFileDestination(destinationURL)
    }

    let destinationURL = destinationURL.standardizedFileURL
    guard activeDestinations.insert(destinationURL).inserted else {
      throw RestoreImageDownloadError.downloadAlreadyInProgress(destinationURL)
    }
    defer { activeDestinations.remove(destinationURL) }

    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let partialURL = Self.partialFileURL(for: destinationURL)
    let existingByteCount = try partialByteCount(at: partialURL)
    var request = URLRequest(
      url: sourceURL,
      cachePolicy: .reloadIgnoringLocalCacheData
    )
    request.httpMethod = "GET"
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if existingByteCount > 0 {
      request.setValue("bytes=\(existingByteCount)-", forHTTPHeaderField: "Range")
    }

    let (progressUpdates, progressContinuation) = AsyncStream.makeStream(
      of: RestoreImageDownloadProgress.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    let progressTask = Task {
      for await update in progressUpdates {
        await progress(update)
      }
    }
    let transfer = RestoreImageTransfer(
      configuration: sessionConfiguration,
      request: request,
      partialURL: partialURL,
      requestedOffset: existingByteCount,
      progress: { update in
        _ = progressContinuation.yield(update)
      }
    )

    do {
      let outcome = try await transfer.run()
      try promote(partialURL: partialURL, to: destinationURL)
      _ = progressContinuation.yield(
        RestoreImageDownloadProgress(
          receivedBytes: outcome.byteCount,
          totalBytes: outcome.byteCount,
          resumedBytes: outcome.resumedFromBytes
        )
      )
      progressContinuation.finish()
      await progressTask.value
      return RestoreImageDownloadResult(
        fileURL: destinationURL,
        byteCount: outcome.byteCount,
        resumedFromBytes: outcome.resumedFromBytes
      )
    } catch {
      progressContinuation.finish()
      progressTask.cancel()
      throw error
    }
  }

  static func partialFileURL(for destinationURL: URL) -> URL {
    destinationURL.appendingPathExtension(Self.partialFileExtension)
  }

  private func partialByteCount(at url: URL) throws -> Int64 {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return 0 }
      throw RestoreImageDownloadError.partialFileIsNotRegularFile(url)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size >= 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw RestoreImageDownloadError.partialFileIsNotRegularFile(url)
    }
    return Int64(metadata.st_size)
  }

  private func completedByteCount(at url: URL) throws -> Int64 {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RestoreImageDownloadError.completedFileIsNotRegularFile(url)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw RestoreImageDownloadError.completedFileIsNotRegularFile(url)
    }
    return Int64(metadata.st_size)
  }

  private func removeRegularPartialIfPresent(at url: URL) throws {
    let byteCount = try partialByteCount(at: url)
    guard byteCount > 0 || fileManager.fileExists(atPath: url.path) else {
      return
    }
    try fileManager.removeItem(at: url)
  }

  private func promote(partialURL: URL, to destinationURL: URL) throws {
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw RestoreImageDownloadError.destinationAlreadyExists(destinationURL)
    }
    try fileManager.moveItem(at: partialURL, to: destinationURL)
  }

  static func destinationURL(for sourceURL: URL, in directoryURL: URL) -> URL {
    directoryURL.appending(
      path: filename(for: sourceURL),
      directoryHint: .notDirectory
    )
  }

  static func filename(for sourceURL: URL) -> String {
    let sourceName = sourceURL.deletingPathExtension().lastPathComponent
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let sanitized = sourceName.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let readableName = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    let prefix = readableName.isEmpty ? "RestoreImage" : String(readableName.prefix(48))
    let digest = SHA256.hash(data: Data(sourceURL.absoluteString.utf8))
      .prefix(10)
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(prefix)-\(digest).ipsw"
  }
}

private final class RestoreImageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  struct Outcome: Sendable {
    let byteCount: Int64
    let resumedFromBytes: Int64
  }

  private struct ContentRange {
    let start: Int64
    let end: Int64
    let total: Int64?
  }

  private let configuration: URLSessionConfiguration
  private let request: URLRequest
  private let partialURL: URL
  private let requestedOffset: Int64
  private let progress: @Sendable (RestoreImageDownloadProgress) -> Void
  private let delegateQueue: OperationQueue
  private let stateLock = NSLock()

  private var continuation: CheckedContinuation<Outcome, any Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var cancellationRequested = false
  private var completed = false

  // The session invokes these only on delegateQueue, whose concurrency is one.
  private var fileHandle: FileHandle?
  private var terminalError: (any Error)?
  private var bodyByteCount: Int64 = 0
  private var expectedBodyByteCount: Int64?
  private var expectedTotalByteCount: Int64?
  private var resumedFromBytes: Int64 = 0

  init(
    configuration: URLSessionConfiguration,
    request: URLRequest,
    partialURL: URL,
    requestedOffset: Int64,
    progress: @escaping @Sendable (RestoreImageDownloadProgress) -> Void
  ) {
    self.configuration = configuration
    self.request = request
    self.partialURL = partialURL
    self.requestedOffset = requestedOffset
    self.progress = progress
    self.delegateQueue = OperationQueue()
    self.delegateQueue.maxConcurrentOperationCount = 1
    self.delegateQueue.qualityOfService = .utility
    super.init()
  }

  func run() async throws -> Outcome {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Outcome, any Error>) in
        begin(with: continuation)
      }
    } onCancel: {
      cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let response = response as? HTTPURLResponse else {
        throw RestoreImageDownloadError.invalidHTTPResponse
      }
      try preparePartialFile(for: response)
      progress(
        RestoreImageDownloadProgress(
          receivedBytes: resumedFromBytes,
          totalBytes: expectedTotalByteCount,
          resumedBytes: resumedFromBytes
        )
      )
      completionHandler(.allow)
    } catch {
      terminalError = error
      completionHandler(.cancel)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard terminalError == nil else { return }
    guard let fileHandle else {
      failAndCancel(with: RestoreImageDownloadError.invalidHTTPResponse)
      return
    }

    do {
      try fileHandle.write(contentsOf: data)
      bodyByteCount += Int64(data.count)
      progress(
        RestoreImageDownloadProgress(
          receivedBytes: resumedFromBytes + bodyByteCount,
          totalBytes: expectedTotalByteCount,
          resumedBytes: resumedFromBytes
        )
      )
    } catch {
      failAndCancel(with: error)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let terminalError {
      finish(with: .failure(terminalError))
      return
    }
    if isCancellationRequested || (error as? URLError)?.code == .cancelled {
      finish(with: .failure(CancellationError()))
      return
    }
    if let error {
      finish(with: .failure(error))
      return
    }

    let byteCount = resumedFromBytes + bodyByteCount
    if let expectedBodyByteCount, bodyByteCount != expectedBodyByteCount {
      finish(
        with: .failure(
          RestoreImageDownloadError.incompleteDownload(
            expected: resumedFromBytes + expectedBodyByteCount,
            actual: byteCount
          )
        )
      )
      return
    }
    if let expectedTotalByteCount, byteCount != expectedTotalByteCount {
      finish(
        with: .failure(
          RestoreImageDownloadError.incompleteDownload(
            expected: expectedTotalByteCount,
            actual: byteCount
          )
        )
      )
      return
    }

    finish(
      with: .success(
        Outcome(byteCount: byteCount, resumedFromBytes: resumedFromBytes)
      )
    )
  }

  private var isCancellationRequested: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancellationRequested
  }

  private func begin(with continuation: CheckedContinuation<Outcome, any Error>) {
    stateLock.lock()
    if cancellationRequested {
      completed = true
      stateLock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }

    self.continuation = continuation
    let session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: delegateQueue
    )
    let task = session.dataTask(with: request)
    self.session = session
    self.task = task
    stateLock.unlock()
    task.resume()
  }

  private func cancel() {
    stateLock.lock()
    cancellationRequested = true
    let task = task
    stateLock.unlock()
    task?.cancel()
  }

  private func preparePartialFile(for response: HTTPURLResponse) throws {
    switch response.statusCode {
    case 200:
      resumedFromBytes = 0
      expectedBodyByteCount = Self.knownLength(response.expectedContentLength)
      expectedTotalByteCount = expectedBodyByteCount
      fileHandle = try openPartialFile(restarting: true)
    case 206:
      let rawContentRange = response.value(forHTTPHeaderField: "Content-Range")
      guard let contentRange = Self.parseContentRange(rawContentRange),
        contentRange.start == requestedOffset
      else {
        throw RestoreImageDownloadError.invalidContentRange(rawContentRange)
      }
      resumedFromBytes = requestedOffset
      expectedBodyByteCount = contentRange.end - contentRange.start + 1
      expectedTotalByteCount = contentRange.total
      fileHandle = try openPartialFile(restarting: false)
    default:
      throw RestoreImageDownloadError.unexpectedHTTPStatus(response.statusCode)
    }
  }

  private func openPartialFile(restarting: Bool) throws -> FileHandle {
    let descriptor = Darwin.open(
      partialURL.path,
      O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw RestoreImageDownloadError.unableToCreatePartialFile(partialURL)
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      Darwin.fchmod(descriptor, 0o600) == 0
    else {
      Darwin.close(descriptor)
      throw RestoreImageDownloadError.partialFileIsNotRegularFile(partialURL)
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      if restarting {
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
      } else {
        let actualOffset = try handle.seekToEnd()
        guard actualOffset <= UInt64(Int64.max), Int64(actualOffset) == requestedOffset else {
          throw RestoreImageDownloadError.partialFileSizeChanged(
            expected: requestedOffset,
            actual: Int64(clamping: actualOffset)
          )
        }
      }
      return handle
    } catch {
      try? handle.close()
      throw error
    }
  }

  private func failAndCancel(with error: any Error) {
    guard terminalError == nil else { return }
    terminalError = error
    stateLock.lock()
    let task = task
    stateLock.unlock()
    task?.cancel()
  }

  private func finish(with result: Result<Outcome, any Error>) {
    let result = closePartialFile(adjusting: result)

    stateLock.lock()
    guard !completed else {
      stateLock.unlock()
      return
    }
    completed = true
    let continuation = continuation
    self.continuation = nil
    let session = session
    self.session = nil
    task = nil
    stateLock.unlock()

    session?.finishTasksAndInvalidate()
    continuation?.resume(with: result)
  }

  private func closePartialFile(
    adjusting result: Result<Outcome, any Error>
  ) -> Result<Outcome, any Error> {
    guard let fileHandle else { return result }
    self.fileHandle = nil
    do {
      try fileHandle.synchronize()
      try fileHandle.close()
      return result
    } catch {
      return .failure(error)
    }
  }

  private static func knownLength(_ value: Int64) -> Int64? {
    value >= 0 ? value : nil
  }

  private static func parseContentRange(_ value: String?) -> ContentRange? {
    guard let value else { return nil }
    let unitAndValue = value.split(
      separator: " ",
      maxSplits: 1,
      omittingEmptySubsequences: true
    )
    guard unitAndValue.count == 2, unitAndValue[0].lowercased() == "bytes" else {
      return nil
    }

    let rangeAndTotal = unitAndValue[1].split(
      separator: "/",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard rangeAndTotal.count == 2 else { return nil }
    let bounds = rangeAndTotal[0].split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard bounds.count == 2,
      let start = Int64(bounds[0]),
      let end = Int64(bounds[1]),
      start >= 0,
      end >= start
    else {
      return nil
    }

    let total: Int64?
    if rangeAndTotal[1] == "*" {
      total = nil
    } else if let parsedTotal = Int64(rangeAndTotal[1]), parsedTotal > end {
      total = parsedTotal
    } else {
      return nil
    }
    return ContentRange(start: start, end: end, total: total)
  }
}
