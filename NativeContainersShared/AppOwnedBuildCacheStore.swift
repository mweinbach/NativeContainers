import Darwin
import Foundation

@_silgen_name("flock")
private func nativeBuildCacheFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct AppOwnedBuildCacheStore: Sendable {
  static let namespaceDirectoryName = "nativecontainers-cache-v1"
  static let currentDirectoryName = "current"
  static let stagingDirectoryName = "staging"
  static let preparedDirectoryName = "prepared"

  private static let lockFileName = ".lock"
  private static let preparedHandoffLifetime: TimeInterval = 24 * 60 * 60

  let sharedExportRoot: URL

  private let validator = AppOwnedBuildCacheValidator()

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
        hasImportableCache: try validator.validateCurrentCacheIfPresent(at: currentURL)
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
    guard try validator.validateCurrentCacheIfPresent(at: currentURL) else { return nil }
    return try validator.measureCache(at: currentURL)
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
    guard try validator.validateOwnedCurrentBoundaryIfPresent(at: currentURL) else {
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

  func releaseLock(_ descriptor: Int32) {
    _ = nativeBuildCacheFlock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  func abandonExportWhileLocked(buildID: UUID) {
    try? removeIfPresent(stagingURL(buildID: buildID), within: stagingRoot)
  }

  func commitExportWhileLocked(
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

  func prepareExportForHostCommitWhileLocked(
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

  private func reviewExportWhileLocked(
    buildID: UUID
  ) throws -> ReviewedAppOwnedBuildCacheExport {
    try reviewExport(at: stagingURL(buildID: buildID), within: stagingRoot)
  }

  private func reviewExport(
    at source: URL,
    within parent: URL
  ) throws -> ReviewedAppOwnedBuildCacheExport {
    do {
      return try validator.reviewExport(at: source)
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
    guard try validator.cacheDirectoryIdentity(source) == reviewed.directoryIdentity else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        source.path(percentEncoded: false)
      )
    }
    let currentExists = try validator.validateCurrentCacheIfPresent(at: currentURL)
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
    try validator.validateDirectory(
      sharedExportRoot,
      missing: .unsafeRoot(sharedExportRoot.path(percentEncoded: false)),
      allowsSharedRead: true
    )
    try createPrivateDirectoryIfNeeded(namespaceRoot)
    try validator.validateDirectory(
      namespaceRoot,
      missing: .unsafeRoot(namespaceRoot.path(percentEncoded: false))
    )
    try createPrivateDirectoryIfNeeded(stagingRoot)
    try validator.validateDirectory(
      stagingRoot,
      missing: .unsafeRoot(stagingRoot.path(percentEncoded: false))
    )
    try createPrivateDirectoryIfNeeded(preparedRoot)
    try validator.validateDirectory(
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
      try validator.validateDirectory(
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
}
