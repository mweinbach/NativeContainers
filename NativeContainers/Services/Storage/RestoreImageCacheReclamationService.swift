import Foundation

protocol RestoreImageCacheStorageReclaiming: Sendable {
  func prepareRestoreImageReclamation() async throws
    -> RestoreImageCacheReclamationPlan

  func reclaimRestoreImages(
    _ plan: RestoreImageCacheReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult
}

protocol RestoreImageCacheReclamationStoring: Sendable {
  func prepareRestoreImageCacheReclamation(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws -> RestoreImageCacheReclamationPlan

  func reclaimRestoreImageCache(
    _ plan: RestoreImageCacheReclamationPlan,
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws -> VirtualMachineStorageReclamationBatchResult
}

struct RestoreImageCacheReclamationService:
  RestoreImageCacheStorageReclaiming
{
  private let store: any RestoreImageCacheReclamationStoring
  private let referencedURLs: @Sendable () async throws -> Set<URL>

  init(
    store: any RestoreImageCacheReclamationStoring,
    referencedURLs: @escaping @Sendable () async throws -> Set<URL>
  ) {
    self.store = store
    self.referencedURLs = referencedURLs
  }

  func prepareRestoreImageReclamation() async throws
    -> RestoreImageCacheReclamationPlan
  {
    try await store.prepareRestoreImageCacheReclamation(
      referencedURLs: referencedURLs
    )
  }

  func reclaimRestoreImages(
    _ plan: RestoreImageCacheReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    try await store.reclaimRestoreImageCache(
      plan,
      referencedURLs: referencedURLs
    )
  }
}

struct UnavailableRestoreImageCacheReclamationService:
  RestoreImageCacheStorageReclaiming
{
  func prepareRestoreImageReclamation() async throws
    -> RestoreImageCacheReclamationPlan
  {
    throw VirtualMachineStorageReclamationError.unavailable
  }

  func reclaimRestoreImages(
    _ plan: RestoreImageCacheReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    throw VirtualMachineStorageReclamationError.unavailable
  }
}
