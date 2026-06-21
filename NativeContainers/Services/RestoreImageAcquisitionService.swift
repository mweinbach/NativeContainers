import Foundation

protocol RestoreImageAcquiring: Sendable {
  func acquire(
    _ source: RestoreImageAcquisitionSource,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease

  func commit(_ lease: RestoreImageCacheLease) async
  func abandon(_ lease: RestoreImageCacheLease) async throws

  func recoverCache(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws
}

extension RestoreImageAcquiring {
  func acquire(_ source: RestoreImageAcquisitionSource) async throws
    -> RestoreImageCacheLease
  {
    try await acquire(source) { _ in }
  }
}

struct RestoreImageAcquisitionService: RestoreImageAcquiring {
  private let downloader: any MacRestoreImageDownloading
  private let importer: any MacRestoreImageImporting
  private let cache: any RestoreImageCacheManaging

  init(
    downloader: any MacRestoreImageDownloading,
    importer: any MacRestoreImageImporting,
    cache: any RestoreImageCacheManaging
  ) {
    self.downloader = downloader
    self.importer = importer
    self.cache = cache
  }

  static func standard() -> RestoreImageAcquisitionService {
    let directoryURL = RestoreImageCacheDirectory.defaultURL()
    let cache = RestoreImageCacheService(cacheDirectoryURL: directoryURL)
    return RestoreImageAcquisitionService(
      downloader: RestoreImageDownloadService(
        downloadDirectoryURL: directoryURL,
        cache: cache
      ),
      importer: RestoreImageImportService(
        cacheDirectoryURL: directoryURL,
        cache: cache
      ),
      cache: cache
    )
  }

  func acquire(
    _ source: RestoreImageAcquisitionSource,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease {
    switch source {
    case .remote(let url):
      try await downloader.download(from: url, progress: progress)
    case .local(let url):
      try await importer.importImage(at: url, progress: progress)
    }
  }

  func commit(_ lease: RestoreImageCacheLease) async {
    await cache.commit(lease)
  }

  func abandon(_ lease: RestoreImageCacheLease) async throws {
    try await cache.abandon(lease)
  }

  func recoverCache(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws {
    try await cache.recover(referencedURLs: referencedURLs)
  }
}
