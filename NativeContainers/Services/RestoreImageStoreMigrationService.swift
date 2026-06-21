import Darwin
import Foundation

protocol VirtualMachineRestoreImageReferenceStoring: Sendable {
  func loadRestoreImageReferences() async throws -> Set<URL>

  @discardableResult
  func migrateRestoreImageReferences(
    from sourceURL: URL,
    to destinationURL: URL
  ) async throws -> Int
}

protocol RestoreImageStoreMigrating: Sendable {
  func migrateLegacyReferences() async throws -> RestoreImageStoreMigrationReport
}

struct RestoreImageStoreMigrationReport: Equatable, Sendable {
  let migratedArtifactCount: Int
  let updatedManifestCount: Int
  let retainedLegacyArtifactCount: Int

  static let empty = Self(
    migratedArtifactCount: 0,
    updatedManifestCount: 0,
    retainedLegacyArtifactCount: 0
  )
}

protocol RestoreImageMigrationCopying: Sendable {
  func copy(from sourceURL: URL, to destinationURL: URL) async throws
}

struct CopyfileRestoreImageMigrationCopier: RestoreImageMigrationCopying {
  private let transfer: any VirtualMachineBundleTransferring

  init(
    transfer: any VirtualMachineBundleTransferring =
      CopyfileVirtualMachineBundleTransfer()
  ) {
    self.transfer = transfer
  }

  func copy(from sourceURL: URL, to destinationURL: URL) async throws {
    try await transfer.copyBundle(from: sourceURL, to: destinationURL)
  }
}

