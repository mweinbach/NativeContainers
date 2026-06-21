import Foundation
import Testing

@testable import NativeContainers

struct RestoreImageStoreMigrationServiceTests {
  @Test
  func standardLocationUsesApplicationSupportAndRetainsTheLegacyCacheRoot() {
    let locations = RestoreImageStoreLocations.standard()

    #expect(
      locations.current.path.contains("/Library/Application Support/NativeContainers/")
    )
    #expect(locations.current.lastPathComponent == "Restore Images")
    #expect(locations.legacyCache.path.contains("/Library/Caches/NativeContainers/"))
    #expect(locations.current != locations.legacyCache)
  }

  @Test
  func migratesEverySharedReferenceAndRetainsTheLegacySource() async throws {
    let fixture = try MigrationFixture(referenceCount: 2)
    defer { fixture.remove() }

    let report = try await fixture.service.migrateLegacyReferences()
    let references = await fixture.references.currentReferences
    let destination = try #require(references.first)

    #expect(report.migratedArtifactCount == 1)
    #expect(report.updatedManifestCount == 2)
    #expect(report.retainedLegacyArtifactCount == 1)
    #expect(references.count == 1)
    #expect(destination.deletingLastPathComponent() == fixture.locations.current)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: destination) == MigrationFixture.payload)

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    #expect(
      try destination.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)
    #expect(try fixture.migrationControlFiles().isEmpty)

    #expect(
      try await fixture.service.migrateLegacyReferences()
        == RestoreImageStoreMigrationReport.empty
    )
  }

  @Test
  func resumesAfterAPartialManifestRewriteWithoutDanglingEitherReference() async throws {
    let fixture = try MigrationFixture(
      referenceCount: 2,
      failFirstMigrationAfterUpdates: 1
    )
    defer { fixture.remove() }

    await #expect(throws: MigrationFixtureError.injectedFailure) {
      _ = try await fixture.service.migrateLegacyReferences()
    }

    let partialReferences = await fixture.references.referencesByMachine
    #expect(Set(partialReferences.values).count == 2)
    for reference in partialReferences.values {
      #expect(FileManager.default.fileExists(atPath: reference.path))
    }
    #expect(try fixture.migrationControlFiles().count == 1)

    let report = try await fixture.service.migrateLegacyReferences()
    let recoveredReferences = await fixture.references.currentReferences
    let destination = try #require(recoveredReferences.first)

    #expect(report.migratedArtifactCount == 1)
    #expect(report.updatedManifestCount == 1)
    #expect(recoveredReferences == [destination])
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try fixture.migrationControlFiles().isEmpty)
  }

  @Test
  func discardsAStaleJournalAfterTheReferencingMachinesAreDeleted() async throws {
    let fixture = try MigrationFixture(
      referenceCount: 2,
      failFirstMigrationAfterUpdates: 1
    )
    defer { fixture.remove() }

    await #expect(throws: MigrationFixtureError.injectedFailure) {
      _ = try await fixture.service.migrateLegacyReferences()
    }
    await fixture.references.removeAllReferences()
    try FileManager.default.removeItem(at: fixture.sourceURL)

    #expect(
      try await fixture.service.migrateLegacyReferences()
        == RestoreImageStoreMigrationReport.empty
    )
    #expect(try fixture.currentRestoreImages().isEmpty)
    #expect(try fixture.migrationControlFiles().isEmpty)
  }

  @Test
  func staleJournalRetainsItsRecordWhenAnArtifactWasReplaced() async throws {
    let fixture = try MigrationFixture(
      referenceCount: 2,
      failFirstMigrationAfterUpdates: 1
    )
    defer { fixture.remove() }

    await #expect(throws: MigrationFixtureError.injectedFailure) {
      _ = try await fixture.service.migrateLegacyReferences()
    }
    let destination = try #require(fixture.currentRestoreImages().first)
    try FileManager.default.removeItem(at: destination)
    let replacement = Data("replacement".utf8)
    try replacement.write(to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    await fixture.references.removeAllReferences()
    try FileManager.default.removeItem(at: fixture.sourceURL)

    #expect(
      try await fixture.service.migrateLegacyReferences()
        == RestoreImageStoreMigrationReport.empty
    )
    #expect(try Data(contentsOf: destination) == replacement)
    #expect(try fixture.migrationJournalFiles().count == 1)
  }

  @Test
  func stalePlannedJournalRetainsAnUnsealedPartialForReviewedReclamation() async throws {
    let fixture = try MigrationFixture(
      referenceCount: 1,
      copier: PartialFailingRestoreImageMigrationCopier()
    )
    defer { fixture.remove() }

    await #expect(throws: MigrationFixtureError.injectedCopyFailure) {
      _ = try await fixture.service.migrateLegacyReferences()
    }
    await fixture.references.removeAllReferences()

    #expect(
      try await fixture.service.migrateLegacyReferences()
        == RestoreImageStoreMigrationReport.empty
    )
    let staging = try #require(fixture.migrationStagingFiles().first)
    #expect(try Data(contentsOf: staging) == PartialFailingRestoreImageMigrationCopier.payload)
    #expect(try fixture.migrationJournalFiles().count == 1)
  }

  @Test
  func leavesUnreferencedLegacyImagesInPlaceForReviewedReclamation() async throws {
    let fixture = try MigrationFixture(referenceCount: 0)
    defer { fixture.remove() }

    let report = try await fixture.service.migrateLegacyReferences()

    #expect(report == .empty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(try fixture.currentRestoreImages().isEmpty)
  }

  @Test
  func missingReferencedLegacyImageFailsBeforeChangingTheManifest() async throws {
    let fixture = try MigrationFixture(referenceCount: 1, createsSource: false)
    defer { fixture.remove() }

    await #expect(
      throws: RestoreImageStoreMigrationError.missingLegacyArtifact(
        fixture.sourceURL
      )
    ) {
      _ = try await fixture.service.migrateLegacyReferences()
    }

    #expect(await fixture.references.currentReferences == [fixture.sourceURL])
    #expect(try fixture.currentRestoreImages().isEmpty)
  }

  @Test
  func activePrimaryLeaseDefersMigrationWithoutChangingReferences() async throws {
    let fixture = try MigrationFixture(referenceCount: 1)
    defer { fixture.remove() }
    let busyURL = fixture.locations.current.appending(path: "Busy.ipsw")
    let lease = try await fixture.currentStore.acquireLease(
      for: busyURL,
      purpose: .existingCachedImage,
      abandonPolicy: .retainArtifacts
    )

    await #expect(throws: RestoreImageCacheError.cacheInUse) {
      _ = try await fixture.service.migrateLegacyReferences()
    }
    #expect(await fixture.references.currentReferences == [fixture.sourceURL])

    try await fixture.currentStore.abandon(lease)
  }

  @Test
  func recoveryServiceRunsMaintenanceOnlyForLegacyReferences() async throws {
    let fixture = try MigrationFixture(referenceCount: 1)
    defer { fixture.remove() }
    let recovery = RestoreImageStoreRecoveryService(
      locations: fixture.locations,
      legacyCache: fixture.legacyStore,
      currentCache: fixture.currentStore,
      migration: fixture.service,
      references: fixture.references
    )

    #expect(
      try await recovery.recoverLegacyReferencesIfNeeded([fixture.sourceURL])
    )
    let migratedReferences = await fixture.references.currentReferences
    #expect(migratedReferences.count == 1)
    #expect(
      try await recovery.recoverLegacyReferencesIfNeeded(migratedReferences)
        == false
    )
  }
}

