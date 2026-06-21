import Foundation

struct AppOwnedBuildCacheSnapshot: Equatable, Sendable {
  let byteCount: Int64
  let entryCount: Int
  let maintenanceWarning: String?

  init(
    byteCount: Int64,
    entryCount: Int,
    maintenanceWarning: String? = nil
  ) {
    self.byteCount = byteCount
    self.entryCount = entryCount
    self.maintenanceWarning = maintenanceWarning
  }
}

struct AppOwnedBuildCacheResetReceipt: Equatable, Sendable {
  let maintenanceWarning: String?

  init(maintenanceWarning: String? = nil) {
    self.maintenanceWarning = maintenanceWarning
  }
}

struct AppOwnedBuildCachePreparedExport: Equatable, Sendable {
  let snapshot: AppOwnedBuildCacheSnapshot
  let handoffToken: UUID
  let fingerprintSHA256: String
}

struct ReviewedAppOwnedBuildCacheExport: Sendable {
  let snapshot: AppOwnedBuildCacheSnapshot
  let directoryIdentity: AppOwnedBuildCacheDirectoryIdentity
  let fingerprintSHA256: String
}

struct AppOwnedBuildCacheLayoutIdentity: Equatable, Sendable {
  let layoutSHA256: String
  let indexSHA256: String
}

struct AppOwnedBuildCacheTreeIdentity: Equatable, Sendable {
  let snapshot: AppOwnedBuildCacheSnapshot
  let metadataSHA256: String
}

struct AppOwnedBuildCacheDirectoryIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
  let permissions: UInt16
}

enum AppOwnedBuildCacheStoreError: LocalizedError, Equatable, Sendable {
  case unsafeRoot(String)
  case unsafeCache(String)
  case missingExport(String)
  case tooManyEntries
  case tooLarge
  case invalidHandoff
  case ioFailure(operation: String, path: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .unsafeRoot(let path):
      "The app-owned build cache root is not private at \(path)."
    case .unsafeCache(let path):
      "The app-owned build cache has an unsafe entry at \(path)."
    case .missingExport(let path):
      "BuildKit did not create the requested local cache export at \(path)."
    case .tooManyEntries:
      "The app-owned build cache exceeds the safe entry limit."
    case .tooLarge:
      "The app-owned build cache exceeds the safe size limit."
    case .invalidHandoff:
      "The prepared app-owned cache no longer matches the worker receipt."
    case .ioFailure(let operation, let path, let code):
      "App-owned build cache \(operation) failed at \(path) (errno \(code))."
    }
  }
}

final class AppOwnedBuildCacheLease: @unchecked Sendable {
  let hasImportableCache: Bool

  private let stateLock = NSLock()
  private let store: AppOwnedBuildCacheStore
  private let buildID: UUID
  private var descriptor: Int32?

  init(
    store: AppOwnedBuildCacheStore,
    buildID: UUID,
    descriptor: Int32,
    hasImportableCache: Bool
  ) {
    self.store = store
    self.buildID = buildID
    self.descriptor = descriptor
    self.hasImportableCache = hasImportableCache
  }

  func commit() throws -> AppOwnedBuildCacheSnapshot {
    try stateLock.withLock {
      guard let descriptor else {
        throw AppOwnedBuildCacheStoreError.unsafeCache("cache lease already released")
      }
      do {
        let snapshot = try store.commitExportWhileLocked(buildID: buildID)
        store.releaseLock(descriptor)
        self.descriptor = nil
        return snapshot
      } catch {
        store.abandonExportWhileLocked(buildID: buildID)
        store.releaseLock(descriptor)
        self.descriptor = nil
        throw error
      }
    }
  }

  func prepareForHostCommit() throws -> AppOwnedBuildCachePreparedExport {
    try stateLock.withLock {
      guard let descriptor else {
        throw AppOwnedBuildCacheStoreError.unsafeCache("cache lease already released")
      }
      do {
        let prepared = try store.prepareExportForHostCommitWhileLocked(buildID: buildID)
        store.releaseLock(descriptor)
        self.descriptor = nil
        return prepared
      } catch {
        store.abandonExportWhileLocked(buildID: buildID)
        store.releaseLock(descriptor)
        self.descriptor = nil
        throw error
      }
    }
  }

  func release() {
    stateLock.withLock {
      guard let descriptor else { return }
      store.abandonExportWhileLocked(buildID: buildID)
      store.releaseLock(descriptor)
      self.descriptor = nil
    }
  }

  deinit {
    release()
  }
}
