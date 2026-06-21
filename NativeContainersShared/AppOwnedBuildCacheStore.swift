import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func nativeBuildCacheFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

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

private struct ReviewedAppOwnedBuildCacheExport: Sendable {
  let snapshot: AppOwnedBuildCacheSnapshot
  let directoryIdentity: AppOwnedBuildCacheDirectoryIdentity
  let fingerprintSHA256: String
}

private struct AppOwnedBuildCacheLayoutIdentity: Equatable, Sendable {
  let layoutSHA256: String
  let indexSHA256: String
}

private struct AppOwnedBuildCacheTreeIdentity: Equatable, Sendable {
  let snapshot: AppOwnedBuildCacheSnapshot
  let metadataSHA256: String
}

private struct AppOwnedBuildCacheDirectoryIdentity: Equatable, Sendable {
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

  fileprivate init(
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

struct AppOwnedBuildCacheStore: Sendable {
  static let namespaceDirectoryName = "nativecontainers-cache-v1"
  static let currentDirectoryName = "current"
  static let stagingDirectoryName = "staging"
  static let preparedDirectoryName = "prepared"

  private static let lockFileName = ".lock"
  private static let maximumEntryCount = 1_000_000
  private static let maximumByteCount: Int64 = 512 * 1_024 * 1_024 * 1_024
  private static let maximumIndexBytes: Int64 = 16 * 1_024 * 1_024
  private static let maximumLayoutBytes: Int64 = 4 * 1_024
  private static let maximumDescriptorBytes: Int64 = 64 * 1_024 * 1_024
  private static let maximumDirectoryDepth = 128
  private static let preparedHandoffLifetime: TimeInterval = 24 * 60 * 60

  let sharedExportRoot: URL

  init(sharedExportRoot: URL) {
    self.sharedExportRoot = sharedExportRoot.standardizedFileURL
  }

  func acquireLease(
    policy: ImageBuildCachePolicy,
    buildID: UUID
  ) async throws -> AppOwnedBuildCacheLease? {
    guard policy == .appOwnedLocalV1 else { return nil }
    let descriptor = try await acquireExclusiveLock()
    do {
      try recoverInterruptedTransactions()
      try removeIfPresent(stagingURL(buildID: buildID), within: stagingRoot)
      return AppOwnedBuildCacheLease(
        store: self,
        buildID: buildID,
        descriptor: descriptor,
        hasImportableCache: try validateCurrentCacheIfPresent()
      )
    } catch {
      releaseLock(descriptor)
      throw error
    }
  }

  func inspect() async throws -> AppOwnedBuildCacheSnapshot? {
    guard try entryExists(sharedExportRoot), try entryExists(namespaceRoot) else {
      return nil
    }
    let descriptor = try await acquireExclusiveLock()
    defer { releaseLock(descriptor) }
    try recoverInterruptedTransactions()
    guard try validateCurrentCacheIfPresent() else { return nil }
    return try measureCache(at: currentURL)
  }

  func reset() async throws -> AppOwnedBuildCacheResetReceipt {
    guard try entryExists(sharedExportRoot), try entryExists(namespaceRoot) else {
      return AppOwnedBuildCacheResetReceipt()
    }
    let descriptor = try await acquireExclusiveLock()
    defer { releaseLock(descriptor) }
    try recoverInterruptedTransactions()
    try Task.checkCancellation()

    var warnings = try retirePreparedExportsWhileLocked()
    guard try validateOwnedCurrentBoundaryIfPresent() else {
      return AppOwnedBuildCacheResetReceipt(
        maintenanceWarning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
      )
    }

    let tombstoneName = ".reset-\(UUID().uuidString.lowercased())"
    let namespaceDescriptor = try openDirectoryDescriptor(namespaceRoot)
    defer { Darwin.close(namespaceDescriptor) }
    let renameResult = Self.currentDirectoryName.withCString { currentPointer in
      tombstoneName.withCString { tombstonePointer in
        Darwin.renameatx_np(
          namespaceDescriptor,
          currentPointer,
          namespaceDescriptor,
          tombstonePointer,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      throw posixError("retire cache", currentURL)
    }

    if Darwin.fsync(namespaceDescriptor) != 0 {
      warnings.append(
        "The cache reset committed but its directory sync failed (errno \(errno))."
      )
    }
    do {
      try removeIfPresent(
        namespaceRoot.appending(path: tombstoneName, directoryHint: .isDirectory),
        within: namespaceRoot
      )
    } catch {
      warnings.append("The retired cache remains on disk and will be removed on recovery.")
    }
    return AppOwnedBuildCacheResetReceipt(
      maintenanceWarning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
    )
  }

  func commitPreparedExport(
    buildID: UUID,
    handoffToken: UUID,
    expectedSnapshot: AppOwnedBuildCacheSnapshot,
    expectedFingerprintSHA256: String
  ) async throws -> AppOwnedBuildCacheSnapshot {
    let source = preparedURL(buildID: buildID, handoffToken: handoffToken)
    guard try entryExists(sharedExportRoot), try entryExists(namespaceRoot) else {
      throw AppOwnedBuildCacheStoreError.missingExport(
        source.path(percentEncoded: false)
      )
    }
    let descriptor = try await acquireExclusiveLock()
    defer { releaseLock(descriptor) }
    try recoverInterruptedTransactions()
    try Task.checkCancellation()
    let reviewed = try reviewExport(at: source, within: preparedRoot)
    guard
      reviewed.snapshot.byteCount == expectedSnapshot.byteCount,
      reviewed.snapshot.entryCount == expectedSnapshot.entryCount,
      reviewed.fingerprintSHA256 == expectedFingerprintSHA256
    else {
      try? removeIfPresent(source, within: preparedRoot)
      throw AppOwnedBuildCacheStoreError.invalidHandoff
    }
    try Task.checkCancellation()
    return try publishExportWhileLocked(
      source: source,
      sourceRoot: preparedRoot,
      sourceName: preparedDirectoryName(buildID: buildID, handoffToken: handoffToken),
      reviewed: reviewed
    )
  }

  func discardPreparedExport(buildID: UUID) async throws {
    guard try entryExists(sharedExportRoot), try entryExists(namespaceRoot) else {
      return
    }
    let descriptor = try await acquireExclusiveLock()
    defer { releaseLock(descriptor) }
    try removeIfPresent(stagingURL(buildID: buildID), within: stagingRoot)
    for entry in try preparedExportURLs(buildID: buildID) {
      try removeIfPresent(entry, within: preparedRoot)
    }
  }

  fileprivate func releaseLock(_ descriptor: Int32) {
    _ = nativeBuildCacheFlock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  fileprivate func abandonExportWhileLocked(buildID: UUID) {
    try? removeIfPresent(stagingURL(buildID: buildID), within: stagingRoot)
  }

  fileprivate func commitExportWhileLocked(
    buildID: UUID
  ) throws -> AppOwnedBuildCacheSnapshot {
    let reviewed = try reviewExportWhileLocked(buildID: buildID)
    return try publishExportWhileLocked(
      source: stagingURL(buildID: buildID),
      sourceRoot: stagingRoot,
      sourceName: buildID.uuidString.lowercased(),
      reviewed: reviewed
    )
  }

  fileprivate func prepareExportForHostCommitWhileLocked(
    buildID: UUID
  ) throws -> AppOwnedBuildCachePreparedExport {
    _ = try reviewExportWhileLocked(buildID: buildID)
    let handoffToken = UUID()
    let source = stagingURL(buildID: buildID)
    let destination = preparedURL(buildID: buildID, handoffToken: handoffToken)
    let sourceName = buildID.uuidString.lowercased()
    let destinationName = preparedDirectoryName(
      buildID: buildID,
      handoffToken: handoffToken
    )
    let stagingDescriptor = try openDirectoryDescriptor(stagingRoot)
    defer { Darwin.close(stagingDescriptor) }
    let preparedDescriptor = try openDirectoryDescriptor(preparedRoot)
    defer { Darwin.close(preparedDescriptor) }
    let namespaceDescriptor = try openDirectoryDescriptor(namespaceRoot)
    defer { Darwin.close(namespaceDescriptor) }

    try Task.checkCancellation()
    let renameResult = sourceName.withCString { sourcePointer in
      destinationName.withCString { destinationPointer in
        Darwin.renameatx_np(
          stagingDescriptor,
          sourcePointer,
          preparedDescriptor,
          destinationPointer,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      throw posixError("prepare cache handoff", source)
    }

    do {
      try Task.checkCancellation()
      try touchPreparedExport(destination)
      let prepared = try reviewExport(at: destination, within: preparedRoot)
      guard Darwin.fsync(stagingDescriptor) == 0 else {
        throw posixError("sync cache staging", stagingRoot)
      }
      guard Darwin.fsync(preparedDescriptor) == 0 else {
        throw posixError("sync prepared cache", preparedRoot)
      }
      guard Darwin.fsync(namespaceDescriptor) == 0 else {
        throw posixError("sync cache namespace", namespaceRoot)
      }
      return AppOwnedBuildCachePreparedExport(
        snapshot: prepared.snapshot,
        handoffToken: handoffToken,
        fingerprintSHA256: prepared.fingerprintSHA256
      )
    } catch {
      try? removeIfPresent(destination, within: preparedRoot)
      throw error
    }
  }

  fileprivate func reviewExportWhileLocked(
    buildID: UUID
  ) throws -> ReviewedAppOwnedBuildCacheExport {
    try reviewExport(at: stagingURL(buildID: buildID), within: stagingRoot)
  }

  private func reviewExport(
    at source: URL,
    within parent: URL
  ) throws -> ReviewedAppOwnedBuildCacheExport {
    do {
      try validateDirectory(
        source,
        missing: .missingExport(source.path(percentEncoded: false)),
        allowsSharedRead: true
      )
      try secureExportRoot(source)
      let identity = try cacheDirectoryIdentity(source)
      let firstLayoutIdentity = try validateCacheLayout(source)
      let firstTreeIdentity = try inspectCacheTree(at: source)
      let layoutIdentity = try validateCacheLayout(source)
      let treeIdentity = try inspectCacheTree(at: source)
      guard try cacheDirectoryIdentity(source) == identity else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(
          source.path(percentEncoded: false)
        )
      }
      guard
        layoutIdentity == firstLayoutIdentity,
        treeIdentity == firstTreeIdentity
      else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(
          source.path(percentEncoded: false)
        )
      }
      return ReviewedAppOwnedBuildCacheExport(
        snapshot: treeIdentity.snapshot,
        directoryIdentity: identity,
        fingerprintSHA256: cacheFingerprint(
          directoryIdentity: identity,
          layoutIdentity: layoutIdentity,
          treeIdentity: treeIdentity
        )
      )
    } catch {
      try? removeIfPresent(source, within: parent)
      throw error
    }
  }

  private func publishExportWhileLocked(
    source: URL,
    sourceRoot: URL,
    sourceName: String,
    reviewed: ReviewedAppOwnedBuildCacheExport
  ) throws -> AppOwnedBuildCacheSnapshot {
    guard try cacheDirectoryIdentity(source) == reviewed.directoryIdentity else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        source.path(percentEncoded: false)
      )
    }
    let currentExists = try validateCurrentCacheIfPresent()
    let namespaceDescriptor = try openDirectoryDescriptor(namespaceRoot)
    defer { Darwin.close(namespaceDescriptor) }
    let sourceDescriptor = try openDirectoryDescriptor(sourceRoot)
    defer { Darwin.close(sourceDescriptor) }
    let renameResult = sourceName.withCString { sourcePointer in
      Self.currentDirectoryName.withCString { currentPointer in
        Darwin.renameatx_np(
          sourceDescriptor,
          sourcePointer,
          namespaceDescriptor,
          currentPointer,
          UInt32(currentExists ? RENAME_SWAP : RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      let error = posixError("publish cache", source)
      try? removeIfPresent(source, within: sourceRoot)
      throw error
    }

    var warnings: [String] = []
    if Darwin.fsync(namespaceDescriptor) != 0 {
      warnings.append(
        "The cache promotion committed but its directory sync failed (errno \(errno)).")
    }
    if Darwin.fsync(sourceDescriptor) != 0 {
      warnings.append(
        "The cache promotion committed but its source directory sync failed (errno \(errno)).")
    }
    if currentExists, fileExists(source) {
      do {
        try removeIfPresent(source, within: sourceRoot)
      } catch {
        warnings.append("The retired prior cache remains on disk and can be removed with Reset.")
      }
    }
    return AppOwnedBuildCacheSnapshot(
      byteCount: reviewed.snapshot.byteCount,
      entryCount: reviewed.snapshot.entryCount,
      maintenanceWarning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
    )
  }

  private var namespaceRoot: URL {
    sharedExportRoot.appending(
      path: Self.namespaceDirectoryName,
      directoryHint: .isDirectory
    )
  }

  private var currentURL: URL {
    namespaceRoot.appending(
      path: Self.currentDirectoryName,
      directoryHint: .isDirectory
    )
  }

  private var stagingRoot: URL {
    namespaceRoot.appending(
      path: Self.stagingDirectoryName,
      directoryHint: .isDirectory
    )
  }

  private var preparedRoot: URL {
    namespaceRoot.appending(
      path: Self.preparedDirectoryName,
      directoryHint: .isDirectory
    )
  }

  private var lockURL: URL {
    namespaceRoot.appending(
      path: Self.lockFileName,
      directoryHint: .notDirectory
    )
  }

  private func stagingURL(buildID: UUID) -> URL {
    stagingRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
  }

  private func preparedDirectoryName(buildID: UUID, handoffToken: UUID) -> String {
    "\(buildID.uuidString.lowercased())-\(handoffToken.uuidString.lowercased())"
  }

  private func preparedURL(buildID: UUID, handoffToken: UUID) -> URL {
    preparedRoot.appending(
      path: preparedDirectoryName(buildID: buildID, handoffToken: handoffToken),
      directoryHint: .isDirectory
    )
  }

  private func acquireExclusiveLock() async throws -> Int32 {
    try ensureNamespaceRoot()
    let descriptor = try openValidatedLockDescriptor()
    do {
      while nativeBuildCacheFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let code = errno
        if code == EINTR { continue }
        guard code == EWOULDBLOCK || code == EAGAIN else {
          throw posixError("lock cache", lockURL, code: code)
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(50))
      }
      try Task.checkCancellation()
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func ensureNamespaceRoot() throws {
    try validateDirectory(
      sharedExportRoot,
      missing: .unsafeRoot(sharedExportRoot.path(percentEncoded: false)),
      allowsSharedRead: true
    )
    try createPrivateDirectoryIfNeeded(namespaceRoot)
    try validateDirectory(
      namespaceRoot,
      missing: .unsafeRoot(namespaceRoot.path(percentEncoded: false))
    )
    try createPrivateDirectoryIfNeeded(stagingRoot)
    try validateDirectory(
      stagingRoot,
      missing: .unsafeRoot(stagingRoot.path(percentEncoded: false))
    )
    try createPrivateDirectoryIfNeeded(preparedRoot)
    try validateDirectory(
      preparedRoot,
      missing: .unsafeRoot(preparedRoot.path(percentEncoded: false))
    )
  }

  private func createPrivateDirectoryIfNeeded(_ url: URL) throws {
    if Darwin.mkdir(url.path(percentEncoded: false), 0o700) != 0, errno != EEXIST {
      throw posixError("create cache directory", url)
    }
    guard Darwin.chmod(url.path(percentEncoded: false), 0o700) == 0 else {
      throw posixError("secure cache directory", url)
    }
  }

  private func openValidatedLockDescriptor() throws -> Int32 {
    let descriptor = Darwin.open(
      lockURL.path(percentEncoded: false),
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw posixError("open cache lock", lockURL)
    }
    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw AppOwnedBuildCacheStoreError.unsafeRoot(
        lockURL.path(percentEncoded: false)
      )
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else {
      let error = posixError("secure cache lock", lockURL)
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func recoverInterruptedTransactions() throws {
    let staged = try FileManager.default.contentsOfDirectory(
      at: stagingRoot,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in staged {
      try removeIfPresent(entry, within: stagingRoot)
    }
    try recoverStalePreparedExports()

    let namespaceEntries = try FileManager.default.contentsOfDirectory(
      at: namespaceRoot,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in namespaceEntries {
      let name = entry.lastPathComponent
      if name.hasPrefix(".reset-") || name.hasPrefix("next-") {
        try removeIfPresent(entry, within: namespaceRoot)
      }
    }
  }

  private func recoverStalePreparedExports() throws {
    let now = Date().timeIntervalSince1970
    for entry in try preparedExportURLs() {
      try Task.checkCancellation()
      guard isPreparedExportName(entry.lastPathComponent) else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(
          entry.path(percentEncoded: false)
        )
      }
      var metadata = stat()
      guard
        Darwin.lstat(entry.path(percentEncoded: false), &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o077 == 0
      else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(
          entry.path(percentEncoded: false)
        )
      }
      let modificationTime =
        TimeInterval(metadata.st_mtimespec.tv_sec)
        + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
      if now - modificationTime > Self.preparedHandoffLifetime {
        try removeIfPresent(entry, within: preparedRoot)
      }
    }
  }

  private func isPreparedExportName(_ name: String) -> Bool {
    guard name.count == 73, name == name.lowercased() else { return false }
    let separator = name.index(name.startIndex, offsetBy: 36)
    guard name[separator] == "-" else { return false }
    let tokenStart = name.index(after: separator)
    return UUID(uuidString: String(name[..<separator])) != nil
      && UUID(uuidString: String(name[tokenStart...])) != nil
  }

  private func preparedExportURLs(buildID: UUID? = nil) throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
      at: preparedRoot,
      includingPropertiesForKeys: nil,
      options: []
    )
    guard let buildID else { return entries }
    let prefix = "\(buildID.uuidString.lowercased())-"
    return entries.filter { $0.lastPathComponent.hasPrefix(prefix) }
  }

  private func retirePreparedExportsWhileLocked() throws -> [String] {
    let tombstoneName = ".reset-prepared-\(UUID().uuidString.lowercased())"
    let tombstone = namespaceRoot.appending(
      path: tombstoneName,
      directoryHint: .isDirectory
    )
    let namespaceDescriptor = try openDirectoryDescriptor(namespaceRoot)
    defer { Darwin.close(namespaceDescriptor) }
    let renameResult = Self.preparedDirectoryName.withCString { preparedPointer in
      tombstoneName.withCString { tombstonePointer in
        Darwin.renameatx_np(
          namespaceDescriptor,
          preparedPointer,
          namespaceDescriptor,
          tombstonePointer,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else {
      throw posixError("retire prepared caches", preparedRoot)
    }

    do {
      try createPrivateDirectoryIfNeeded(preparedRoot)
      try validateDirectory(
        preparedRoot,
        missing: .unsafeRoot(preparedRoot.path(percentEncoded: false))
      )
    } catch {
      try? removeIfPresent(tombstone, within: namespaceRoot)
      throw error
    }

    var warnings: [String] = []
    if Darwin.fsync(namespaceDescriptor) != 0 {
      warnings.append(
        "Prepared cache reset committed but its directory sync failed (errno \(errno))."
      )
    }
    do {
      try removeIfPresent(tombstone, within: namespaceRoot)
    } catch {
      warnings.append("Retired prepared caches remain on disk and will be removed on recovery.")
    }
    return warnings
  }

  private func validateCurrentCacheIfPresent() throws -> Bool {
    guard fileExists(currentURL) else { return false }
    try validateDirectory(
      currentURL,
      missing: .unsafeCache(currentURL.path(percentEncoded: false))
    )
    _ = try validateCacheLayout(currentURL)
    _ = try measureCache(at: currentURL)
    return true
  }

  private func validateOwnedCurrentBoundaryIfPresent() throws -> Bool {
    guard try entryExists(currentURL) else { return false }
    var metadata = stat()
    guard
      Darwin.lstat(currentURL.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        currentURL.path(percentEncoded: false)
      )
    }
    return true
  }

  private func validateCacheLayout(_ root: URL) throws -> AppOwnedBuildCacheLayoutIdentity {
    let layoutURL = root.appending(path: "oci-layout", directoryHint: .notDirectory)
    let layoutData = try readValidatedFile(layoutURL, maximumBytes: Self.maximumLayoutBytes)
    let layout = try decode(
      OCILayout.self,
      from: layoutData,
      path: layoutURL
    )
    guard layout.imageLayoutVersion == "1.0.0" else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        layoutURL.path(percentEncoded: false)
      )
    }

    let indexURL = root.appending(path: "index.json", directoryHint: .notDirectory)
    let indexData = try readValidatedFile(indexURL, maximumBytes: Self.maximumIndexBytes)
    let index = try decode(OCIIndex.self, from: indexData, path: indexURL)
    guard index.schemaVersion == 2, !index.manifests.isEmpty else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        indexURL.path(percentEncoded: false)
      )
    }

    let blobs = root.appending(path: "blobs", directoryHint: .isDirectory)
    try validateDirectory(
      blobs,
      missing: .unsafeCache(blobs.path(percentEncoded: false)),
      allowsSharedRead: true
    )
    for descriptor in index.manifests {
      try validateDescriptor(descriptor, root: root)
    }
    return AppOwnedBuildCacheLayoutIdentity(
      layoutSHA256: Self.sha256(layoutData),
      indexSHA256: Self.sha256(indexData)
    )
  }

  private func cacheFingerprint(
    directoryIdentity: AppOwnedBuildCacheDirectoryIdentity,
    layoutIdentity: AppOwnedBuildCacheLayoutIdentity,
    treeIdentity: AppOwnedBuildCacheTreeIdentity
  ) -> String {
    let material = [
      "nativecontainers-cache-handoff-v1",
      String(directoryIdentity.device),
      String(directoryIdentity.inode),
      String(directoryIdentity.owner),
      String(directoryIdentity.permissions),
      layoutIdentity.layoutSHA256,
      layoutIdentity.indexSHA256,
      treeIdentity.metadataSHA256,
      String(treeIdentity.snapshot.byteCount),
      String(treeIdentity.snapshot.entryCount),
    ].joined(separator: "\n")
    return Self.sha256(Data(material.utf8))
  }

  private func validateDescriptor(_ descriptor: OCIDescriptor, root: URL) throws {
    let prefix = "sha256:"
    guard descriptor.digest.hasPrefix(prefix), descriptor.size > 0 else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        root.appending(path: "index.json").path(percentEncoded: false)
      )
    }
    let digest = String(descriptor.digest.dropFirst(prefix.count))
    guard
      digest.count == 64,
      digest.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(descriptor.digest)
    }
    let blob =
      root
      .appending(path: "blobs", directoryHint: .isDirectory)
      .appending(path: "sha256", directoryHint: .isDirectory)
      .appending(path: digest, directoryHint: .notDirectory)
    let data = try readValidatedFile(blob, maximumBytes: Self.maximumDescriptorBytes)
    guard Int64(data.count) == descriptor.size, Self.sha256(data) == digest else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(blob.path(percentEncoded: false))
    }
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data,
    path: URL
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw AppOwnedBuildCacheStoreError.unsafeCache(path.path(percentEncoded: false))
    }
  }

  private func readValidatedFile(_ url: URL, maximumBytes: Int64) throws -> Data {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
      }
      throw posixError("open cache metadata", url)
    }
    defer { Darwin.close(descriptor) }

