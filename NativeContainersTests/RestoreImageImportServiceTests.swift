import Foundation
import Testing

@testable import NativeContainers

struct RestoreImageImportServiceTests {
  @Test
  func importsLocalIPSWIntoPrivateCache() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Selected.ipsw")
    let payload = Data(repeating: 0xA5, count: 6 * 1_024 * 1_024)
    try payload.write(to: source)
    let recorder = ImportProgressRecorder()
    let cache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let service = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: cache
    )

    let lease = try await service.importImage(at: source) { update in
      await recorder.record(update)
    }
    let imported = lease.fileURL

    #expect(imported.deletingLastPathComponent() == fixture.cache)
    #expect(imported != source)
    #expect(try Data(contentsOf: imported) == payload)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(await recorder.updates.last?.fractionCompleted == 1)
    await cache.commit(lease)
    #expect(FileManager.default.fileExists(atPath: imported.path))
    #expect(!FileManager.default.fileExists(atPath: pendingMarker(for: imported).path))
  }

  @Test
  func discardedLeaseRemovesPromotedPrivateCopy() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Discarded.ipsw")
    try Data([1, 2, 3]).write(to: source)
    let cache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let service = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: cache
    )
    let lease = try await service.importImage(at: source)

    #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
    try await cache.abandon(lease)
    let existsAfterDiscard = FileManager.default.fileExists(atPath: lease.fileURL.path)
    #expect(existsAfterDiscard == false)
  }

  @Test
  func cancellationRemovesPartialImport() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Large.ipsw")
    try Data(repeating: 0x5A, count: 10 * 1_024 * 1_024).write(to: source)
    let pause = ImportPause()
    let cache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let service = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: cache
    )

    let task = Task {
      try await service.importImage(at: source) { _ in
        await pause.pauseOnce()
      }
    }

    await pause.waitUntilPaused()
    task.cancel()
    await pause.resume()

    do {
      _ = try await task.value
      Issue.record("A cancelled import must throw CancellationError.")
    } catch is CancellationError {
      // Expected.
    }

    let cachedFiles =
      (try? FileManager.default.contentsOfDirectory(
        at: fixture.cache,
        includingPropertiesForKeys: nil
      )) ?? []
    #expect(
      cachedFiles.allSatisfy {
        $0.lastPathComponent == RestoreImageImportService.operationLockFilename
      }
    )
  }

  @Test
  func relaunchRecoveryRemovesAnUnreferencedPromotedImport() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Interrupted.ipsw")
    try Data([1, 2, 3]).write(to: source)
    let lease = try await createInterruptedImport(source: source, cache: fixture.cache)
    #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: pendingMarker(for: lease.fileURL).path))

    let relaunchedCache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    try await relaunchedCache.recover { [] }

    #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: pendingMarker(for: lease.fileURL).path))
  }

  @Test
  func relaunchRecoveryKeepsAnImportReferencedByAPersistedManifest() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Persisted.ipsw")
    try Data([4, 5, 6]).write(to: source)
    let lease = try await createInterruptedImport(source: source, cache: fixture.cache)

    let relaunchedCache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    try await relaunchedCache.recover { [lease.fileURL] }

    #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: pendingMarker(for: lease.fileURL).path))
  }

  @Test
  func concurrentRecoveryDoesNotRemoveAnImportWithALiveOwner() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Active.ipsw")
    try Data([7, 8, 9]).write(to: source)
    let activeCache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let activeService = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: activeCache
    )
    let lease = try await activeService.importImage(at: source)

    let competingCache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let competingService = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: competingCache
    )
    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      _ = try await competingService.importImage(at: lease.fileURL)
    }
    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      try await competingCache.recover { [] }
    }

    #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: pendingMarker(for: lease.fileURL).path))
    try await activeCache.abandon(lease)
  }

  @Test
  func imageAlreadyInPrivateCacheStillReceivesADurableLease() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.cache,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let cachedImage = fixture.cache.appending(path: "Existing.ipsw")
    try Data([1, 2, 3]).write(to: cachedImage)
    let owner = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let importer = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: owner
    )

    let lease = try await importer.importImage(at: cachedImage)
    #expect(lease.purpose == .existingCachedImage)

    let competitor = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      _ = try await competitor.acquireLease(
        for: fixture.cache.appending(path: "Other.ipsw"),
        purpose: .remoteDownload,
        abandonPolicy: .retainArtifacts
      )
    }

    await owner.commit(lease)
  }

  @Test
  func rejectsSymbolicRestoreImage() async throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }

    let source = fixture.root.appending(path: "Real.ipsw")
    try Data([1]).write(to: source)
    let symbolic = fixture.root.appending(path: "Symbolic.ipsw")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
    let cache = RestoreImageCacheService(cacheDirectoryURL: fixture.cache)
    let service = RestoreImageImportService(
      cacheDirectoryURL: fixture.cache,
      cache: cache
    )

    do {
      _ = try await service.importImage(at: symbolic)
      Issue.record("A symbolic restore image must be rejected.")
    } catch let error as RestoreImageImportError {
      #expect(error == .invalidSource(symbolic))
    }
  }

  private func pendingMarker(for importedURL: URL) -> URL {
    importedURL.deletingLastPathComponent().appending(
      path:
        ".\(importedURL.lastPathComponent)\(RestoreImageCacheService.leaseMarkerSuffix)"
    )
  }

  private func createInterruptedImport(source: URL, cache: URL) async throws
    -> RestoreImageCacheLease
  {
    let cacheService = RestoreImageCacheService(cacheDirectoryURL: cache)
    let service = RestoreImageImportService(
      cacheDirectoryURL: cache,
      cache: cacheService
    )
    return try await service.importImage(at: source)
  }
}

private struct ImportFixture {
  let root: URL
  let cache: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-ImportTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    cache = root.appending(path: "Cache", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor ImportProgressRecorder {
  private(set) var updates: [RestoreImageDownloadProgress] = []

  func record(_ update: RestoreImageDownloadProgress) {
    updates.append(update)
  }
}

private actor ImportPause {
  private var isPaused = false
  private var didPause = false
  private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func pauseOnce() async {
    guard !didPause else { return }
    didPause = true
    isPaused = true
    let waiters = pausedWaiters
    pausedWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
  }

  func waitUntilPaused() async {
    if isPaused { return }
    await withCheckedContinuation { continuation in
      pausedWaiters.append(continuation)
    }
  }

  func resume() {
    isPaused = false
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}