private struct MigrationFixture {
  static let payload = Data("restore-image".utf8)

  let rootURL: URL
  let locations: RestoreImageStoreLocations
  let sourceURL: URL
  let legacyStore: RestoreImageCacheService
  let currentStore: RestoreImageCacheService
  let references: MigrationReferenceStore
  let service: RestoreImageStoreMigrationService

  init(
    referenceCount: Int,
    createsSource: Bool = true,
    failFirstMigrationAfterUpdates: Int? = nil,
    copier: any RestoreImageMigrationCopying = CopyfileRestoreImageMigrationCopier()
  ) throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    self.rootURL = rootURL
    let locations = RestoreImageStoreLocations(
      current: rootURL.appending(
        path: "Application Support/Restore Images",
        directoryHint: .isDirectory
      ),
      legacyCache: rootURL.appending(
        path: "Caches/Restore Images",
        directoryHint: .isDirectory
      )
    )
    self.locations = locations
    let sourceURL = locations.legacyCache.appending(path: "Legacy.ipsw")
    self.sourceURL = sourceURL
    try FileManager.default.createDirectory(
      at: locations.legacyCache,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if createsSource {
      try Self.payload.write(to: sourceURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: sourceURL.path
      )
    }

    legacyStore = RestoreImageCacheService(
      cacheDirectoryURL: locations.legacyCache,
      excludesFromBackup: false
    )
    currentStore = RestoreImageCacheService(
      cacheDirectoryURL: locations.current,
      excludesFromBackup: true
    )
    references = MigrationReferenceStore(
      references: Dictionary(
        uniqueKeysWithValues: (0..<referenceCount).map { _ in
          (UUID(), sourceURL)
        }
      ),
      failFirstMigrationAfterUpdates: failFirstMigrationAfterUpdates
    )
    service = RestoreImageStoreMigrationService(
      locations: locations,
      legacyStore: legacyStore,
      currentStore: currentStore,
      references: references,
      copier: copier
    )
  }

