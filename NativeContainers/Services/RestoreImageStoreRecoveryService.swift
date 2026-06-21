import Foundation

protocol RestoreImageStoreRecovering: Sendable {
  func recover() async throws
}

struct RestoreImageStoreRecoveryService: RestoreImageStoreRecovering {
  private let legacyCache: any RestoreImageCacheManaging
  private let currentCache: any RestoreImageCacheManaging
  private let migration: any RestoreImageStoreMigrating
  private let references: any VirtualMachineRestoreImageReferenceStoring

  init(
    legacyCache: any RestoreImageCacheManaging,
    currentCache: any RestoreImageCacheManaging,
    migration: any RestoreImageStoreMigrating,
    references: any VirtualMachineRestoreImageReferenceStoring
  ) {
    self.legacyCache = legacyCache
    self.currentCache = currentCache
    self.migration = migration
    self.references = references
  }

  func recover() async throws {
    try await legacyCache.recover {
      try await references.loadRestoreImageReferences()
    }
    _ = try await migration.migrateLegacyReferences()
    try await currentCache.recover {
      try await references.loadRestoreImageReferences()
    }
  }
}

struct NoopRestoreImageStoreRecoveryService: RestoreImageStoreRecovering {
  func recover() async throws {}
}
