import Foundation

protocol VirtualMachineDiskImageMigrationStoring:
  VirtualMachineStorageInventoryLoading
{
  func acquireDiskImageMigrationRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease

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
  private let hostBootSession: any HostBootSessionIdentifying
  private let files: VirtualMachineDiskImageMigrationFileOperations
  private var quarantinedLeases: [UUID: MacVirtualMachineRuntimeLease] = [:]

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
    hostBootSession: any HostBootSessionIdentifying =
      DarwinHostBootSessionIdentifier(),
    fileManager: FileManager = .default
  ) {
    self.store = store
    self.savedStates = savedStates
    self.converter = converter
    self.imageInspector = imageInspector
    self.hostBootSession = hostBootSession
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
    guard quarantinedLeases[machineID] == nil else {
      throw VirtualMachineDiskImageMigrationError.converterTerminationUnconfirmed(
        "the previous converter is still quarantined in this app session"
      )
    }

    let lease = try await store.acquireDiskImageMigrationRuntime(id: machineID)
    var shouldReleaseLease = true
    defer {
      if shouldReleaseLease {
        lease.release()
      }
    }

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
      phase: .planned,
      hostBootIdentifier: try hostBootSession.currentBootIdentifier()
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
      convertedJournal.hostBootIdentifier = nil
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
    } catch let error as HostProcessError
      where error.leavesOwnedProcessTerminationUnconfirmed
    {
      quarantinedLeases[machineID] = lease
      shouldReleaseLease = false
      var quarantinedJournal = journal
      quarantinedJournal.phase = .terminationQuarantined
      switch error {
      case .signalFailed:
        quarantinedJournal.terminationQuarantine = .untilHostRestart
      case .didNotExitAfterKill:
        quarantinedJournal.terminationQuarantine = .untilAppRestart
        quarantinedJournal.hostBootIdentifier = nil
      case .launchFailed, .timedOut:
        quarantinedJournal.terminationQuarantine = .manualIntervention
        quarantinedJournal.hostBootIdentifier = nil
      }
      do {
        try files.saveJournal(
          quarantinedJournal,
          in: lease.machine.bundleURL
        )
      } catch {
        throw
          VirtualMachineDiskImageMigrationError
          .converterTerminationUnconfirmed(
            "the kill result and restart boundary could not be persisted; keep NativeContainers open and restart the Mac before retrying (\(error.localizedDescription))"
          )
      }
      throw VirtualMachineDiskImageMigrationError.converterTerminationUnconfirmed(
        quarantineMessage(for: quarantinedJournal)
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
    var failures: [VirtualMachineDiskImageMigrationRecoveryFailure] = []

    let inventory = try await store.loadVirtualMachineStorageInventory()
    for target in inventory.targets where target.manifest.installState == .stopped {
      do {
        try Task.checkCancellation()
        if quarantinedLeases[target.manifest.id] != nil {
          deferred.append(target.manifest.id)
          continue
        }
        guard try files.loadJournal(in: target.bundleURL) != nil else {
          continue
        }

        let lease: MacVirtualMachineRuntimeLease
        do {
          lease = try await store.acquireDiskImageMigrationRuntime(
            id: target.manifest.id
          )
        } catch let error as MacVirtualMachineRuntimeError {
          if case .ownedElsewhere = error {
            deferred.append(target.manifest.id)
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
        recovered.append(target.manifest.id)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append(
          VirtualMachineDiskImageMigrationRecoveryFailure(
            machineID: target.manifest.id,
            diagnostic: error.localizedDescription
          )
        )
      }
    }

    return VirtualMachineDiskImageMigrationRecoveryReport(
      recoveredMachineIDs: recovered,
      deferredMachineIDs: deferred,
      failures: failures
    )
  }

  private func recover(
    journal: VirtualMachineDiskImageMigrationJournal,
    lease: MacVirtualMachineRuntimeLease
  ) async throws {
    guard journal.machineID == lease.target.machineID else {
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
    try requireRecoveryIsSafe(journal)
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

  private func requireRecoveryIsSafe(
    _ journal: VirtualMachineDiskImageMigrationJournal
  ) throws {
    if journal.phase == .planned {
      guard let originatingBoot = journal.hostBootIdentifier else {
        throw VirtualMachineDiskImageMigrationError.invalidJournal
      }
      if originatingBoot == (try hostBootSession.currentBootIdentifier()) {
        throw
          VirtualMachineDiskImageMigrationError
          .converterTerminationUnconfirmed(
            "the app exited while conversion may have been active; restart the Mac before recovery"
          )
      }
    }
    guard journal.phase == .terminationQuarantined else { return }
    switch journal.terminationQuarantine {
    case .untilAppRestart:
      return
    case .untilHostRestart:
      guard let originatingBoot = journal.hostBootIdentifier,
        originatingBoot != (try hostBootSession.currentBootIdentifier())
      else {
        throw
          VirtualMachineDiskImageMigrationError
          .converterTerminationUnconfirmed(
            "SIGKILL could not be delivered; restart the Mac before recovery"
          )
      }
    case .manualIntervention:
      throw
        VirtualMachineDiskImageMigrationError
        .converterTerminationUnconfirmed(
          "automatic recovery is unsafe; restart the Mac and remove the quarantine with a newer NativeContainers build"
        )
    case nil:
      throw VirtualMachineDiskImageMigrationError.invalidJournal
    }
  }

  private func quarantineMessage(
    for journal: VirtualMachineDiskImageMigrationJournal
  ) -> String {
    switch journal.terminationQuarantine {
    case .untilAppRestart:
      "SIGKILL was sent, but exit was not confirmed; restart NativeContainers before retrying"
    case .untilHostRestart:
      "SIGKILL could not be delivered; restart the Mac before recovery"
    case .manualIntervention, nil:
      "automatic recovery is unsafe; restart the Mac before retrying"
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
      "\(VirtualMachineDiskImageMigrationArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageMigrationArtifacts.stagingSuffix)"
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
