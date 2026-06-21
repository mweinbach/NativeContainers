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

actor RestoreImageCacheService:
  RestoreImageCacheManaging,
  RestoreImageCacheReclamationStoring
{
  static let operationLockFilename = ".operations.lock"
  static let leaseMarkerSuffix = ".cache-lease.json"
  static let legacyImportMarkerSuffix = ".import-pending"
  static let reclamationTombstonePrefix = ".RestoreImageReclamation-"
  static let reclamationTombstoneSuffix = ".partial"
  static let defaultPartialRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

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
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let partialRetentionInterval: TimeInterval
  private let now: @Sendable () -> Date
  private var activeLeases: [UUID: ActiveLease] = [:]
  private var operationTokens = Set<UUID>()
  private var operationLockLease: AdvisoryFileLockLease?
  private var exclusiveOperationToken: UUID?

  init(
    cacheDirectoryURL: URL? = nil,
    fileManager: FileManager = .default,
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    partialRetentionInterval: TimeInterval =
      RestoreImageCacheService.defaultPartialRetentionInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.cacheDirectoryURL =
      (cacheDirectoryURL ?? RestoreImageCacheDirectory.defaultURL(fileManager: fileManager))
      .standardizedFileURL
    self.fileManager = fileManager
    self.artifactInspector = artifactInspector
    self.partialRetentionInterval = max(0, partialRetentionInterval)
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

    try recoverReclamationTombstones()
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

  func prepareRestoreImageCacheReclamation(
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws -> RestoreImageCacheReclamationPlan {
    guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else {
      return RestoreImageCacheReclamationPlan(candidates: [], issues: [])
    }
    try ensurePrivateStoreExists()
    let token = UUID()
    guard try acquireExclusiveOperationAccess(token: token) else {
      throw RestoreImageCacheError.cacheInUse
    }
    defer { releaseExclusiveOperationAccess(token: token) }

    try recoverReclamationTombstones()
    let references = Set(try await referencedURLs().map(\.standardizedFileURL))
    let entries = try fileManager.contentsOfDirectory(
      at: cacheDirectoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    var candidates: [RestoreImageCacheReclamationCandidate] = []
    var issues: [VirtualMachineStorageReclamationPlanningIssue] = []

    for entry in entries.sorted(by: {
      $0.lastPathComponent.utf8.lexicographicallyPrecedes(
        $1.lastPathComponent.utf8
      )
    }) {
      try Task.checkCancellation()
      guard
        let kind = reclamationKind(
          entryName: entry.lastPathComponent,
          references: references
        )
      else {
        continue
      }
      do {
        let identity = try artifactInspector.inspect(at: entry)
        guard identity.fileType == .regularFile else {
          throw VirtualMachineStorageReclamationError.unsafeArtifact(
            "\(entry.lastPathComponent) is not a regular file"
          )
        }
        let modifiedAt = modificationDate(identity)
        if kind == .abandonedPartial,
          now().timeIntervalSince(modifiedAt) < partialRetentionInterval
        {
          continue
        }
        candidates.append(
          RestoreImageCacheReclamationCandidate(
            entryName: entry.lastPathComponent,
            kind: kind,
            modifiedAt: modifiedAt,
            artifactIdentity: identity
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(
          VirtualMachineStorageReclamationPlanningIssue(
            id: "restore-image:\(entry.lastPathComponent)",
            category: .restoreImages,
            machineID: nil,
            message: error.localizedDescription
          )
        )
      }
    }
    return RestoreImageCacheReclamationPlan(
      candidates: candidates,
      issues: issues
    )
  }

  func reclaimRestoreImageCache(
    _ plan: RestoreImageCacheReclamationPlan,
    referencedURLs: @Sendable () async throws -> Set<URL>
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    let ids = plan.candidates.map(\.id)
    guard Set(ids).count == ids.count,
      plan.candidates.allSatisfy({
        $0.artifactIdentity.fileType == .regularFile
          && basicReclamationKind(entryName: $0.entryName) == $0.kind
      })
    else {
      throw VirtualMachineStorageReclamationError.invalidPlan
    }
    guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else {
      return VirtualMachineStorageReclamationBatchResult(
        removedCandidateIDs: [],
        staleCandidateIDs: ids,
        failedCandidates: [],
        removedAllocatedBytes: 0
      )
    }

    try ensurePrivateStoreExists()
    let token = UUID()
    guard try acquireExclusiveOperationAccess(token: token) else {
      throw RestoreImageCacheError.cacheInUse
    }
    defer { releaseExclusiveOperationAccess(token: token) }

    try recoverReclamationTombstones()
    let references = Set(try await referencedURLs().map(\.standardizedFileURL))
    var result = VirtualMachineStorageReclamationBatchResult.empty

    for (index, candidate) in plan.candidates.enumerated() {
      guard !Task.isCancelled else {
        throw partialReclamationError(
          result: result,
          remaining: plan.candidates[index...]
        )
      }
      do {
        if try reclaim(candidate, references: references) {
          result = result.merging(
            VirtualMachineStorageReclamationBatchResult(
              removedCandidateIDs: [candidate.id],
              staleCandidateIDs: [],
              failedCandidates: [],
              removedAllocatedBytes: candidate.estimatedAllocatedBytes
            )
          )
        } else {
          result = result.merging(staleResult(candidate.id))
        }
      } catch is CancellationError {
        throw partialReclamationError(
          result: result,
          remaining: plan.candidates[index...]
        )
      } catch {
        result = result.merging(
          VirtualMachineStorageReclamationBatchResult(
            removedCandidateIDs: [],
            staleCandidateIDs: [],
            failedCandidates: [
              VirtualMachineStorageReclamationCandidateFailure(
                candidateID: candidate.id,
                message: error.localizedDescription
              )
            ],
            removedAllocatedBytes: 0
          )
        )
      }

      guard !Task.isCancelled else {
        let next = plan.candidates.index(after: index)
        throw partialReclamationError(
          result: result,
          remaining: plan.candidates[next...]
        )
      }
    }
    return result
  }

  private func basicReclamationKind(
    entryName: String
  ) -> RestoreImageCacheReclamationKind? {
    guard !entryName.hasPrefix(".") else { return nil }
    let lowercaseName = entryName.lowercased()
    if lowercaseName.hasSuffix(".ipsw.partial") {
      return .abandonedPartial
    }
    if lowercaseName.hasSuffix(".ipsw") {
      return .completedImage
    }
    return nil
  }

  private func reclamationKind(
    entryName: String,
    references: Set<URL>
  ) -> RestoreImageCacheReclamationKind? {
    guard let kind = basicReclamationKind(entryName: entryName) else {
      return nil
    }
    let finalName: String
    switch kind {
    case .completedImage:
      finalName = entryName
    case .abandonedPartial:
      finalName = String(
        entryName.dropLast(".\(RestoreImageDownloadService.partialFileExtension)".count)
      )
    }
    let finalURL = cacheDirectoryURL.appending(
      path: finalName,
      directoryHint: .notDirectory
    ).standardizedFileURL
    guard !references.contains(finalURL), !hasOwnershipMarker(for: finalURL) else {
      return nil
    }
    return kind
  }

  private func hasOwnershipMarker(for finalURL: URL) -> Bool {
    if fileManager.fileExists(atPath: leaseMarkerURL(for: finalURL).path) {
      return true
    }
    let legacyMarker = cacheDirectoryURL.appending(
      path: ".\(finalURL.lastPathComponent)\(Self.legacyImportMarkerSuffix)",
      directoryHint: .notDirectory
    )
    return fileManager.fileExists(atPath: legacyMarker.path)
  }

  private func modificationDate(
    _ identity: VirtualMachineStorageArtifactIdentity
  ) -> Date {
    Date(
      timeIntervalSince1970:
        TimeInterval(identity.modificationSeconds)
        + TimeInterval(identity.modificationNanoseconds) / 1_000_000_000
    )
  }

  private func reclaim(
    _ candidate: RestoreImageCacheReclamationCandidate,
    references: Set<URL>
  ) throws -> Bool {
    guard
      reclamationKind(
        entryName: candidate.entryName,
        references: references
      ) == candidate.kind
    else {
      return false
    }
    let fileURL = cacheDirectoryURL.appending(
      path: candidate.entryName,
      directoryHint: .notDirectory
    )
    guard fileManager.fileExists(atPath: fileURL.path) else { return false }
    let identity = try artifactInspector.inspect(at: fileURL)
    guard identity == candidate.artifactIdentity else { return false }
    if candidate.kind == .abandonedPartial,
      now().timeIntervalSince(candidate.modifiedAt) < partialRetentionInterval
    {
      return false
    }
    try Task.checkCancellation()

    let tombstoneURL = cacheDirectoryURL.appending(
      path:
        "\(Self.reclamationTombstonePrefix)\(UUID().uuidString.lowercased())\(Self.reclamationTombstoneSuffix)",
      directoryHint: .notDirectory
    )
    guard !fileManager.fileExists(atPath: tombstoneURL.path) else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a restore-image cleanup tombstone already exists"
      )
    }
    try fileManager.moveItem(at: fileURL, to: tombstoneURL)
    try syncCacheDirectory()

    // Rename is the commit point. Finish deletion even if cancellation arrives
    // so a reviewed artifact never becomes active again under its old name.
    try fileManager.removeItem(at: tombstoneURL)
    try syncCacheDirectory()
    return true
  }

  private func recoverReclamationTombstones() throws {
    guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else { return }
    let entries = try fileManager.contentsOfDirectory(
      at: cacheDirectoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries where isReclamationTombstone(entry.lastPathComponent) {
      try removeOwnedRegularArtifactIfPresent(at: entry)
      try syncCacheDirectory()
    }
  }

  private func isReclamationTombstone(_ entryName: String) -> Bool {
    guard entryName.hasPrefix(Self.reclamationTombstonePrefix),
      entryName.hasSuffix(Self.reclamationTombstoneSuffix)
    else {
      return false
    }
    let start = entryName.index(
      entryName.startIndex,
      offsetBy: Self.reclamationTombstonePrefix.count
    )
    let end = entryName.index(
      entryName.endIndex,
      offsetBy: -Self.reclamationTombstoneSuffix.count
    )
    return UUID(uuidString: String(entryName[start..<end])) != nil
  }

  private func staleResult(
    _ candidateID: String
  ) -> VirtualMachineStorageReclamationBatchResult {
    VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: [],
      staleCandidateIDs: [candidateID],
      failedCandidates: [],
      removedAllocatedBytes: 0
    )
  }

  private func partialReclamationError(
    result: VirtualMachineStorageReclamationBatchResult,
    remaining: ArraySlice<RestoreImageCacheReclamationCandidate>
  ) -> VirtualMachineStorageReclamationBatchPartialCompletionError {
    VirtualMachineStorageReclamationBatchPartialCompletionError(
      result: result,
      remainingCandidateIDs: remaining.map(\.id)
    )
  }

  private func syncCacheDirectory() throws {
    let descriptor = Darwin.open(
      cacheDirectoryURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
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
