import Foundation
import Testing

@testable import NativeContainers

@Suite("Restore image cache ownership", .serialized)
struct RestoreImageCacheServiceTests {
  @Test
  func activeLeaseBlocksAnotherProcessAuthorityUntilCommit() async throws {
    let fixture = try RestoreImageCacheFixture()
    defer { fixture.remove() }
    let first = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let second = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    let firstLease = try await first.acquireLease(
      for: fixture.fileURL,
      purpose: .remoteDownload,
      abandonPolicy: .retainArtifacts
    )

    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      _ = try await second.acquireLease(
        for: fixture.cacheURL.appending(path: "Other.ipsw"),
        purpose: .localImport,
        abandonPolicy: .discardArtifacts
      )
    }

    await first.commit(firstLease)
    let secondLease = try await second.acquireLease(
      for: fixture.cacheURL.appending(path: "Other.ipsw"),
      purpose: .localImport,
      abandonPolicy: .discardArtifacts
    )
    await second.commit(secondLease)
  }

  @Test
  func recoveryHoldsExclusiveCacheAccessWhileLoadingFreshReferences() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    let recovery = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let competitor = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    try await recovery.recover {
      do {
        _ = try await competitor.acquireLease(
          for: fixture.fileURL,
          purpose: .remoteDownload,
          abandonPolicy: .retainArtifacts
        )
        Issue.record("Recovery must hold the cross-process cache lease before reading references.")
      } catch let error as RestoreImageCacheError {
        #expect(error == .cacheInUse)
      }
      return []
    }
  }

  @Test
  func abandonPolicySeparatesResumableDownloadsFromPrivateImports() async throws {
    let fixture = try RestoreImageCacheFixture()
    defer { fixture.remove() }
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    let retained = try await service.acquireLease(
      for: fixture.fileURL,
      purpose: .remoteDownload,
      abandonPolicy: .retainArtifacts
    )
    try Data([1]).write(to: retained.fileURL)
    try Data([2]).write(to: retained.partialURL)
    try await service.abandon(retained)

    #expect(FileManager.default.fileExists(atPath: retained.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: retained.partialURL.path))

    let discarded = try await service.acquireLease(
      for: fixture.cacheURL.appending(path: "Imported.ipsw"),
      purpose: .localImport,
      abandonPolicy: .discardArtifacts
    )
    try Data([3]).write(to: discarded.fileURL)
    try Data([4]).write(to: discarded.partialURL)
    try await service.abandon(discarded)

    #expect(!FileManager.default.fileExists(atPath: discarded.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: discarded.partialURL.path))
  }
}

private struct RestoreImageCacheFixture {
  let rootURL: URL
  let cacheURL: URL
  let fileURL: URL

  init(createCache: Bool = false) throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-RestoreCacheTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    cacheURL = rootURL.appending(path: "Cache", directoryHint: .isDirectory)
    fileURL = cacheURL.appending(path: "Restore.ipsw", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: createCache ? cacheURL : rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
