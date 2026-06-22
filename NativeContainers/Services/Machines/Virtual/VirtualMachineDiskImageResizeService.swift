import Foundation

protocol VirtualMachineDiskImageResizeStoring:
  VirtualMachineStorageInventoryLoading,
  Sendable
{
  func acquireMacOSDiskImageResizeRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease
  func acquireLinuxDiskImageResizeRuntime(
    id: UUID
  ) async throws -> LinuxVirtualMachineRuntimeLease

  func commitMacOSDiskImageResize(
    _ commit: VirtualMachineDiskImageResizeCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
  func commitLinuxDiskImageResize(
    _ commit: VirtualMachineDiskImageResizeCommit,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

protocol VirtualMachineDiskImageResizing: Sendable {
  func grow(
    machineID: UUID,
    guest: VirtualMachineGuest,
    to targetLogicalBytes: UInt64
  ) async throws -> VirtualMachineDiskImageResizeResult
}

protocol VirtualMachineDiskImageResizeRecovering: Sendable {
  func recoverInterruptedDiskImageResizes() async throws
    -> VirtualMachineDiskImageResizeRecoveryReport
}

struct UnavailableVirtualMachineDiskImageResizeService:
  VirtualMachineDiskImageResizing,
  VirtualMachineDiskImageResizeRecovering
{
  func grow(
    machineID: UUID,
    guest: VirtualMachineGuest,
    to targetLogicalBytes: UInt64
  ) async throws -> VirtualMachineDiskImageResizeResult {
    throw VirtualMachineDiskImageResizeError.unavailable
  }

  func recoverInterruptedDiskImageResizes() async throws
    -> VirtualMachineDiskImageResizeRecoveryReport
  {
    .empty
  }
}

actor VirtualMachineDiskImageResizeService:
  VirtualMachineDiskImageResizing,
  VirtualMachineDiskImageResizeRecovering
{
  private struct Context {
    let target: VirtualMachineRuntimeTarget
    let manifest: VirtualMachineManifest
    let bundleURL: URL
    let source: VirtualMachineDiskImageResizeSource
    let resizeArtifactPath: String
  }

  private typealias CommitHandler =
    @Sendable (VirtualMachineDiskImageResizeCommit) async throws
    -> VirtualMachineManifest

  private let store: any VirtualMachineDiskImageResizeStoring
  private let macSavedStates: any MacVirtualMachineSavedStateInspecting
  private let linuxSavedStates: any LinuxVirtualMachineSavedStateInspecting
  private let extender: any VirtualMachineDiskImageExtending
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let journals: any VirtualMachineDiskImageResizeJournaling

  init(
    store: any VirtualMachineDiskImageResizeStoring,
    macSavedStates: any MacVirtualMachineSavedStateInspecting,
    linuxSavedStates: any LinuxVirtualMachineSavedStateInspecting,
    extender: any VirtualMachineDiskImageExtending =
      AppleVirtualMachineDiskImageExtender(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    journals: any VirtualMachineDiskImageResizeJournaling =
      FileVirtualMachineDiskImageResizeJournalStore()
  ) {
    self.store = store
    self.macSavedStates = macSavedStates
    self.linuxSavedStates = linuxSavedStates
    self.extender = extender
    self.artifactInspector = artifactInspector
    self.journals = journals
  }

  func grow(
    machineID: UUID,
    guest: VirtualMachineGuest,
    to targetLogicalBytes: UInt64
  ) async throws -> VirtualMachineDiskImageResizeResult {
    guard targetLogicalBytes > 0 else {
      throw VirtualMachineDiskImageResizeError.invalidTarget(
        targetLogicalBytes
      )
    }
    return switch guest {
    case .macOS:
      try await growMacOS(
        machineID: machineID,
        to: targetLogicalBytes,
        recoveredExistingJournal: false
      )
    case .linux:
      try await growLinux(
        machineID: machineID,
        to: targetLogicalBytes,
        recoveredExistingJournal: false
      )
    }
  }

  func recoverInterruptedDiskImageResizes() async throws
    -> VirtualMachineDiskImageResizeRecoveryReport
  {
    let inventory = try await store.loadVirtualMachineStorageInventory()
    var recovered: [UUID] = []
    var deferred: [UUID] = []
    var failures: [VirtualMachineDiskImageResizeRecoveryFailure] = []

    for target in inventory.targets.sorted(by: {
      $0.manifest.id.uuidString < $1.manifest.id.uuidString
    }) {
      try Task.checkCancellation()

      let journal: VirtualMachineDiskImageResizeJournal
      do {
        guard let loaded = try journals.load(in: target.bundleURL) else {
          continue
        }
        journal = loaded
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append(
          VirtualMachineDiskImageResizeRecoveryFailure(
            machineID: target.manifest.id,
            diagnostic: error.localizedDescription
          )
        )
        continue
      }

      do {
        switch target.manifest.guest {
        case .macOS:
          let lease = try await store.acquireMacOSDiskImageResizeRuntime(
            id: target.manifest.id
          )
          defer { lease.release() }
          let context = context(for: lease)
          _ = try await recover(
            journal: journal,
            context: context
          ) { [store] commit in
            try await store.commitMacOSDiskImageResize(
              commit,
              for: lease
            )
          }
        case .linux:
          let lease = try await store.acquireLinuxDiskImageResizeRuntime(
            id: target.manifest.id
          )
          defer { lease.release() }
          let context = context(for: lease)
          _ = try await recover(
            journal: journal,
            context: context
          ) { [store] commit in
            try await store.commitLinuxDiskImageResize(
              commit,
              for: lease
            )
          }
        }
        recovered.append(target.manifest.id)
      } catch is CancellationError {
        throw CancellationError()
      } catch MacVirtualMachineRuntimeError.ownedElsewhere {
        deferred.append(target.manifest.id)
      } catch LinuxVirtualMachineRuntimeError.ownedElsewhere {
        deferred.append(target.manifest.id)
      } catch {
        failures.append(
          VirtualMachineDiskImageResizeRecoveryFailure(
            machineID: target.manifest.id,
            diagnostic: error.localizedDescription
          )
        )
      }
    }

    return VirtualMachineDiskImageResizeRecoveryReport(
      recoveredMachineIDs: recovered,
      deferredMachineIDs: deferred,
      failures: failures
    )
  }

  private func growMacOS(
    machineID: UUID,
    to targetLogicalBytes: UInt64,
    recoveredExistingJournal: Bool
  ) async throws -> VirtualMachineDiskImageResizeResult {
    let lease = try await store.acquireMacOSDiskImageResizeRuntime(
      id: machineID
    )
    defer { lease.release() }
    let context = context(for: lease)
    let commit: CommitHandler = { [store] commit in
      try await store.commitMacOSDiskImageResize(commit, for: lease)
    }

    if let journal = try journals.load(in: context.bundleURL) {
      let recovered = try await recover(
        journal: journal,
        context: context,
        commit: commit
      )
      guard targetLogicalBytes > recovered.newLogicalBytes else {
        if targetLogicalBytes == recovered.newLogicalBytes { return recovered }
        throw VirtualMachineDiskImageResizeError.growthRequired(
          current: recovered.newLogicalBytes,
          requested: targetLogicalBytes
        )
      }
      guard !recoveredExistingJournal else {
        throw VirtualMachineDiskImageResizeError.recoveryRequired(
          "the previous resize was recovered; retry the new capacity"
        )
      }
      lease.release()
      return try await growMacOS(
        machineID: machineID,
        to: targetLogicalBytes,
        recoveredExistingJournal: true
      )
    }

    guard try await macSavedStates.inspect(for: lease) == .none else {
      throw VirtualMachineDiskImageResizeError.savedStateMustBeDiscarded
    }
    return try await beginResize(
      context: context,
      targetLogicalBytes: targetLogicalBytes,
      commit: commit
    )
  }

  private func growLinux(
    machineID: UUID,
    to targetLogicalBytes: UInt64,
    recoveredExistingJournal: Bool
  ) async throws -> VirtualMachineDiskImageResizeResult {
    let lease = try await store.acquireLinuxDiskImageResizeRuntime(
      id: machineID
    )
    defer { lease.release() }
    let context = context(for: lease)
    let commit: CommitHandler = { [store] commit in
      try await store.commitLinuxDiskImageResize(commit, for: lease)
    }

    if let journal = try journals.load(in: context.bundleURL) {
      let recovered = try await recover(
        journal: journal,
        context: context,
        commit: commit
      )
      guard targetLogicalBytes > recovered.newLogicalBytes else {
        if targetLogicalBytes == recovered.newLogicalBytes { return recovered }
        throw VirtualMachineDiskImageResizeError.growthRequired(
          current: recovered.newLogicalBytes,
          requested: targetLogicalBytes
        )
      }
      guard !recoveredExistingJournal else {
        throw VirtualMachineDiskImageResizeError.recoveryRequired(
          "the previous resize was recovered; retry the new capacity"
        )
      }
      lease.release()
      return try await growLinux(
        machineID: machineID,
        to: targetLogicalBytes,
        recoveredExistingJournal: true
      )
    }

    guard try await linuxSavedStates.inspect(for: lease) == .none else {
      throw VirtualMachineDiskImageResizeError.savedStateMustBeDiscarded
    }
    return try await beginResize(
      context: context,
      targetLogicalBytes: targetLogicalBytes,
      commit: commit
    )
  }

  private func beginResize(
    context: Context,
    targetLogicalBytes: UInt64,
    commit: @escaping CommitHandler
  ) async throws -> VirtualMachineDiskImageResizeResult {
    try Task.checkCancellation()
    let descriptor = try extender.descriptor(for: context.source)
    guard
      descriptor.logicalBytes == context.manifest.resources.diskBytes
    else {
      throw VirtualMachineDiskImageResizeError.logicalSizeMismatch(
        expected: context.manifest.resources.diskBytes,
        actual: descriptor.logicalBytes
      )
    }
    if targetLogicalBytes == descriptor.logicalBytes {
      return VirtualMachineDiskImageResizeResult(
        manifest: context.manifest,
        previousLogicalBytes: descriptor.logicalBytes,
        newLogicalBytes: descriptor.logicalBytes,
        didResize: false
      )
    }
    guard targetLogicalBytes > descriptor.logicalBytes else {
      throw VirtualMachineDiskImageResizeError.growthRequired(
        current: descriptor.logicalBytes,
        requested: targetLogicalBytes
      )
    }
    guard targetLogicalBytes.isMultiple(of: descriptor.blockSizeBytes) else {
      throw VirtualMachineDiskImageResizeError.targetNotBlockAligned(
        target: targetLogicalBytes,
        blockSize: descriptor.blockSizeBytes
      )
    }
    guard
      Int(exactly: targetLogicalBytes / descriptor.blockSizeBytes)
        != nil
    else {
      throw VirtualMachineDiskImageResizeError.targetTooLarge(
        targetLogicalBytes
      )
    }

    let sourceIdentity = try inspectOwnedFile(
      at: context.source.resizeArtifactURL
    )
    let journal = VirtualMachineDiskImageResizeJournal(
      operationID: UUID(),
      machineID: context.target.machineID,
      guest: context.manifest.guest,
      diskImagePath: context.manifest.diskImagePath,
      resizeArtifactPath: context.resizeArtifactPath,
      diskImageFormat: context.manifest.effectiveDiskImageFormat,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: descriptor.logicalBytes,
      sourceBlockSizeBytes: descriptor.blockSizeBytes,
      targetLogicalBytes: targetLogicalBytes
    )
    try journals.save(journal, in: context.bundleURL)
    return try await recover(
      journal: journal,
      context: context,
      commit: commit
    )
  }

  private func recover(
    journal initialJournal: VirtualMachineDiskImageResizeJournal,
    context: Context,
    commit: @escaping CommitHandler
  ) async throws -> VirtualMachineDiskImageResizeResult {
    try validate(initialJournal, for: context)
    var journal = initialJournal

    if journal.phase == .planned {
      let resizedIdentity = try extendAndSeal(
        journal: journal,
        context: context
      )
      var extended = journal
      extended.resizedIdentity = resizedIdentity
      extended.phase = .imageExtended
      do {
        try journals.save(extended, in: context.bundleURL)
      } catch {
        throw VirtualMachineDiskImageResizeError.recoveryRequired(
          "the disk was extended but its journal could not advance (\(error.localizedDescription))"
        )
      }
      journal = extended
    }

    guard let resizedIdentity = journal.resizedIdentity else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
    try requireExtendedImage(
      journal: journal,
      context: context,
      expectedIdentity: resizedIdentity
    )

    let commitValue = VirtualMachineDiskImageResizeCommit(
      machineID: journal.machineID,
      guest: journal.guest,
      diskImagePath: journal.diskImagePath,
      resizeArtifactPath: journal.resizeArtifactPath,
      diskImageFormat: journal.diskImageFormat,
      sourceLogicalBytes: journal.sourceLogicalBytes,
      targetLogicalBytes: journal.targetLogicalBytes,
      resizedIdentity: resizedIdentity
    )
    let manifest: VirtualMachineManifest
    do {
      manifest = try await commit(commitValue)
    } catch {
      throw error
    }

    if journal.phase == .imageExtended {
      var committed = journal
      committed.phase = .manifestUpdated
      do {
        try journals.save(committed, in: context.bundleURL)
      } catch {
        throw VirtualMachineDiskImageResizeError.committedCleanupPending(
          error.localizedDescription
        )
      }
      journal = committed
    }

    do {
      try journals.remove(journal, from: context.bundleURL)
    } catch {
      throw VirtualMachineDiskImageResizeError.committedCleanupPending(
        error.localizedDescription
      )
    }
    return VirtualMachineDiskImageResizeResult(
      manifest: manifest,
      previousLogicalBytes: journal.sourceLogicalBytes,
      newLogicalBytes: journal.targetLogicalBytes,
      didResize: true
    )
  }

  private func extendAndSeal(
    journal: VirtualMachineDiskImageResizeJournal,
    context: Context
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let currentDescriptor = try extender.descriptor(for: context.source)
    let currentIdentity = try inspectOwnedFile(
      at: context.source.resizeArtifactURL
    )

    if currentDescriptor.logicalBytes == journal.targetLogicalBytes {
      guard
        currentIdentity.refersToSameFileNode(
          as: journal.sourceIdentity
        )
      else {
        throw VirtualMachineDiskImageResizeError.staleSource
      }
      return currentIdentity
    }

    guard currentDescriptor.logicalBytes == journal.sourceLogicalBytes,
      currentDescriptor.blockSizeBytes == journal.sourceBlockSizeBytes,
      currentIdentity == journal.sourceIdentity
    else {
      throw VirtualMachineDiskImageResizeError.staleSource
    }

    do {
      _ = try extender.extend(
        context.source,
        to: journal.targetLogicalBytes
      )
    } catch {
      let operationError = error
      if let descriptor = try? extender.descriptor(for: context.source),
        let identity = try? inspectOwnedFile(
          at: context.source.resizeArtifactURL
        ),
        descriptor.logicalBytes == journal.sourceLogicalBytes,
        identity == journal.sourceIdentity
      {
        do {
          try journals.remove(journal, from: context.bundleURL)
        } catch {
          throw VirtualMachineDiskImageResizeError.recoveryRequired(
            "growth failed and the unchanged transaction could not be removed (\(error.localizedDescription))"
          )
        }
        throw operationError
      }
      throw VirtualMachineDiskImageResizeError.recoveryRequired(
        "DiskImageKit did not report a clean outcome (\(operationError.localizedDescription))"
      )
    }

    let grownDescriptor = try extender.descriptor(for: context.source)
    let grownIdentity = try inspectOwnedFile(
      at: context.source.resizeArtifactURL
    )
    guard grownDescriptor.logicalBytes == journal.targetLogicalBytes,
      grownDescriptor.blockSizeBytes == journal.sourceBlockSizeBytes,
      grownIdentity.refersToSameFileNode(as: journal.sourceIdentity)
    else {
      throw VirtualMachineDiskImageResizeError.recoveryRequired(
        "the disk image did not preserve its expected identity and geometry"
      )
    }
    return grownIdentity
  }

  private func requireExtendedImage(
    journal: VirtualMachineDiskImageResizeJournal,
    context: Context,
    expectedIdentity: VirtualMachineStorageArtifactIdentity
  ) throws {
    let descriptor = try extender.descriptor(for: context.source)
    let identity = try inspectOwnedFile(
      at: context.source.resizeArtifactURL
    )
    guard descriptor.logicalBytes == journal.targetLogicalBytes,
      descriptor.blockSizeBytes == journal.sourceBlockSizeBytes,
      identity == expectedIdentity
    else {
      throw VirtualMachineDiskImageResizeError.staleSource
    }
  }

  private func validate(
    _ journal: VirtualMachineDiskImageResizeJournal,
    for context: Context
  ) throws {
    guard journal.machineID == context.target.machineID,
      journal.guest == context.manifest.guest,
      journal.diskImagePath == context.manifest.diskImagePath,
      journal.resizeArtifactPath == context.resizeArtifactPath,
      journal.diskImageFormat == context.manifest.effectiveDiskImageFormat,
      context.manifest.resources.diskBytes == journal.sourceLogicalBytes
        || context.manifest.resources.diskBytes
          == journal.targetLogicalBytes
    else {
      throw VirtualMachineDiskImageResizeError.invalidJournal
    }
  }

  private func inspectOwnedFile(
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1
    else {
      throw VirtualMachineDiskImageResizeError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    return identity
  }

  private func context(
    for lease: MacVirtualMachineRuntimeLease
  ) -> Context {
    let configuration = lease.machine.manifest
      .effectiveMacOSDiskSnapshotConfiguration
    return Context(
      target: lease.target,
      manifest: lease.machine.manifest,
      bundleURL: lease.machine.bundleURL,
      source: VirtualMachineDiskImageResizeSource(
        baseURL: lease.machine.diskImageURL,
        layerURLs: lease.machine.diskSnapshotLayerURLs,
        expectedFormat: lease.machine.manifest.effectiveDiskImageFormat
      ),
      resizeArtifactPath:
        configuration.layers.last?.relativePath
        ?? lease.machine.manifest.diskImagePath
    )
  }

  private func context(
    for lease: LinuxVirtualMachineRuntimeLease
  ) -> Context {
    Context(
      target: lease.target,
      manifest: lease.machine.manifest,
      bundleURL: lease.machine.bundleURL,
      source: VirtualMachineDiskImageResizeSource(
        baseURL: lease.machine.diskImageURL,
        layerURLs: [],
        expectedFormat: lease.machine.manifest.effectiveDiskImageFormat
      ),
      resizeArtifactPath: lease.machine.manifest.diskImagePath
    )
  }
}