    var metadataBefore = stat()
    guard
      Darwin.fstat(descriptor, &metadataBefore) == 0,
      metadataBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadataBefore.st_uid == geteuid(),
      metadataBefore.st_nlink == 1,
      metadataBefore.st_size > 0,
      metadataBefore.st_size <= maximumBytes,
      metadataBefore.st_mode & 0o022 == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }

    var data = Data()
    data.reserveCapacity(Int(metadataBefore.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError("read cache metadata", url)
      }
      guard Int64(data.count) + Int64(count) <= maximumBytes else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    var metadataAfter = stat()
    var pathMetadata = stat()
    guard
      Darwin.fstat(descriptor, &metadataAfter) == 0,
      Darwin.lstat(url.path(percentEncoded: false), &pathMetadata) == 0,
      metadataAfter.st_dev == metadataBefore.st_dev,
      metadataAfter.st_ino == metadataBefore.st_ino,
      metadataAfter.st_mode == metadataBefore.st_mode,
      metadataAfter.st_uid == metadataBefore.st_uid,
      metadataAfter.st_nlink == metadataBefore.st_nlink,
      metadataAfter.st_size == metadataBefore.st_size,
      metadataAfter.st_mtimespec.tv_sec == metadataBefore.st_mtimespec.tv_sec,
      metadataAfter.st_mtimespec.tv_nsec == metadataBefore.st_mtimespec.tv_nsec,
      pathMetadata.st_dev == metadataAfter.st_dev,
      pathMetadata.st_ino == metadataAfter.st_ino,
      Int64(data.count) == metadataBefore.st_size
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
    return data
  }

  private func validateDirectory(
    _ url: URL,
    missing: AppOwnedBuildCacheStoreError,
    allowsSharedRead: Bool = false
  ) throws {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 else {
      if errno == ENOENT { throw missing }
      throw posixError("inspect directory", url)
    }
    let unsafePermissions: mode_t = allowsSharedRead ? 0o022 : 0o077
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & unsafePermissions == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
  }

  private func secureExportRoot(_ url: URL) throws {
    var metadata = stat()
    guard
      Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        url.path(percentEncoded: false)
      )
    }
    guard metadata.st_mode & 0o777 != 0o700 else { return }
    guard Darwin.chmod(url.path(percentEncoded: false), 0o700) == 0 else {
      throw posixError("secure cache export", url)
    }
  }

  private func touchPreparedExport(_ url: URL) throws {
    let descriptor = try openDirectoryDescriptor(url)
    defer { Darwin.close(descriptor) }
    guard Darwin.futimens(descriptor, nil) == 0 else {
      throw posixError("timestamp prepared cache", url)
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw posixError("sync prepared cache timestamp", url)
    }
  }

  private func cacheDirectoryIdentity(
    _ url: URL
  ) throws -> AppOwnedBuildCacheDirectoryIdentity {
    var metadata = stat()
    guard
      Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
    return AppOwnedBuildCacheDirectoryIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      owner: metadata.st_uid,
      permissions: UInt16(metadata.st_mode & 0o777)
    )
  }

  private func measureCache(at root: URL) throws -> AppOwnedBuildCacheSnapshot {
    try inspectCacheTree(at: root).snapshot
  }

  private func inspectCacheTree(at root: URL) throws -> AppOwnedBuildCacheTreeIdentity {
    var byteCount: Int64 = 0
    var entryCount = 0
    var hasher = SHA256()
    try inspectCacheDirectory(
      root,
      relativePath: "",
      depth: 0,
      byteCount: &byteCount,
      entryCount: &entryCount,
      hasher: &hasher
    )
    return AppOwnedBuildCacheTreeIdentity(
      snapshot: AppOwnedBuildCacheSnapshot(
        byteCount: byteCount,
        entryCount: entryCount
      ),
      metadataSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }

  private func inspectCacheDirectory(
    _ directory: URL,
    relativePath: String,
    depth: Int,
    byteCount: inout Int64,
    entryCount: inout Int,
    hasher: inout SHA256
  ) throws {
    guard depth <= Self.maximumDirectoryDepth else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        directory.path(percentEncoded: false)
      )
    }
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted {
        $0.lastPathComponent.utf8.lexicographicallyPrecedes(
          $1.lastPathComponent.utf8
        )
      }
    } catch {
      throw cocoaError("enumerate cache", directory, error)
    }

    for entry in entries {
      entryCount += 1
      guard entryCount <= Self.maximumEntryCount else {
        throw AppOwnedBuildCacheStoreError.tooManyEntries
      }
      let name = entry.lastPathComponent
      let entryRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
      var metadata = stat()
      guard
        Darwin.lstat(entry.path(percentEncoded: false), &metadata) == 0,
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o022 == 0
      else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
      }

      var record = Data()
      appendFingerprintString(entryRelativePath, to: &record)
      appendFingerprintInteger(UInt64(metadata.st_mode), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_dev), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_ino), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_uid), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_nlink), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_size)), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_blocks)), to: &record)
      appendFingerprintInteger(
        UInt64(bitPattern: Int64(metadata.st_mtimespec.tv_sec)),
        to: &record
      )
      appendFingerprintInteger(UInt64(metadata.st_mtimespec.tv_nsec), to: &record)
      appendFingerprintInteger(
        UInt64(bitPattern: Int64(metadata.st_ctimespec.tv_sec)),
        to: &record
      )
      appendFingerprintInteger(UInt64(metadata.st_ctimespec.tv_nsec), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_flags), to: &record)
      hasher.update(data: record)

      switch metadata.st_mode & mode_t(S_IFMT) {
      case mode_t(S_IFDIR):
        try inspectCacheDirectory(
          entry,
          relativePath: entryRelativePath,
          depth: depth + 1,
          byteCount: &byteCount,
          entryCount: &entryCount,
          hasher: &hasher
        )
      case mode_t(S_IFREG):
        guard metadata.st_nlink == 1 else {
          throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
        }
        byteCount = try adding(byteCount, Int64(metadata.st_blocks) * 512)
        guard byteCount <= Self.maximumByteCount else {
          throw AppOwnedBuildCacheStoreError.tooLarge
        }
      default:
        throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
      }
    }
  }

  private func appendFingerprintString(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    appendFingerprintInteger(UInt64(bytes.count), to: &data)
    data.append(bytes)
  }

  private func appendFingerprintInteger(_ value: UInt64, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { bytes in
      data.append(contentsOf: bytes)
    }
  }

  private func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw AppOwnedBuildCacheStoreError.tooLarge }
    return value
  }

  private func openDirectoryDescriptor(_ url: URL) throws -> Int32 {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw posixError("open cache directory", url)
    }
    return descriptor
  }

  private func removeIfPresent(_ url: URL, within parent: URL) throws {
    guard fileExists(url) else { return }
    guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw cocoaError("remove cache entry", url, error)
    }
  }

  private func fileExists(_ url: URL) -> Bool {
    var metadata = stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
  }

  private func entryExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 {
      return true
    }
    if errno == ENOENT { return false }
    throw posixError("inspect cache entry", url)
  }

  private func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32 = errno
  ) -> AppOwnedBuildCacheStoreError {
    AppOwnedBuildCacheStoreError.ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: code
    )
  }

  private func cocoaError(
    _ operation: String,
    _ url: URL,
    _ error: any Error
  ) -> AppOwnedBuildCacheStoreError {
    AppOwnedBuildCacheStoreError.ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: Int32((error as NSError).code)
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct OCILayout: Decodable {
  let imageLayoutVersion: String
}

private struct OCIIndex: Decodable {
  let schemaVersion: Int
  let manifests: [OCIDescriptor]
}

private struct OCIDescriptor: Decodable {
  let digest: String
  let size: Int64
}
