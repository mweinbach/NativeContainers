import Foundation

@MainActor
protocol VirtualMachineDiskImageReplacementRecovering: Sendable {
  func recoverInterruptedDiskImageReplacements() async throws
    -> VirtualMachineDiskImageReplacementRecoveryReport
}

@MainActor
struct UnavailableVirtualMachineDiskImageReplacementRecoveryService:
  VirtualMachineDiskImageReplacementRecovering
{
  func recoverInterruptedDiskImageReplacements() async throws
    -> VirtualMachineDiskImageReplacementRecoveryReport
  {
    .empty
  }
}

extension VirtualMachineDiskImageReplacementCoordinator {
  func recoverInterruptedDiskImageReplacements() async throws
    -> VirtualMachineDiskImageReplacementRecoveryReport
  {
    var recovered: [UUID] = []
    var deferred: [UUID] = []
    var failures: [VirtualMachineDiskImageReplacementRecoveryFailure] = []

    let inventory = try await store.loadVirtualMachineStorageInventory()
    for target in inventory.targets {
      do {
        try Task.checkCancellation()
        guard try files.loadJournal(in: target.bundleURL) != nil else {
          continue
        }
        guard target.manifest.installState == .stopped else {
          throw VirtualMachineDiskImageReplacementError.invalidJournal
        }
        if quarantinedLeases[target.manifest.id] != nil {
          deferred.append(target.manifest.id)
          continue
        }

        let lease: MacVirtualMachineRuntimeLease
        do {
          lease = try await store.acquireDiskImageReplacementRuntime(
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
          VirtualMachineDiskImageReplacementRecoveryFailure(
            machineID: target.manifest.id,
            diagnostic: error.localizedDescription
          )
        )
      }
    }

    return VirtualMachineDiskImageReplacementRecoveryReport(
      recoveredMachineIDs: recovered,
      deferredMachineIDs: deferred,
      failures: failures
    )
  }

  func recover(
    journal: VirtualMachineDiskImageReplacementJournal,
    lease: MacVirtualMachineRuntimeLease
  ) async throws {
    guard journal.machineID == lease.target.machineID else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
    try requireRecoveryIsSafe(journal)
    let manifest = lease.machine.manifest

    if manifest.diskImagePath == journal.destinationPath,
      manifest.effectiveDiskImageFormat == journal.destinationFormat
    {
      guard journal.phase == .promoted || journal.phase == .manifestUpdated,
        let destinationIdentity = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      let destinationURL = try files.resolve(
        journal.destinationPath,
        in: lease.machine.bundleURL
      )
      try files.requireIdentity(destinationIdentity, at: destinationURL)
      let descriptor = try imageInspector.inspect(
        at: destinationURL,
        expectedFormat: journal.destinationFormat
      )
      guard descriptor.logicalBytes == journal.sourceLogicalBytes else {
        throw VirtualMachineDiskImageReplacementError.logicalSizeMismatch(
          expected: journal.sourceLogicalBytes,
          actual: descriptor.logicalBytes
        )
      }
      guard descriptor.layerType == nil else {
        throw VirtualMachineDiskImageReplacementError.stackedImageUnsupported
      }
      let expectedBlockSize =
        journal.sourceBlockSizeBytes
        ?? (journal.operation == .rawToASIF
          ? VirtualMachineDiskImageDescriptor.rawBlockSizeBytes : nil)
      if let expectedBlockSize {
        guard descriptor.blockSizeBytes == expectedBlockSize else {
          throw VirtualMachineDiskImageReplacementError.blockSizeMismatch(
            expected: expectedBlockSize,
            actual: descriptor.blockSizeBytes
          )
        }
      } else {
        guard
          journal.version
            < VirtualMachineDiskImageReplacementJournal.geometryMetadataVersion
        else {
          throw VirtualMachineDiskImageReplacementError.invalidJournal
        }
      }
      try await finishCommittedCleanup(
        journal: journal,
        bundleURL: lease.machine.bundleURL
      )
      return
    }

    guard manifest.diskImagePath == journal.sourcePath,
      manifest.effectiveDiskImageFormat == journal.sourceFormat,
      journal.phase != .manifestUpdated
    else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
    try await rollback(
      journal: journal,
      bundleURL: lease.machine.bundleURL
    )
  }

  func rollbackOrCombine(
    journal: VirtualMachineDiskImageReplacementJournal,
    bundleURL: URL,
    operationError: any Error
  ) async throws {
    do {
      try await rollback(journal: journal, bundleURL: bundleURL)
    } catch {
      throw VirtualMachineDiskImageReplacementError.operationAndCleanupFailed(
        operation: operationError.localizedDescription,
        cleanup: error.localizedDescription
      )
    }
  }

  private func requireRecoveryIsSafe(
    _ journal: VirtualMachineDiskImageReplacementJournal
  ) throws {
    if journal.phase == .planned {
      guard let originatingBoot = journal.hostBootIdentifier else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      if originatingBoot == (try hostBootSession.currentBootIdentifier()) {
        throw
          VirtualMachineDiskImageReplacementError
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
          VirtualMachineDiskImageReplacementError
          .converterTerminationUnconfirmed(
            "SIGKILL could not be delivered; restart the Mac before recovery"
          )
      }
    case .manualIntervention:
      throw
        VirtualMachineDiskImageReplacementError
        .converterTerminationUnconfirmed(
          "automatic recovery is unsafe; restart the Mac and remove the quarantine with a newer NativeContainers build"
        )
    case nil:
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
  }

  func quarantineMessage(
    for journal: VirtualMachineDiskImageReplacementJournal
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

  func rollback(
    journal: VirtualMachineDiskImageReplacementJournal,
    bundleURL: URL
  ) async throws {
    let files = files
    try await Task.detached(priority: .userInitiated) {
      try files.rollback(journal, in: bundleURL)
    }.value
  }

  func finishCommittedCleanup(
    journal: VirtualMachineDiskImageReplacementJournal,
    bundleURL: URL
  ) async throws {
    let files = files
    try await Task.detached(priority: .userInitiated) {
      try files.finishCommitted(journal, in: bundleURL)
    }.value
  }
}
