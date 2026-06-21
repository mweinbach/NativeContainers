import Foundation

protocol VirtualMachineDiskImageReplacementStoring:
  VirtualMachineStorageInventoryLoading
{
  func acquireDiskImageReplacementRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease

  func commitDiskImageReplacement(
    _ commit: VirtualMachineDiskImageReplacementCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

@MainActor
final class VirtualMachineDiskImageReplacementCoordinator {
  let store: any VirtualMachineDiskImageReplacementStoring
  private let savedStates: any MacVirtualMachineSavedStateInspecting
  private let converter: any VirtualMachineDiskImageConverting
  let imageInspector: any VirtualMachineDiskImageInspecting
  let hostBootSession: any HostBootSessionIdentifying
  let files: VirtualMachineDiskImageReplacementFileOperations
  var quarantinedLeases: [UUID: MacVirtualMachineRuntimeLease] = [:]

  init(
    store: any VirtualMachineDiskImageReplacementStoring,
    savedStates: any MacVirtualMachineSavedStateInspecting,
    converter: any VirtualMachineDiskImageConverting =
      DiskutilVirtualMachineDiskImageConverter(),
    imageInspector: any VirtualMachineDiskImageInspecting =
      AppleVirtualMachineDiskImageInspector(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    journalStore: any VirtualMachineDiskImageReplacementJournaling =
      FileVirtualMachineDiskImageReplacementJournalStore(),
    hostBootSession: any HostBootSessionIdentifying =
      DarwinHostBootSessionIdentifier(),
    fileManager: FileManager = .default
  ) {
    self.store = store
    self.savedStates = savedStates
    self.converter = converter
    self.imageInspector = imageInspector
    self.hostBootSession = hostBootSession
    files = VirtualMachineDiskImageReplacementFileOperations(
      artifactInspector: artifactInspector,
      journalStore: journalStore,
      fileManager: fileManager
    )
  }

  func replace(
    machineID: UUID,
    operation: VirtualMachineDiskImageReplacementOperation
  ) async throws -> VirtualMachineDiskImageReplacementResult {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskImageReplacementError.unavailable
    }
    guard quarantinedLeases[machineID] == nil else {
      throw
        VirtualMachineDiskImageReplacementError
        .converterTerminationUnconfirmed(
          "the previous converter is still quarantined in this app session"
        )
    }

    let lease = try await store.acquireDiskImageReplacementRuntime(id: machineID)
    var shouldReleaseLease = true
    defer {
      if shouldReleaseLease {
        lease.release()
      }
    }

    if let journal = try files.loadJournal(in: lease.machine.bundleURL) {
      try await recover(journal: journal, lease: lease)
    }

    try requireSourceFormat(
      operation.sourceFormat,
      actual: lease.machine.manifest.effectiveDiskImageFormat
    )
    guard try await savedStates.inspect(for: lease) == .none else {
      throw VirtualMachineDiskImageReplacementError.savedStateMustBeDiscarded
    }

    let sourceDescriptor = try imageInspector.inspect(
      at: lease.machine.diskImageURL,
      expectedFormat: operation.sourceFormat
    )
    guard
      sourceDescriptor.logicalBytes == lease.machine.manifest.resources.diskBytes
    else {
      throw VirtualMachineDiskImageReplacementError.logicalSizeMismatch(
        expected: lease.machine.manifest.resources.diskBytes,
        actual: sourceDescriptor.logicalBytes
      )
    }
    if operation == .rewriteASIF, sourceDescriptor.layerType != nil {
      throw VirtualMachineDiskImageReplacementError.stackedImageUnsupported
    }

    let sourceIdentity = try files.inspectOwnedFile(
      at: lease.machine.diskImageURL
    )
    let operationID = UUID()
    let paths = replacementPaths(
      sourcePath: lease.machine.manifest.diskImagePath,
      operation: operation,
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

    var journal = VirtualMachineDiskImageReplacementJournal(
      operation: operation,
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
        to: operation.destinationFormat
      )
      try Task.checkCancellation()
      try files.securePrivateArtifact(at: stagingURL)

      let destinationDescriptor = try imageInspector.inspect(
        at: stagingURL,
        expectedFormat: operation.destinationFormat
      )
      try validateReplacementDescriptor(
        destinationDescriptor,
        against: sourceDescriptor,
        operation: operation
      )
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
      guard let candidateIdentity = journal.destinationIdentity else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      if operation == .rewriteASIF,
        candidateIdentity.allocatedBytes >= sourceIdentity.allocatedBytes
      {
        try await rollback(
          journal: journal,
          bundleURL: lease.machine.bundleURL
        )
        return VirtualMachineDiskImageReplacementResult(
          manifest: lease.machine.manifest,
          sourceAllocatedBytes: sourceIdentity.allocatedBytes,
          destinationAllocatedBytes: candidateIdentity.allocatedBytes,
          didReplace: false
        )
      }

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
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      try files.requireIdentity(destinationIdentity, at: destinationURL)

      let manifest = try await store.commitDiskImageReplacement(
        VirtualMachineDiskImageReplacementCommit(
          sourcePath: journal.sourcePath,
          destinationPath: journal.destinationPath,
          sourceFormat: journal.sourceFormat,
          destinationFormat: journal.destinationFormat,
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
        throw VirtualMachineDiskImageReplacementError.committedCleanupPending(
          error.localizedDescription
        )
      }

      return VirtualMachineDiskImageReplacementResult(
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
          VirtualMachineDiskImageReplacementError
          .converterTerminationUnconfirmed(
            "the kill result and restart boundary could not be persisted; keep NativeContainers open and restart the Mac before retrying (\(error.localizedDescription))"
          )
      }
      throw
        VirtualMachineDiskImageReplacementError
        .converterTerminationUnconfirmed(
          quarantineMessage(for: quarantinedJournal)
        )
    } catch let error as VirtualMachineDiskImageReplacementError {
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

  private func requireSourceFormat(
    _ expected: VirtualMachineDiskImageFormat,
    actual: VirtualMachineDiskImageFormat
  ) throws {
    guard actual == expected else {
      switch expected {
      case .raw:
        throw VirtualMachineDiskImageReplacementError.alreadyASIF
      case .asif:
        throw VirtualMachineDiskImageReplacementError.requiresASIF
      }
    }
  }

  private func validateReplacementDescriptor(
    _ destination: VirtualMachineDiskImageDescriptor,
    against source: VirtualMachineDiskImageDescriptor,
    operation: VirtualMachineDiskImageReplacementOperation
  ) throws {
    guard destination.logicalBytes == source.logicalBytes else {
      throw VirtualMachineDiskImageReplacementError.logicalSizeMismatch(
        expected: source.logicalBytes,
        actual: destination.logicalBytes
      )
    }
    guard destination.layerType == nil else {
      throw VirtualMachineDiskImageReplacementError.stackedImageUnsupported
    }
    if operation == .rewriteASIF,
      destination.blockSizeBytes != source.blockSizeBytes
    {
      throw VirtualMachineDiskImageReplacementError.blockSizeMismatch(
        expected: source.blockSizeBytes,
        actual: destination.blockSizeBytes
      )
    }
  }

  private func replacementPaths(
    sourcePath: String,
    operation: VirtualMachineDiskImageReplacementOperation,
    operationID: UUID
  ) -> (destination: String, staging: String) {
    let source = NSString(string: sourcePath)
    let directory = source.deletingLastPathComponent
    let destinationName: String
    switch operation {
    case .rawToASIF:
      let baseName = (source.lastPathComponent as NSString).deletingPathExtension
      destinationName = "\(baseName).asif"
    case .rewriteASIF:
      destinationName = "Disk-\(operationID.uuidString.lowercased()).asif"
    }
    let stagingName =
      "\(VirtualMachineDiskImageReplacementArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageReplacementArtifacts.stagingSuffix)"
    if directory.isEmpty {
      return (destinationName, stagingName)
    }
    return (
      NSString.path(withComponents: [directory, destinationName]),
      NSString.path(withComponents: [directory, stagingName])
    )
  }
}