  func migrationControlFiles() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: locations.current.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(
      at: locations.current,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(
        RestoreImageStoreMigrationService.journalPrefix
      )
    }
  }

  func currentRestoreImages() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: locations.current.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(
      at: locations.current,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "ipsw" }
  }

  func migrationJournalFiles() throws -> [URL] {
    try migrationControlFiles().filter {
      $0.lastPathComponent.hasSuffix(
        RestoreImageStoreMigrationService.journalSuffix
      )
    }
  }

  func migrationStagingFiles() throws -> [URL] {
    try migrationControlFiles().filter {
      $0.lastPathComponent.hasSuffix(
        RestoreImageStoreMigrationService.stagingSuffix
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private actor MigrationReferenceStore:
  VirtualMachineRestoreImageReferenceStoring
{
  private(set) var referencesByMachine: [UUID: URL]
  private let failFirstMigrationAfterUpdates: Int?
  private var hasInjectedFailure = false

  init(
    references: [UUID: URL],
    failFirstMigrationAfterUpdates: Int?
  ) {
    referencesByMachine = references
    self.failFirstMigrationAfterUpdates = failFirstMigrationAfterUpdates
  }

  var currentReferences: Set<URL> {
    Set(referencesByMachine.values)
  }

  func loadRestoreImageReferences() -> Set<URL> {
    currentReferences
  }

  func migrateRestoreImageReferences(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> Int {
    var updateCount = 0
    for machineID in referencesByMachine.keys.sorted(by: {
      $0.uuidString < $1.uuidString
    })
    where referencesByMachine[machineID]?.standardizedFileURL
      == sourceURL.standardizedFileURL
    {
      referencesByMachine[machineID] = destinationURL
      updateCount += 1
      if !hasInjectedFailure,
        let failFirstMigrationAfterUpdates,
        updateCount >= failFirstMigrationAfterUpdates
      {
        hasInjectedFailure = true
        throw MigrationFixtureError.injectedFailure
      }
    }
    return updateCount
  }

  func removeAllReferences() {
    referencesByMachine.removeAll()
  }
}

private enum MigrationFixtureError: Error, Equatable {
  case injectedFailure
  case injectedCopyFailure
}

private struct PartialFailingRestoreImageMigrationCopier:
  RestoreImageMigrationCopying
{
  static let payload = Data("partial-restore-image".utf8)

  func copy(from sourceURL: URL, to destinationURL: URL) async throws {
    try Self.payload.write(to: destinationURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    throw MigrationFixtureError.injectedCopyFailure
  }
}
