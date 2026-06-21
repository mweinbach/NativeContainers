import Darwin
import Foundation

protocol VirtualMachineDiskImageMigrationStoring:
  MacVirtualMachineRuntimeLeasing,
  VirtualMachineInventoryLoading
{
  func commitDiskImageMigration(
    _ commit: VirtualMachineDiskImageMigrationCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

@MainActor
protocol VirtualMachineDiskImageMigrating: Sendable {
  func migrateToASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult
}

@MainActor
protocol VirtualMachineDiskImageMigrationRecovering: Sendable {
  func recoverInterruptedMigrations() async throws
    -> VirtualMachineDiskImageMigrationRecoveryReport
}

@MainActor
protocol VirtualMachineDiskImageMigrationManaging:
  VirtualMachineDiskImageMigrating,
  VirtualMachineDiskImageMigrationRecovering
{}

@MainActor
final class VirtualMachineDiskImageMigrationService:
  VirtualMachineDiskImageMigrationManaging
{
  private let store: any VirtualMachineDiskImageMigrationStoring
  private let savedStates: any MacVirtualMachineSavedStateInspecting
  private let converter: any VirtualMachineDiskImageConverting
  private let imageInspector: any VirtualMachineDiskImageInspecting
  private let files: VirtualMachineDiskImageMigrationFileOperations

  init(
    store: any VirtualMachineDiskImageMigrationStoring,
    savedStates: any MacVirtualMachineSavedStateInspecting,
    converter: any VirtualMachineDiskImageConverting =
      DiskutilVirtualMachineDiskImageConverter(),
    imageInspector: any VirtualMachineDiskImageInspecting =
      AppleVirtualMachineDiskImageInspector(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    journalStore: any VirtualMachineDiskImageMigrationJournaling =
      FileVirtualMachineDiskImageMigrationJournalStore(),
    fileManager: FileManager = .default
  ) {
    self.store = store
    self.savedStates = savedStates
    self.converter = converter
    self.imageInspector = imageInspector
    files = VirtualMachineDiskImageMigrationFileOperations(
      artifactInspector: artifactInspector,
      journalStore: journalStore,
      fileManager: fileManager
    )
  }

  func migrateToASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskImageMigrationError.unavailable
    }

    let lease = try await store.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    if let journal = try files.loadJournal(in: lease.machine.bundleURL) {
      try await recover(journal: journal, lease: lease)
    }

    guard lease.machine.manifest.effectiveDiskImageFormat == .raw else {
      throw VirtualMachineDiskImageMigrationError.alreadyASIF
    }
    guard try await savedStates.inspect(for: lease) == .none else {
      throw VirtualMachineDiskImageMigrationError.savedStateMustBeDiscarded
    }

    let sourceDescriptor = try imageInspector.inspect(
      at: lease.machine.diskImageURL,
      expectedFormat: .raw
    )
    guard
      sourceDescriptor.logicalBytes == lease.machine.manifest.resources.diskBytes
    else {
      throw VirtualMachineDiskImageMigrationError.logicalSizeMismatch(
        expected: lease.machine.manifest.resources.diskBytes,
        actual: sourceDescriptor.logicalBytes
      )
    }

    let sourceIdentity = try files.inspectOwnedFile(
      at: lease.machine.diskImageURL
    )
    let operationID = UUID()
    let paths = migrationPaths(
      sourcePath: lease.machine.manifest.diskImagePath,
      operationID: operationID
    )
    let destinationURL = try files.resolve(
      paths.destination,
      in: lease.machine.bundleURL
    )
    let stagingURL = try files.resolve(
      paths.staging,
      in: lease.machine.bundleURL
    )
    try files.requireAbsent(destinationURL)
    try files.requireAbsent(stagingURL)

    var journal = VirtualMachineDiskImageMigrationJournal(
      version: VirtualMachineDiskImageMigrationJournal.currentVersion,
      operationID: operationID,
      machineID: machineID,
      sourcePath: lease.machine.manifest.diskImagePath,
      destinationPath: paths.destination,
      stagingPath: paths.staging,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: sourceDescriptor.logicalBytes,
      destinationIdentity: nil,
      phase: .planned
    )
    try files.saveJournal(journal, in: lease.machine.bundleURL)

    do {
      try await converter.convert(
        sourceURL: lease.machine.diskImageURL,
        destinationURL: stagingURL,
        to: .asif
      )
      try Task.checkCancellation()
      try files.securePrivateArtifact(at: stagingURL)

      let destinationDescriptor = try imageInspector.inspect(
        at: stagingURL,
        expectedFormat: .asif
      )
      guard destinationDescriptor.logicalBytes == sourceDescriptor.logicalBytes else {
        throw VirtualMachineDiskImageMigrationError.logicalSizeMismatch(
          expected: sourceDescriptor.logicalBytes,
          actual: destinationDescriptor.logicalBytes
        )
      }
      try files.requireIdentity(sourceIdentity, at: lease.machine.diskImageURL)

      var convertedJournal = journal
      convertedJournal.destinationIdentity = try files.inspectOwnedFile(
        at: stagingURL
      )
      convertedJournal.phase = .converted
      try files.saveJournal(convertedJournal, in: lease.machine.bundleURL)
      journal = convertedJournal

      try Task.checkCancellation()
      try files.promote(from: stagingURL, to: destinationURL)
      var promotedJournal = journal
      promotedJournal.destinationIdentity = try files.inspectRenamedFile(
        journal.destinationIdentity,
        at: destinationURL
      )
      promotedJournal.phase = .promoted
      try files.saveJournal(promotedJournal, in: lease.machine.bundleURL)
      journal = promotedJournal

      try Task.checkCancellation()
      try files.requireIdentity(sourceIdentity, at: lease.machine.diskImageURL)
      guard let destinationIdentity = journal.destinationIdentity else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      try files.requireIdentity(destinationIdentity, at: destinationURL)

      let manifest = try await store.commitDiskImageMigration(
        VirtualMachineDiskImageMigrationCommit(
          sourcePath: journal.sourcePath,
          destinationPath: journal.destinationPath,
          sourceFormat: .raw,
          destinationFormat: .asif,
          sourceIdentity: sourceIdentity,
          destinationIdentity: destinationIdentity
        ),
        for: lease
      )

      do {
        var committedJournal = journal
        committedJournal.phase = .manifestUpdated
        try files.saveJournal(
          committedJournal,
          in: lease.machine.bundleURL
        )
        journal = committedJournal
        try await finishCommittedCleanup(
          journal: committedJournal,
          bundleURL: lease.machine.bundleURL
        )
      } catch {
        throw VirtualMachineDiskImageMigrationError.committedCleanupPending(
          error.localizedDescription
        )
      }

      return VirtualMachineDiskImageMigrationResult(
        manifest: manifest,
        sourceAllocatedBytes: sourceIdentity.allocatedBytes,
        destinationAllocatedBytes: destinationIdentity.allocatedBytes
      )
    } catch let error as VirtualMachineDiskImageMigrationError {
      if case .committedCleanupPending = error {
        throw error
      }
      try await rollbackOrCombine(
        journal: journal,
        bundleURL: lease.machine.bundleURL,
        operationError: error
      )
      throw error
    } catch is CancellationError {
      try await rollbackOrCombine(
        journal: journal,
        bundleURL: lease.machine.bundleURL,
        operationError: CancellationError()
      )
      throw CancellationError()
    } catch {
      try await rollbackOrCombine(
        journal: journal,
        bundleURL: lease.machine.bundleURL,
        operationError: error
      )
      throw error
    }
  }

  func recoverInterruptedMigrations() async throws
    -> VirtualMachineDiskImageMigrationRecoveryReport
  {
    var recovered: [UUID] = []
    var deferred: [UUID] = []

    for manifest in try await store.list() where manifest.installState == .stopped {
      let lease: MacVirtualMachineRuntimeLease
      do {
        lease = try await store.acquireMacOSRuntime(id: manifest.id)
      } catch let error as MacVirtualMachineRuntimeError {
        if case .ownedElsewhere = error {
          deferred.append(manifest.id)
          continue
        }
        throw error
      }
      defer { lease.release() }

      guard
        let journal = try files.loadJournal(in: lease.machine.bundleURL)
      else {
        continue
      }
      try await recover(journal: journal, lease: lease)
      recovered.append(manifest.id)
    }

    return VirtualMachineDiskImageMigrationRecoveryReport(
      recoveredMachineIDs: recovered,
      deferredMachineIDs: deferred
    )
  }

  private func recover(
    journal: VirtualMachineDiskImageMigrationJournal,
    lease: MacVirtualMachineRuntimeLease
  ) async throws {
    guard journal.machineID == lease.target.machineID else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    let manifest = lease.machine.manifest

    if manifest.diskImagePath == journal.destinationPath,
      manifest.effectiveDiskImageFormat == .asif
    {
      guard journal.phase == .promoted || journal.phase == .manifestUpdated,
        let destinationIdentity = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      let destinationURL = try files.resolve(
        journal.destinationPath,
        in: lease.machine.bundleURL
      )
      try files.requireIdentity(destinationIdentity, at: destinationURL)
      let descriptor = try imageInspector.inspect(
        at: destinationURL,
        expectedFormat: .asif
      )
      guard descriptor.logicalBytes == journal.sourceLogicalBytes else {
        throw VirtualMachineDiskImageMigrationError.logicalSizeMismatch(
          expected: journal.sourceLogicalBytes,
          actual: descriptor.logicalBytes
        )
      }
      try await finishCommittedCleanup(
        journal: journal,
        bundleURL: lease.machine.bundleURL
      )
      return
    }

    guard manifest.diskImagePath == journal.sourcePath,
      manifest.effectiveDiskImageFormat == .raw,
      journal.phase != .manifestUpdated
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    try await rollback(
      journal: journal,
      bundleURL: lease.machine.bundleURL
    )
  }

  private func rollbackOrCombine(
    journal: VirtualMachineDiskImageMigrationJournal,
    bundleURL: URL,
    operationError: any Error
  ) async throws {
    do {
      try await rollback(journal: journal, bundleURL: bundleURL)
    } catch {
      throw VirtualMachineDiskImageMigrationError.operationAndCleanupFailed(
        operation: operationError.localizedDescription,
        cleanup: error.localizedDescription
      )
    }
  }

  private func rollback(
    journal: VirtualMachineDiskImageMigrationJournal,
    bundleURL: URL
  ) async throws {
    let files = files
    try await Task.detached(priority: .userInitiated) {
      try files.rollback(journal, in: bundleURL)
    }.value
  }

  private func finishCommittedCleanup(
    journal: VirtualMachineDiskImageMigrationJournal,
    bundleURL: URL
  ) async throws {
    let files = files
    try await Task.detached(priority: .userInitiated) {
      try files.finishCommitted(journal, in: bundleURL)
    }.value
  }

  private func migrationPaths(
    sourcePath: String,
    operationID: UUID
  ) -> (destination: String, staging: String) {
    let source = NSString(string: sourcePath)
    let directory = source.deletingLastPathComponent
    let baseName = (source.lastPathComponent as NSString).deletingPathExtension
    let destinationName = "\(baseName).asif"
    let stagingName =
      ".DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    if directory.isEmpty {
      return (destinationName, stagingName)
    }
    return (
      NSString.path(withComponents: [directory, destinationName]),
      NSString.path(withComponents: [directory, stagingName])
    )
  }
}

