import Foundation

typealias RestoreImageDownloadProgressHandler =
  @Sendable (RestoreImageDownloadProgress) async -> Void

struct RestoreImageDownloadProgress: Equatable, Sendable {
  let receivedBytes: Int64
  let totalBytes: Int64?
  let resumedBytes: Int64

  init(receivedBytes: Int64, totalBytes: Int64?, resumedBytes: Int64 = 0) {
    let normalizedTotal = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
    let nonnegativeReceivedBytes = max(0, receivedBytes)
    let boundedReceivedBytes =
      normalizedTotal.map {
        min(nonnegativeReceivedBytes, $0)
      } ?? nonnegativeReceivedBytes

    self.receivedBytes = boundedReceivedBytes
    self.totalBytes = normalizedTotal
    self.resumedBytes = min(max(0, resumedBytes), boundedReceivedBytes)
  }

  var fractionCompleted: Double? {
    guard let totalBytes else { return nil }
    guard totalBytes > 0 else { return receivedBytes == 0 ? 1 : nil }
    return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
  }
}

struct RestoreImageDownloadResult: Equatable, Sendable {
  let fileURL: URL
  let byteCount: Int64
  let resumedFromBytes: Int64
}

enum RestoreImageDownloadError: LocalizedError, Equatable, Sendable {
  case unsupportedSourceURL(URL)
  case nonFileDestination(URL)
  case downloadAlreadyInProgress(URL)
  case partialFileIsNotRegularFile(URL)
  case unableToCreatePartialFile(URL)
  case invalidHTTPResponse
  case unexpectedHTTPStatus(Int)
  case invalidContentRange(String?)
  case partialFileSizeChanged(expected: Int64, actual: Int64)
  case incompleteDownload(expected: Int64, actual: Int64)

  var errorDescription: String? {
    switch self {
    case .unsupportedSourceURL(let url):
      "Restore images must use HTTP or HTTPS: \(url.absoluteString)"
    case .nonFileDestination(let url):
      "The restore-image destination must be a file URL: \(url.absoluteString)"
    case .downloadAlreadyInProgress(let url):
      "A restore image is already downloading to \(url.path)."
    case .partialFileIsNotRegularFile(let url):
      "The partial restore image is not a regular file: \(url.path)"
    case .unableToCreatePartialFile(let url):
      "Could not create the partial restore image at \(url.path)."
    case .invalidHTTPResponse:
      "The restore-image server returned a non-HTTP response."
    case .unexpectedHTTPStatus(let statusCode):
      "The restore-image server returned HTTP \(statusCode)."
    case .invalidContentRange(let value):
      "The restore-image server returned an invalid Content-Range header: \(value ?? "missing")."
    case .partialFileSizeChanged(let expected, let actual):
      "The partial restore image changed size during download (expected \(expected), found \(actual))."
    case .incompleteDownload(let expected, let actual):
      "The restore-image download is incomplete (expected \(expected) bytes, received \(actual))."
    }
  }
}