actor RestoreImageStoreMigrationService: RestoreImageStoreMigrating {
  static let journalPrefix = ".LegacyRestoreImageMigration-"
  static let journalSuffix = ".json"
  static let stagingSuffix = ".partial"

  private enum Phase: String, Codable, Sendable {
    case planned
    case copied
    case promoted
    case referencesUpdated
  }

  private struct Journal: Codable, Sendable {
    let version: Int
    let id: UUID
    let sourceFilename: String
    let destinationFilename: String
    let stagingFilename: String
    let sourceIdentity: VirtualMachineStorageArtifactIdentity
    var destinationIdentity: VirtualMachineStorageArtifactIdentity?
    var phase: Phase
  }

  private struct ResumeResult: Sendable {
    let updatedManifestCount: Int
  }

  private let locations: RestoreImageStoreLocations
  private let legacyStore: any RestoreImageStoreOperationCoordinating
  private let currentStore: any RestoreImageStoreOperationCoordinating
  private let references: any VirtualMachineRestoreImageReferenceStoring
  private let copier: any RestoreImageMigrationCopying
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let fileManager: FileManager

  init(
    locations: RestoreImageStoreLocations,
    legacyStore: any RestoreImageStoreOperationCoordinating,
    currentStore: any RestoreImageStoreOperationCoordinating,
    references: any VirtualMachineRestoreImageReferenceStoring,
    copier: any RestoreImageMigrationCopying =
      CopyfileRestoreImageMigrationCopier(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    fileManager: FileManager = .default
  ) {
    self.locations = locations
    self.legacyStore = legacyStore
    self.currentStore = currentStore
    self.references = references
    self.copier = copier
    self.artifactInspector = artifactInspector
    self.fileManager = fileManager
  }

  func migrateLegacyReferences() async throws -> RestoreImageStoreMigrationReport {
    guard
      locations.legacyCache.standardizedFileURL.path
        != locations.current.standardizedFileURL.path
    else {
      throw RestoreImageStoreMigrationError.overlappingStores
    }

    // Keep compatibility with the previous release's lock order. A legacy
    // process owns the Caches lock through manifest commit, while every new
    // operation owns the durable-store lock before entering the VM library.
    return try await legacyStore.withExclusiveAccess { [self] in
      try await currentStore.withExclusiveAccess { [self] in
        try await migrateWithStoresLocked()
      }
    }
  }

  private func migrateWithStoresLocked() async throws
    -> RestoreImageStoreMigrationReport
  {
    var migratedArtifactCount = 0
    var updatedManifestCount = 0
    var retainedLegacyArtifactCount = 0

    for journalURL in try journalURLs() {
      try Task.checkCancellation()
      let result = try await resume(journalURL: journalURL)
      migratedArtifactCount += 1
      updatedManifestCount += result.updatedManifestCount
      retainedLegacyArtifactCount += 1
    }

    let referencedURLs = try await references.loadRestoreImageReferences()
    let legacyReferences = try referencedURLs.compactMap { reference -> URL? in
      let reference = reference.standardizedFileURL
      guard isSameOrDescendant(reference, of: locations.legacyCache) else {
        return nil
      }
      guard
        reference.deletingLastPathComponent().standardizedFileURL.path
          == locations.legacyCache.standardizedFileURL.path,
        reference.pathExtension.lowercased() == "ipsw"
      else {
        throw RestoreImageStoreMigrationError.invalidLegacyReference(reference)
      }
      return reference
    }

    for sourceURL in Set(legacyReferences).sorted(by: {
      $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }) {
      try Task.checkCancellation()
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw RestoreImageStoreMigrationError.missingLegacyArtifact(sourceURL)
      }
      let journalURL = try planMigration(for: sourceURL)
      let result = try await resume(journalURL: journalURL)
      migratedArtifactCount += 1
      updatedManifestCount += result.updatedManifestCount
      retainedLegacyArtifactCount += 1
    }

    return RestoreImageStoreMigrationReport(
      migratedArtifactCount: migratedArtifactCount,
      updatedManifestCount: updatedManifestCount,
      retainedLegacyArtifactCount: retainedLegacyArtifactCount
    )
  }

  private func planMigration(for sourceURL: URL) throws -> URL {
    let sourceURL = sourceURL.standardizedFileURL
    try requireDirectChild(sourceURL, of: locations.legacyCache)
    let sourceIdentity = try inspectRestoreImage(at: sourceURL)
    let id = UUID()
    let journal = Journal(
      version: 1,
      id: id,
      sourceFilename: sourceURL.lastPathComponent,
      destinationFilename: destinationFilename(
        id: id,
        sourceFilename: sourceURL.lastPathComponent
      ),
      stagingFilename: stagingFilename(id: id),
      sourceIdentity: sourceIdentity,
      destinationIdentity: nil,
      phase: .planned
    )
    let journalURL = self.journalURL(id: id)
    try write(journal, to: journalURL)
    return journalURL
  }

  private func resume(journalURL: URL) async throws -> ResumeResult {
    var journal = try readJournal(at: journalURL)
    let sourceURL = locations.legacyCache.appending(
      path: journal.sourceFilename,
      directoryHint: .notDirectory
    )
    let destinationURL = locations.current.appending(
      path: journal.destinationFilename,
      directoryHint: .notDirectory
    )
    let stagingURL = locations.current.appending(
      path: journal.stagingFilename,
      directoryHint: .notDirectory
    )
    var updatedManifestCount = 0

    while true {
      try Task.checkCancellation()
      switch journal.phase {
      case .planned:
        try requireIdentity(journal.sourceIdentity, at: sourceURL)
        try removeOwnedRegularArtifactIfPresent(at: stagingURL)
        try removeOwnedRegularArtifactIfPresent(at: destinationURL)

        try await copier.copy(from: sourceURL, to: stagingURL)
        try fileManager.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: stagingURL.path
        )
        var excludedStagingURL = stagingURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try excludedStagingURL.setResourceValues(resourceValues)
        let destinationIdentity = try inspectRestoreImage(at: stagingURL)
        guard destinationIdentity.logicalBytes == journal.sourceIdentity.logicalBytes,
          destinationIdentity.modificationSeconds
            == journal.sourceIdentity.modificationSeconds,
          destinationIdentity.modificationNanoseconds
            == journal.sourceIdentity.modificationNanoseconds
        else {
          throw RestoreImageStoreMigrationError.unsafeArtifact(stagingURL)
        }
        try requireIdentity(journal.sourceIdentity, at: sourceURL)
        journal.destinationIdentity = destinationIdentity
        journal.phase = .copied
        try write(journal, to: journalURL)

      case .copied:
        guard let destinationIdentity = journal.destinationIdentity else {
          throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
        }
        let stagingExists = fileManager.fileExists(atPath: stagingURL.path)
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        guard stagingExists != destinationExists else {
          throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
        }
        if stagingExists {
          try requireIdentity(destinationIdentity, at: stagingURL)
          try fileManager.moveItem(at: stagingURL, to: destinationURL)
          try synchronizeDirectory(locations.current)
          journal.destinationIdentity = try requireRenamedIdentity(
            destinationIdentity,
            at: destinationURL
          )
        } else {
          journal.destinationIdentity = try requireRenamedIdentity(
            destinationIdentity,
            at: destinationURL
          )
        }
        journal.phase = .promoted
        try write(journal, to: journalURL)

      case .promoted:
        guard let destinationIdentity = journal.destinationIdentity else {
          throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
        }
        if !fileManager.fileExists(atPath: destinationURL.path) {
          try requireIdentity(journal.sourceIdentity, at: sourceURL)
          journal.destinationIdentity = nil
          journal.phase = .planned
          try write(journal, to: journalURL)
          continue
        }
        try requireIdentity(destinationIdentity, at: destinationURL)
        updatedManifestCount += try await references.migrateRestoreImageReferences(
          from: sourceURL,
          to: destinationURL
        )
        journal.phase = .referencesUpdated
        try write(journal, to: journalURL)

      case .referencesUpdated:
        guard let destinationIdentity = journal.destinationIdentity else {
          throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
        }
        if !fileManager.fileExists(atPath: destinationURL.path) {
          try requireIdentity(journal.sourceIdentity, at: sourceURL)
          journal.destinationIdentity = nil
          journal.phase = .planned
          try write(journal, to: journalURL)
          continue
        }
        try requireIdentity(destinationIdentity, at: destinationURL)

        // This second idempotent pass catches a legacy process that committed a
        // reference after a crash but before this launch reacquired both locks.
        updatedManifestCount += try await references.migrateRestoreImageReferences(
          from: sourceURL,
          to: destinationURL
        )

        // Keep the old, now-unreferenced Caches artifact. Its continued
        // existence makes every partial manifest rewrite safe, and deleting it
        // remains an explicit reviewed-reclamation decision.
        try removeOwnedRegularArtifactIfPresent(at: stagingURL)
        try removeOwnedRegularArtifactIfPresent(at: journalURL)
        try synchronizeDirectory(locations.current)
        return ResumeResult(
          updatedManifestCount: updatedManifestCount
        )
      }
    }
  }

  private func journalURLs() throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: locations.current,
      includingPropertiesForKeys: nil,
      options: []
    ).filter {
      $0.lastPathComponent.hasPrefix(Self.journalPrefix)
        && $0.lastPathComponent.hasSuffix(Self.journalSuffix)
    }.sorted {
      $0.lastPathComponent.utf8.lexicographicallyPrecedes(
        $1.lastPathComponent.utf8
      )
    }
  }

  private func readJournal(at journalURL: URL) throws -> Journal {
    try requireDirectChild(journalURL, of: locations.current)
    let descriptor = Darwin.open(
      journalURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      let data = try handle.readToEnd()
    else {
      throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
    }

    let journal: Journal
    do {
      journal = try JSONDecoder().decode(Journal.self, from: data)
    } catch {
      throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
    }
    guard journal.version == 1,
      self.journalURL(id: journal.id).standardizedFileURL
        == journalURL.standardizedFileURL,
      isSafeFilename(journal.sourceFilename),
      journal.sourceFilename.lowercased().hasSuffix(".ipsw"),
      journal.destinationFilename
        == destinationFilename(
          id: journal.id,
          sourceFilename: journal.sourceFilename
        ),
      journal.stagingFilename == stagingFilename(id: journal.id),
      (journal.phase == .planned) == (journal.destinationIdentity == nil)
    else {
      throw RestoreImageStoreMigrationError.invalidJournal(journalURL)
    }
    return journal
  }

  private func write(_ journal: Journal, to journalURL: URL) throws {
    try requireDirectChild(journalURL, of: locations.current)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(journal).write(to: journalURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: journalURL.path
    )
    try synchronizeDirectory(locations.current)
  }

  private func inspectRestoreImage(
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1,
      identity.logicalBytes > 0
    else {
      throw RestoreImageStoreMigrationError.unsafeArtifact(url)
    }
    return identity
  }

  private func requireIdentity(
    _ expected: VirtualMachineStorageArtifactIdentity,
    at url: URL
  ) throws {
    guard
      identitiesReferToSameStableFile(
        try inspectRestoreImage(at: url),
        expected
      )
    else {
      throw RestoreImageStoreMigrationError.unsafeArtifact(url)
    }
  }

  private func removeOwnedRegularArtifactIfPresent(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1
    else {
      throw RestoreImageStoreMigrationError.unsafeArtifact(url)
    }
    try fileManager.removeItem(at: url)
  }

  private func requireDirectChild(_ url: URL, of root: URL) throws {
    guard url.isFileURL,
      url.deletingLastPathComponent().standardizedFileURL.path
        == root.standardizedFileURL.path,
      isSafeFilename(url.lastPathComponent)
    else {
      throw RestoreImageStoreMigrationError.unsafeArtifact(url)
    }
  }

  private func isSafeFilename(_ filename: String) -> Bool {
    !filename.isEmpty
      && filename != "."
      && filename != ".."
      && !filename.contains("/")
      && !filename.contains("\0")
  }

  private func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootComponents = root.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    guard candidateComponents.count >= rootComponents.count else { return false }
    return candidateComponents.prefix(rootComponents.count)
      .elementsEqual(rootComponents)
  }

  private func requireRenamedIdentity(
    _ expected: VirtualMachineStorageArtifactIdentity,
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let actual = try inspectRestoreImage(at: url)
    guard identitiesReferToSameStableFile(actual, expected) else {
      throw RestoreImageStoreMigrationError.unsafeArtifact(url)
    }
    return actual
  }

  private func identitiesReferToSameStableFile(
    _ lhs: VirtualMachineStorageArtifactIdentity,
    _ rhs: VirtualMachineStorageArtifactIdentity
  ) -> Bool {
    // ctime can advance after an APFS clone's metadata and backup-exclusion
    // xattr are flushed. Device + inode still pin the exact file, while size,
    // allocation, ownership, link count, and mtime detect content drift.
    lhs.device == rhs.device
      && lhs.inode == rhs.inode
      && lhs.fileType == rhs.fileType
      && lhs.ownerUserID == rhs.ownerUserID
      && lhs.linkCount == rhs.linkCount
      && lhs.logicalBytes == rhs.logicalBytes
      && lhs.allocatedBytes == rhs.allocatedBytes
      && lhs.entryCount == rhs.entryCount
      && lhs.modificationSeconds == rhs.modificationSeconds
      && lhs.modificationNanoseconds == rhs.modificationNanoseconds
  }

  private func journalURL(id: UUID) -> URL {
    locations.current.appending(
      path:
        "\(Self.journalPrefix)\(id.uuidString.lowercased())\(Self.journalSuffix)",
      directoryHint: .notDirectory
    )
  }

  private func stagingFilename(id: UUID) -> String {
    "\(Self.journalPrefix)\(id.uuidString.lowercased())\(Self.stagingSuffix)"
  }

  private func destinationFilename(id: UUID, sourceFilename: String) -> String {
    let stem = URL(filePath: sourceFilename).deletingPathExtension().lastPathComponent
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "-_.")
    )
    let sanitized = stem.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let readable = String(sanitized).trimmingCharacters(
      in: CharacterSet(charactersIn: "-.")
    )
    let prefix = readable.isEmpty ? "RestoreImage" : String(readable.prefix(64))
    return "Legacy-\(id.uuidString.lowercased())-\(prefix).ipsw"
  }

  private func synchronizeDirectory(_ directoryURL: URL) throws {
    let descriptor = Darwin.open(
      directoryURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

enum RestoreImageStoreMigrationError: LocalizedError, Equatable, Sendable {
  case overlappingStores
  case invalidLegacyReference(URL)
  case missingLegacyArtifact(URL)
  case unsafeArtifact(URL)
  case invalidJournal(URL)

  var errorDescription: String? {
    switch self {
    case .overlappingStores:
      "The current and legacy restore-image stores resolve to the same directory."
    case .invalidLegacyReference(let url):
      "A virtual machine has an unsupported legacy restore-image reference: \(url.path)"
    case .missingLegacyArtifact(let url):
      "A virtual machine's legacy restore image is missing: \(url.path)"
    case .unsafeArtifact(let url):
      "A restore-image migration artifact is missing, replaced, or unsafe: \(url.path)"
    case .invalidJournal(let url):
      "The restore-image migration journal is invalid: \(url.path)"
    }
  }
}
