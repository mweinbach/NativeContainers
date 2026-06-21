import Foundation

enum RestoreImageCacheLeasePurpose: String, Codable, Equatable, Sendable {
  case remoteDownload
  case localImport
  case existingCachedImage
}

enum RestoreImageCacheAbandonPolicy: String, Codable, Equatable, Sendable {
  case retainArtifacts
  case discardArtifacts
}

struct RestoreImageCacheLease: Equatable, Sendable {
  let fileURL: URL
  let partialURL: URL
  let purpose: RestoreImageCacheLeasePurpose
  let abandonPolicy: RestoreImageCacheAbandonPolicy
  let token: UUID

  init(
    fileURL: URL,
    partialURL: URL? = nil,
    purpose: RestoreImageCacheLeasePurpose,
    abandonPolicy: RestoreImageCacheAbandonPolicy,
    token: UUID = UUID()
  ) {
    self.fileURL = fileURL.standardizedFileURL
    self.partialURL =
      partialURL?.standardizedFileURL
      ?? fileURL.appendingPathExtension(RestoreImageDownloadService.partialFileExtension)
      .standardizedFileURL
    self.purpose = purpose
    self.abandonPolicy = abandonPolicy
    self.token = token
  }
}

enum RestoreImageAcquisitionSource: Equatable, Sendable {
  case remote(URL)
  case local(URL)
}

enum RestoreImageCacheError: LocalizedError, Equatable, Sendable {
  case outsideStore(URL)
  case cacheInUse
  case unsafeArtifact(URL)
  case invalidLeaseMarker(URL)

  var errorDescription: String? {
    switch self {
    case .outsideStore(let url):
      "The restore-image artifact is outside the private app store: \(url.path)"
    case .cacheInUse:
      "Another restore-image operation is active. Try again when it finishes."
    case .unsafeArtifact(let url):
      "The restore-image store contains an unsafe artifact at \(url.path)."
    case .invalidLeaseMarker(let url):
      "The restore-image ownership marker is invalid at \(url.path)."
    }
  }
}

enum RestoreImageAcquisitionError: LocalizedError, Equatable, Sendable {
  case cleanupFailed(operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .cleanupFailed(let operation, let cleanup):
      "Restore-image preparation ended (\(operation)), and its private artifact could not be finalized (\(cleanup))."
    }
  }
}
