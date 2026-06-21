import Darwin
import Foundation

protocol RestoreImageCacheManaging: Sendable {
  func acquireLease(
    for fileURL: URL,
    purpose: RestoreImageCacheLeasePurpose,
    abandonPolicy: RestoreImageCacheAbandonPolicy
  ) async throws -> RestoreImageCacheLease

  func commit(_ lease: RestoreImageCacheLease) async
  func abandon(_ lease: RestoreImageCacheLease) async throws

  func recover(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws
}

actor RestoreImageCacheService: RestoreImageCacheManaging {
  static let operationLockFilename = ".operations.lock"
  static let leaseMarkerSuffix = ".cache-lease.json"
  static let legacyImportMarkerSuffix = ".import-pending"

  private struct LeaseMarker: Codable, Equatable, Sendable {
    let version: Int
    let token: UUID
    let filename: String
    let purpose: RestoreImageCacheLeasePurpose
    let abandonPolicy: RestoreImageCacheAbandonPolicy
    let createdAt: Date
  }

  private struct ActiveLease: Sendable {
    let lease: RestoreImageCacheLease
    let markerURL: URL
  }

  private let cacheDirectoryURL: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private var activeLeases: [UUID: ActiveLease] = [:]
  private var operationTokens = Set<UUID>()
  private var operationLockLease: AdvisoryFileLockLease?
  private var exclusiveOperationToken: UUID?

  init(
    cacheDirectoryURL: URL? = nil,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.cacheDirectoryURL =
      (cacheDirectoryURL ?? RestoreImageCacheDirectory.defaultURL(fileManager: fileManager))
      .standardizedFileURL
    self.fileManager = fileManager
    self.now = now
  }

  func acquireLease(
    for fileURL: URL,
    purpose: RestoreImageCacheLeasePurpose,
    abandonPolicy: RestoreImageCacheAbandonPolicy
  ) async throws -> RestoreImageCacheLease {
    let fileURL = fileURL.standardizedFileURL
    try requireDirectStoreChild(fileURL)
    try ensurePrivateStoreExists()
    guard exclusiveOperationToken == nil else {
      throw RestoreImageCacheError.cacheInUse
    }

    let token = UUID()
    try acquireOperationAccess(token: token)
    do {
      let markerURL = leaseMarkerURL(for: fileURL)
      guard !fileManager.fileExists(atPath: markerURL.path),
        !activeLeases.values.contains(where: { $0.lease.fileURL == fileURL })
      else {
        throw RestoreImageCacheError.cacheInUse
      }

      let lease = RestoreImageCacheLease(
        fileURL: fileURL,
        purpose: purpose,
        abandonPolicy: abandonPolicy,
        token: token
      )
      let marker = LeaseMarker(
        version: 1,
        token: token,
        filename: fileURL.lastPathComponent,
        purpose: purpose,
        abandonPolicy: abandonPolicy,
        createdAt: now()
      )
      try write(marker, to: markerURL)
      activeLeases[token] = ActiveLease(lease: lease, markerURL: markerURL)
      return lease
    } catch {
      releaseOperationAccess(token: token)
      throw error
    }
  }

  func commit(_ lease: RestoreImageCacheLease) async {
    guard let active = activeLease(matching: lease) else { return }
    try? removeMarker(active.markerURL, token: lease.token)
    finish(active)
  }

  func abandon(_ lease: RestoreImageCacheLease) async throws {
    guard let active = activeLease(matching: lease) else { return }
    defer { finish(active) }

    switch lease.abandonPolicy {
    case .retainArtifacts:
      try removeMarker(active.markerURL, token: lease.token)
    case .discardArtifacts:
      try removeOwnedRegularArtifactIfPresent(at: lease.fileURL)
      try removeOwnedRegularArtifactIfPresent(at: lease.partialURL)
      try removeMarker(active.markerURL, token: lease.token)
    }
  }

  func recover(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws {
    guard activeLeases.isEmpty, exclusiveOperationToken == nil else {
      throw RestoreImageCacheError.cacheInUse
    }
    guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else { return }

    let token = UUID()
    guard try acquireExclusiveOperationAccess(token: token) else {
      throw RestoreImageCacheError.cacheInUse
    }
    defer { releaseExclusiveOperationAccess(token: token) }

    let references = Set(try await referencedURLs().map(\.standardizedFileURL))
    let entries = try fileManager.contentsOfDirectory(
      at: cacheDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    let entriesByName = Dictionary(
      uniqueKeysWithValues: entries.map { ($0.lastPathComponent, $0) }
    )

    for markerURL in entries
    where markerURL.lastPathComponent.hasSuffix(Self.leaseMarkerSuffix) {
      let marker = try readMarker(at: markerURL)
      let fileURL = cacheDirectoryURL.appending(
        path: marker.filename,
        directoryHint: .notDirectory
      )
      guard leaseMarkerURL(for: fileURL) == markerURL.standardizedFileURL else {
        throw RestoreImageCacheError.invalidLeaseMarker(markerURL)
      }

      if marker.abandonPolicy == .discardArtifacts {
        if !references.contains(fileURL.standardizedFileURL),
          let finalEntry = entriesByName[marker.filename]
        {
          try removeOwnedRegularArtifactIfPresent(at: finalEntry)
        }
        let partialName =
          "\(marker.filename).\(RestoreImageDownloadService.partialFileExtension)"
        if let partialEntry = entriesByName[partialName] {
          try removeOwnedRegularArtifactIfPresent(at: partialEntry)
        }
      }
      try removeOwnedRegularArtifactIfPresent(at: markerURL)
    }

    try recoverLegacyImports(entries: entries, references: references)
  }

  private func activeLease(matching lease: RestoreImageCacheLease) -> ActiveLease? {
    guard let active = activeLeases[lease.token], active.lease == lease else {
      return nil
    }
    return active
  }

  private func finish(_ active: ActiveLease) {
    activeLeases.removeValue(forKey: active.lease.token)
    releaseOperationAccess(token: active.lease.token)
  }

  private func ensurePrivateStoreExists() throws {
    try fileManager.createDirectory(
      at: cacheDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let values = try cacheDirectoryURL.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    let attributes = try fileManager.attributesOfItem(atPath: cacheDirectoryURL.path)
    guard values.isDirectory == true,
      values.isSymbolicLink != true,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
      ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o022 == 0
    else {
      throw RestoreImageCacheError.unsafeArtifact(cacheDirectoryURL)
    }
  }

  private func requireDirectStoreChild(_ fileURL: URL) throws {
    let filename = fileURL.lastPathComponent
    guard fileURL.isFileURL,
      fileURL.deletingLastPathComponent().standardizedFileURL == cacheDirectoryURL,
      !filename.isEmpty,
      filename != ".",
      filename != "..",
      !filename.contains("/"),
      !filename.contains("\0")
    else {
      throw RestoreImageCacheError.outsideStore(fileURL)
    }
  }

  private func leaseMarkerURL(for fileURL: URL) -> URL {
    cacheDirectoryURL.appending(
      path: ".\(fileURL.lastPathComponent)\(Self.leaseMarkerSuffix)",
      directoryHint: .notDirectory
    ).standardizedFileURL
  }

  private func write(_ marker: LeaseMarker, to markerURL: URL) throws {
    let data = try JSONEncoder().encode(marker)
    try data.write(to: markerURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: markerURL.path
    )
  }

  private func readMarker(at markerURL: URL) throws -> LeaseMarker {
    try requireOwnedRegularArtifact(at: markerURL, allowEmpty: false)
    do {
      let marker = try JSONDecoder().decode(
        LeaseMarker.self,
        from: Data(contentsOf: markerURL, options: [.mappedIfSafe])
      )
      guard marker.version == 1,
        marker.filename == URL(filePath: marker.filename).lastPathComponent,
        !marker.filename.isEmpty,
        marker.filename != ".",
        marker.filename != ".."
      else {
        throw RestoreImageCacheError.invalidLeaseMarker(markerURL)
      }
      return marker
    } catch let error as RestoreImageCacheError {
      throw error
    } catch {
      throw RestoreImageCacheError.invalidLeaseMarker(markerURL)
    }
  }

  private func removeMarker(_ markerURL: URL, token: UUID) throws {
    guard fileManager.fileExists(atPath: markerURL.path) else { return }
    let marker = try readMarker(at: markerURL)
    guard marker.token == token else {
      throw RestoreImageCacheError.invalidLeaseMarker(markerURL)
    }
    try fileManager.removeItem(at: markerURL)
  }

  private func requireOwnedRegularArtifact(at url: URL, allowEmpty: Bool) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
      (attributes[.referenceCount] as? NSNumber)?.uint64Value == 1,
      allowEmpty || size > 0
    else {
      throw RestoreImageCacheError.unsafeArtifact(url)
    }
  }

  private func removeOwnedRegularArtifactIfPresent(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try requireOwnedRegularArtifact(at: url, allowEmpty: true)
    try fileManager.removeItem(at: url)
  }

  private func recoverLegacyImports(
    entries: [URL],
    references: Set<URL>
  ) throws {
    let entriesByName = Dictionary(
      uniqueKeysWithValues: entries.map { ($0.lastPathComponent, $0) }
    )
    for markerURL in entries where isLegacyImportMarker(markerURL.lastPathComponent) {
      try requireOwnedRegularArtifact(at: markerURL, allowEmpty: true)
      let filename = try legacyImportFilename(from: markerURL)
      let importedURL = cacheDirectoryURL.appending(
        path: filename,
        directoryHint: .notDirectory
      )
      if !references.contains(importedURL.standardizedFileURL),
        let importedEntry = entriesByName[filename]
      {
        try removeOwnedRegularArtifactIfPresent(at: importedEntry)
      }
      let partialName =
        "\(filename).\(RestoreImageDownloadService.partialFileExtension)"
      if let partialEntry = entriesByName[partialName] {
        try removeOwnedRegularArtifactIfPresent(at: partialEntry)
      }
      try fileManager.removeItem(at: markerURL)
    }
  }

  private func isLegacyImportMarker(_ filename: String) -> Bool {
    filename.hasPrefix(".") && filename.hasSuffix(Self.legacyImportMarkerSuffix)
  }

  private func legacyImportFilename(from markerURL: URL) throws -> String {
    let markerName = markerURL.lastPathComponent
    let filename = String(
      markerName.dropFirst().dropLast(Self.legacyImportMarkerSuffix.count)
    )
    guard !filename.isEmpty,
      filename != ".",
      filename != "..",
      URL(filePath: filename).lastPathComponent == filename
    else {
      throw RestoreImageCacheError.invalidLeaseMarker(markerURL)
    }
    return filename
  }

  private func acquireOperationAccess(token: UUID) throws {
    guard operationTokens.insert(token).inserted else {
      throw RestoreImageCacheError.cacheInUse
    }
    guard operationLockLease == nil else { return }
    do {
      guard
        let lease = try AdvisoryFileLock.acquire(
          at: cacheDirectoryURL.appending(path: Self.operationLockFilename)
        )
      else {
        operationTokens.remove(token)
        throw RestoreImageCacheError.cacheInUse
      }
      operationLockLease = lease
    } catch {
      operationTokens.remove(token)
      throw error
    }
  }

  private func releaseOperationAccess(token: UUID) {
    guard operationTokens.remove(token) != nil else { return }
    guard operationTokens.isEmpty else { return }
    operationLockLease?.release()
    operationLockLease = nil
  }

  private func acquireExclusiveOperationAccess(token: UUID) throws -> Bool {
    guard operationTokens.isEmpty else { return false }
    do {
      try acquireOperationAccess(token: token)
      exclusiveOperationToken = token
      return true
    } catch RestoreImageCacheError.cacheInUse {
      return false
    }
  }

  private func releaseExclusiveOperationAccess(token: UUID) {
    guard exclusiveOperationToken == token else { return }
    exclusiveOperationToken = nil
    releaseOperationAccess(token: token)
  }
}

enum RestoreImageCacheDirectory {
  static func defaultURL(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Restore Images", directoryHint: .isDirectory)
  }
}
