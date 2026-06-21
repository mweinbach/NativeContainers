import ContainerAPIClient
import Foundation

protocol AppOwnedBuildCacheRootLoading: Sendable {
  func loadSharedExportRoot() async throws -> URL
}

struct AppleAppOwnedBuildCacheRootLoader: AppOwnedBuildCacheRootLoading {
  func loadSharedExportRoot() async throws -> URL {
    do {
      let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
      return health.appRoot.appending(path: "builder", directoryHint: .isDirectory)
    } catch {
      throw AppOwnedBuildCacheManagementError.runtimeUnavailable(
        error.localizedDescription
      )
    }
  }
}

protocol AppOwnedBuildCacheManaging: Sendable {
  func loadCache() async throws -> AppOwnedBuildCacheSnapshot?
  func resetCache() async throws -> AppOwnedBuildCacheResetReceipt
}

actor AppleAppOwnedBuildCacheService: AppOwnedBuildCacheManaging {
  private let rootLoader: any AppOwnedBuildCacheRootLoading
  private let buildExecutionCoordinator: RuntimeMutationCoordinator

  init(
    rootLoader: any AppOwnedBuildCacheRootLoading = AppleAppOwnedBuildCacheRootLoader(),
    buildExecutionCoordinator: RuntimeMutationCoordinator = .imageBuilds
  ) {
    self.rootLoader = rootLoader
    self.buildExecutionCoordinator = buildExecutionCoordinator
  }

  func loadCache() async throws -> AppOwnedBuildCacheSnapshot? {
    let root = try await rootLoader.loadSharedExportRoot()
    return try await AppOwnedBuildCacheStore(sharedExportRoot: root).inspect()
  }

  func resetCache() async throws -> AppOwnedBuildCacheResetReceipt {
    try await buildExecutionCoordinator.perform { [rootLoader] in
      let root = try await rootLoader.loadSharedExportRoot()
      return try await AppOwnedBuildCacheStore(sharedExportRoot: root).reset()
    }
  }
}

protocol ImageBuildCacheFinalizing: Sendable {
  func commitPreparedCache(
    _ receipt: ContainerBuildWorkerCacheReceipt,
    buildID: UUID
  ) async throws -> AppOwnedBuildCacheSnapshot
  func discardPreparedCache(buildID: UUID) async
}

struct AppleImageBuildCacheFinalizationService: ImageBuildCacheFinalizing {
  private let rootLoader: any AppOwnedBuildCacheRootLoading

  init(
    rootLoader: any AppOwnedBuildCacheRootLoading = AppleAppOwnedBuildCacheRootLoader()
  ) {
    self.rootLoader = rootLoader
  }

  func commitPreparedCache(
    _ receipt: ContainerBuildWorkerCacheReceipt,
    buildID: UUID
  ) async throws -> AppOwnedBuildCacheSnapshot {
    guard
      receipt.mode == .appOwnedLocalV1,
      receipt.state == .staged,
      receipt.schemaVersion == ContainerBuildWorkerCacheReceipt.currentSchemaVersion,
      receipt.fingerprintSHA256.count == 64,
      receipt.fingerprintSHA256.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }),
      receipt.byteCount > 0,
      receipt.entryCount > 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache("invalid worker cache receipt")
    }
    let root = try await rootLoader.loadSharedExportRoot()
    return try await AppOwnedBuildCacheStore(sharedExportRoot: root).commitPreparedExport(
      buildID: buildID,
      handoffToken: receipt.handoffToken,
      expectedSnapshot: AppOwnedBuildCacheSnapshot(
        byteCount: receipt.byteCount,
        entryCount: receipt.entryCount
      ),
      expectedFingerprintSHA256: receipt.fingerprintSHA256
    )
  }

  func discardPreparedCache(buildID: UUID) async {
    guard let root = try? await rootLoader.loadSharedExportRoot() else { return }
    try? await AppOwnedBuildCacheStore(sharedExportRoot: root).discardPreparedExport(
      buildID: buildID
    )
  }
}

enum AppOwnedBuildCacheManagementError: LocalizedError, Equatable, Sendable {
  case runtimeUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .runtimeUnavailable(let message):
      "Could not locate Apple’s builder export root. \(message)"
    }
  }
}
