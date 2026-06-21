import Foundation

protocol RestoreImageStoreRecovering: Sendable {
  func recover() async throws

  @discardableResult
  func recoverLegacyReferencesIfNeeded(
    _ referencedURLs: Set<URL>
  ) async throws -> Bool
}

extension RestoreImageStoreRecovering {
  func recoverLegacyReferencesIfNeeded(
    _ referencedURLs: Set<URL>
  ) async throws -> Bool {
    false
  }
}

struct RestoreImageStoreRecoveryService: RestoreImageStoreRecovering {
  private let locations: RestoreImageStoreLocations
  private let legacyCache: any RestoreImageCacheManaging
  private let currentCache: any RestoreImageCacheManaging
  private let migration: any RestoreImageStoreMigrating
  private let references: any VirtualMachineRestoreImageReferenceStoring

  init(
    locations: RestoreImageStoreLocations = .standard(),
    legacyCache: any RestoreImageCacheManaging,
    currentCache: any RestoreImageCacheManaging,
    migration: any RestoreImageStoreMigrating,
    references: any VirtualMachineRestoreImageReferenceStoring
  ) {
    self.locations = locations
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

  func recoverLegacyReferencesIfNeeded(
    _ referencedURLs: Set<URL>
  ) async throws -> Bool {
    let legacyComponents = locations.legacyCache.standardizedFileURL.pathComponents
    guard
      referencedURLs.contains(where: {
        let components = $0.standardizedFileURL.pathComponents
        return components.count >= legacyComponents.count
          && components.prefix(legacyComponents.count).elementsEqual(legacyComponents)
      })
    else {
      return false
    }
    try await recover()
    return true
  }
}

struct NoopRestoreImageStoreRecoveryService: RestoreImageStoreRecovering {
  func recover() async throws {}
}