@MainActor
struct UnavailableVirtualMachineDiskImageMigrationService:
  VirtualMachineDiskImageMigrationManaging
{
  func migrateToASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
    throw VirtualMachineDiskImageMigrationError.unavailable
  }

  func recoverInterruptedMigrations() async throws
    -> VirtualMachineDiskImageMigrationRecoveryReport
  {
    .empty
  }
}

private struct VirtualMachineDiskImageMigrationFileOperations:
  @unchecked Sendable
{
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let journalStore: any VirtualMachineDiskImageMigrationJournaling
  private let fileManager: FileManager

  init(
    artifactInspector: any VirtualMachineStorageArtifactInspecting,
    journalStore: any VirtualMachineDiskImageMigrationJournaling,
    fileManager: FileManager
  ) {
    self.artifactInspector = artifactInspector
    self.journalStore = journalStore
    self.fileManager = fileManager
  }

  func loadJournal(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageMigrationJournal? {
    try journalStore.load(in: bundleURL)
  }

  func saveJournal(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    in bundleURL: URL
  ) throws {
    try journalStore.save(journal, in: bundleURL)
  }

  func inspectOwnedFile(
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1
    else {
      throw VirtualMachineDiskImageMigrationError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    return identity
  }

  func requireIdentity(
    _ expected: VirtualMachineStorageArtifactIdentity,
    at url: URL
  ) throws {
    guard try inspectOwnedFile(at: url).refersToSameStableFile(as: expected) else {
      throw VirtualMachineDiskImageMigrationError.staleSource
    }
  }

  func inspectRenamedFile(
    _ previous: VirtualMachineStorageArtifactIdentity?,
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    guard let previous else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    let current = try inspectOwnedFile(at: url)
    guard current.refersToSameStableFile(as: previous) else {
      throw VirtualMachineDiskImageMigrationError.staleSource
    }
    return current
  }

  func resolve(_ path: String, in bundleURL: URL) throws -> URL {
    let string = NSString(string: path)
    let components = string.pathComponents
    guard !string.isAbsolutePath,
      !components.isEmpty,
      !components.contains(".."),
      components.allSatisfy({ $0 != "/" && $0 != "." })
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    let candidate = bundleURL.appending(path: path).standardizedFileURL
    let bundleComponents = bundleURL.standardizedFileURL.pathComponents
    guard candidate.pathComponents.count > bundleComponents.count,
      candidate.pathComponents.prefix(bundleComponents.count)
        .elementsEqual(bundleComponents)
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    return candidate
  }

  func requireAbsent(_ url: URL) throws {
    var metadata = stat()
    if Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 {
      throw VirtualMachineDiskImageMigrationError.destinationExists(url)
    }
    guard errno == ENOENT else {
      throw VirtualMachineDiskImageMigrationError.unsafeArtifact(
        url.lastPathComponent
      )
    }
  }

  func securePrivateArtifact(at url: URL) throws {
    _ = try inspectOwnedFile(at: url)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
    var excludedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excludedURL.setResourceValues(values)
  }

  func promote(from stagingURL: URL, to destinationURL: URL) throws {
    try requireAbsent(destinationURL)
    try fileManager.moveItem(at: stagingURL, to: destinationURL)
    try synchronizeDirectory(destinationURL.deletingLastPathComponent())
  }

  func rollback(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    in bundleURL: URL
  ) throws {
    let sourceURL = try resolve(journal.sourcePath, in: bundleURL)
    try requireIdentity(journal.sourceIdentity, at: sourceURL)

    let stagingURL = try resolve(journal.stagingPath, in: bundleURL)
    let destinationURL = try resolve(journal.destinationPath, in: bundleURL)
    let stagingExists = exists(stagingURL)
    let destinationExists = exists(destinationURL)

    switch journal.phase {
    case .planned:
      guard !destinationExists else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      if stagingExists {
        try removeOwnedFile(at: stagingURL)
      }
    case .converted:
      guard !(stagingExists && destinationExists),
        let expected = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      if stagingExists || destinationExists {
        let artifactURL = stagingExists ? stagingURL : destinationURL
        let identity = try inspectOwnedFile(at: artifactURL)
        guard identity.refersToSameStableFile(as: expected) else {
          throw VirtualMachineDiskImageMigrationError.invalidJournal
        }
        try fileManager.removeItem(at: artifactURL)
      }
    case .promoted:
      guard !stagingExists,
        let expected = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      if destinationExists {
        try requireIdentity(expected, at: destinationURL)
        try fileManager.removeItem(at: destinationURL)
      }
    case .manifestUpdated:
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    try journalStore.remove(journal, from: bundleURL)
    try synchronizeDirectory(destinationURL.deletingLastPathComponent())
  }

  func finishCommitted(
    _ journal: VirtualMachineDiskImageMigrationJournal,
    in bundleURL: URL
  ) throws {
    guard journal.phase == .promoted || journal.phase == .manifestUpdated,
      let destinationIdentity = journal.destinationIdentity
    else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let destinationURL = try resolve(journal.destinationPath, in: bundleURL)
    try requireIdentity(destinationIdentity, at: destinationURL)

    let stagingURL = try resolve(journal.stagingPath, in: bundleURL)
    guard !exists(stagingURL) else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }

    let sourceURL = try resolve(journal.sourcePath, in: bundleURL)
    if exists(sourceURL) {
      try requireIdentity(journal.sourceIdentity, at: sourceURL)
      try fileManager.removeItem(at: sourceURL)
      try synchronizeDirectory(sourceURL.deletingLastPathComponent())
    }
    try journalStore.remove(journal, from: bundleURL)
  }

  private func removeOwnedFile(at url: URL) throws {
    _ = try inspectOwnedFile(at: url)
    try fileManager.removeItem(at: url)
  }

  private func exists(_ url: URL) -> Bool {
    var metadata = stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageMigrationError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
