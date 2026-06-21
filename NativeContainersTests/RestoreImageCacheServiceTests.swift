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

  @Test
  func reclamationPlansOnlyUnreferencedImagesAndAgedPartials() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000)
    let completed = fixture.cacheURL.appending(path: "Completed.ipsw")
    let referenced = fixture.cacheURL.appending(path: "Referenced.ipsw")
    let oldPartial = fixture.cacheURL.appending(path: "Old.ipsw.partial")
    let recentPartial = fixture.cacheURL.appending(path: "Recent.ipsw.partial")
    try writeRestoreImage(at: completed, modifiedAt: now)
    try writeRestoreImage(at: referenced, modifiedAt: now)
    try writeRestoreImage(
      at: oldPartial,
      modifiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
    )
    try writeRestoreImage(
      at: recentPartial,
      modifiedAt: now.addingTimeInterval(-60)
    )
    try Data([9]).write(to: fixture.cacheURL.appending(path: "Unrelated.txt"))
    let service = RestoreImageCacheService(
      cacheDirectoryURL: fixture.cacheURL,
      now: { now }
    )

    let plan = try await service.prepareRestoreImageCacheReclamation {
      [referenced]
    }

    #expect(Set(plan.candidates.map(\.entryName)) == ["Completed.ipsw", "Old.ipsw.partial"])
    #expect(
      Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.entryName, $0.kind) })
        == [
          "Completed.ipsw": .completedImage,
          "Old.ipsw.partial": .abandonedPartial,
        ]
    )
  }

  @Test
  func reclamationRechecksReferencesImmediatelyBeforeDeletion() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    try writeRestoreImage(at: fixture.fileURL)
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let plan = try await service.prepareRestoreImageCacheReclamation { [] }

    let result = try await service.reclaimRestoreImageCache(plan) {
      [fixture.fileURL]
    }

    #expect(result.removedCandidateIDs.isEmpty)
    #expect(result.staleCandidateIDs == plan.candidates.map(\.id))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  @Test
  func reclamationSkipsAFileWhoseReviewedIdentityChanged() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    try writeRestoreImage(at: fixture.fileURL)
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let plan = try await service.prepareRestoreImageCacheReclamation { [] }

    try FileManager.default.removeItem(at: fixture.fileURL)
    try Data([4, 5, 6, 7]).write(to: fixture.fileURL)
    let result = try await service.reclaimRestoreImageCache(plan) { [] }

    #expect(result.removedCandidateIDs.isEmpty)
    #expect(result.staleCandidateIDs == plan.candidates.map(\.id))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  @Test
  func reclamationRetiresAndDeletesTheExactReviewedImage() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    try writeRestoreImage(at: fixture.fileURL)
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let plan = try await service.prepareRestoreImageCacheReclamation { [] }

    let result = try await service.reclaimRestoreImageCache(plan) { [] }

    #expect(result.removedCandidateIDs == plan.candidates.map(\.id))
    #expect(result.staleCandidateIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    let entries = try FileManager.default.contentsOfDirectory(
      at: fixture.cacheURL,
      includingPropertiesForKeys: nil
    )
    #expect(
      entries.allSatisfy {
        !$0.lastPathComponent.hasPrefix(
          RestoreImageCacheService.reclamationTombstonePrefix
        )
      }
    )
  }

  @Test
  func reclamationPreservesUnsafeMatchingArtifactsAsPlanningIssues() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    let realFile = fixture.cacheURL.appending(path: "Real.data")
    try Data([1]).write(to: realFile)
    let symbolicImage = fixture.cacheURL.appending(path: "Symbolic.ipsw")
    try FileManager.default.createSymbolicLink(
      at: symbolicImage,
      withDestinationURL: realFile
    )
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    let plan = try await service.prepareRestoreImageCacheReclamation { [] }

    #expect(plan.candidates.isEmpty)
    #expect(plan.issues.count == 1)
    #expect(FileManager.default.fileExists(atPath: symbolicImage.path))
  }

  @Test
  func activeAcquisitionBlocksReclamationPlanning() async throws {
    let fixture = try RestoreImageCacheFixture()
    defer { fixture.remove() }
    let owner = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)
    let lease = try await owner.acquireLease(
      for: fixture.fileURL,
      purpose: .remoteDownload,
      abandonPolicy: .retainArtifacts
    )
    let reclaimer = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      _ = try await reclaimer.prepareRestoreImageCacheReclamation { [] }
    }

    try await owner.abandon(lease)
  }

  @Test
  func recoveryFinishesADeletionCommittedBeforeProcessExit() async throws {
    let fixture = try RestoreImageCacheFixture(createCache: true)
    defer { fixture.remove() }
    let tombstone = fixture.cacheURL.appending(
      path:
        "\(RestoreImageCacheService.reclamationTombstonePrefix)\(UUID().uuidString.lowercased())\(RestoreImageCacheService.reclamationTombstoneSuffix)"
    )
    try Data([1, 2, 3]).write(to: tombstone)
    let service = RestoreImageCacheService(cacheDirectoryURL: fixture.cacheURL)

    try await service.recover { [] }

    #expect(!FileManager.default.fileExists(atPath: tombstone.path))
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

private func writeRestoreImage(
  at url: URL,
  modifiedAt: Date = .now
) throws {
  try Data([1, 2, 3]).write(to: url)
  try FileManager.default.setAttributes(
    [.modificationDate: modifiedAt],
    ofItemAtPath: url.path
  )
}
