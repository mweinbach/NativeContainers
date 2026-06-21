import CryptoKit
import Darwin
import Foundation

protocol VirtualMachineInterruptedResidueReclaiming: Sendable {
  func prepareInterruptedResidueReclamation() async throws
    -> VirtualMachineStorageResidueReclamationPlan

  func reclaimInterruptedResidue(
    _ plan: VirtualMachineStorageResidueReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult
}

actor VirtualMachineResidueReclamationService:
  VirtualMachineInterruptedResidueReclaiming
{
  private let inventory: any VirtualMachineStorageInventoryLoading
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let fileManager: FileManager

  init(
    inventory: any VirtualMachineStorageInventoryLoading,
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    fileManager: FileManager = .default
  ) {
    self.inventory = inventory
    self.artifactInspector = artifactInspector
    self.fileManager = fileManager
  }

  func prepareInterruptedResidueReclamation() async throws
    -> VirtualMachineStorageResidueReclamationPlan
  {
    try Task.checkCancellation()
    let snapshot = try await inventory.loadVirtualMachineStorageInventory()
    try Task.checkCancellation()

    var candidates: [VirtualMachineStorageResidueCandidate] = []
    var issues: [VirtualMachineStorageReclamationPlanningIssue] = []

    let libraryLock = try acquireLibraryLock(rootURL: snapshot.rootURL)
    do {
      let rootEntries = try fileManager.contentsOfDirectory(
        at: snapshot.rootURL,
        includingPropertiesForKeys: nil,
        options: []
      )
      for entry in rootEntries.sorted(by: {
        $0.lastPathComponent.utf8.lexicographicallyPrecedes(
          $1.lastPathComponent.utf8
        )
      }) {
        try Task.checkCancellation()
        guard let kind = classifyLibraryEntry(entry.lastPathComponent) else {
          continue
        }
        appendCandidate(
          entryURL: entry,
          kind: kind,
          machineID: nil,
          machineName: nil,
          manifestFingerprint: nil,
          expectedType: .directory,
          candidates: &candidates,
          issues: &issues
        )
      }
      libraryLock.release()
    } catch {
      libraryLock.release()
      throw error
    }

    for target in snapshot.targets.sorted(by: {
      let nameOrder = $0.manifest.name.localizedStandardCompare($1.manifest.name)
      return nameOrder == .orderedSame
        ? $0.manifest.id.uuidString < $1.manifest.id.uuidString
        : nameOrder == .orderedAscending
    }) {
      try Task.checkCancellation()
      do {
        try withBundleLocks(
          rootURL: snapshot.rootURL,
          bundleURL: target.bundleURL,
          machineID: target.manifest.id
        ) {
          let manifest = try currentManifest(
            in: target.bundleURL,
            expectedID: target.manifest.id
          )
          guard manifest.installState != .installing else {
            issues.append(
              planningIssue(
                id: "machine:\(manifest.id.uuidString.lowercased())",
                machineID: manifest.id,
                message:
                  "Installation is still marked in progress; recover it before reviewing residue."
              )
            )
            return
          }
          let fingerprint = try manifestFingerprint(manifest)
          let entries = try fileManager.contentsOfDirectory(
            at: target.bundleURL,
            includingPropertiesForKeys: nil,
            options: []
          )
          for entry in entries.sorted(by: {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes(
              $1.lastPathComponent.utf8
            )
          }) {
            guard
              let classification = classifyBundleEntry(
                entry.lastPathComponent,
                manifest: manifest
              )
            else {
              continue
            }
            appendCandidate(
              entryURL: entry,
              kind: classification.kind,
              machineID: manifest.id,
              machineName: manifest.name,
              manifestFingerprint: fingerprint,
              expectedType: classification.expectedType,
              candidates: &candidates,
              issues: &issues
            )
          }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(
          planningIssue(
            id: "machine:\(target.manifest.id.uuidString.lowercased())",
            machineID: target.manifest.id,
            message: error.localizedDescription
          )
        )
      }
    }

    return VirtualMachineStorageResidueReclamationPlan(
      candidates: candidates,
      issues: issues
    )
  }

  func reclaimInterruptedResidue(
    _ plan: VirtualMachineStorageResidueReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationBatchResult {
    let snapshot = try await inventory.loadVirtualMachineStorageInventory()
    var result = VirtualMachineStorageReclamationBatchResult.empty

    for (index, candidate) in plan.candidates.enumerated() {
      guard !Task.isCancelled else {
        throw partial(result: result, remaining: plan.candidates[index...])
      }

      do {
        let removed: Bool
        if let machineID = candidate.machineID {
          guard
            let target = snapshot.targets.first(where: {
              $0.manifest.id == machineID
            })
          else {
            result = result.merging(staleResult(candidate.id))
            continue
          }
          removed = try withBundleLocks(
            rootURL: snapshot.rootURL,
            bundleURL: target.bundleURL,
            machineID: machineID
          ) {
            try reclaimBundleCandidate(candidate, bundleURL: target.bundleURL)
          }
        } else {
          let lock = try acquireLibraryLock(rootURL: snapshot.rootURL)
          do {
            removed = try reclaimLibraryCandidate(
              candidate,
              rootURL: snapshot.rootURL
            )
            lock.release()
          } catch {
            lock.release()
            throw error
          }
        }

        if removed {
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
        throw partial(result: result, remaining: plan.candidates[index...])
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
        throw partial(result: result, remaining: plan.candidates[next...])
      }
    }
    return result
  }

  private func appendCandidate(
    entryURL: URL,
    kind: VirtualMachineStorageResidueKind,
    machineID: UUID?,
    machineName: String?,
    manifestFingerprint: String?,
    expectedType: VirtualMachineStorageArtifactFileType,
    candidates: inout [VirtualMachineStorageResidueCandidate],
    issues: inout [VirtualMachineStorageReclamationPlanningIssue]
  ) {
    let entryName = entryURL.lastPathComponent
    let candidateID =
      machineID.map {
        VirtualMachineStorageResidueCandidate.machineID(
          machineID: $0,
          entryName: entryName
        )
      }
      ?? VirtualMachineStorageResidueCandidate.libraryID(
        entryName: entryName
      )
    do {
      let identity = try artifactInspector.inspect(at: entryURL)
      guard identity.fileType == expectedType else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "\(entryName) has an unexpected file type"
        )
      }
      candidates.append(
        VirtualMachineStorageResidueCandidate(
          id: candidateID,
          kind: kind,
          entryName: entryName,
          machineID: machineID,
          machineName: machineName,
          manifestFingerprint: manifestFingerprint,
          artifactIdentity: identity
        )
      )
    } catch {
      issues.append(
        planningIssue(
          id: candidateID,
          machineID: machineID,
          message: error.localizedDescription
        )
      )
    }
  }

  private func reclaimLibraryCandidate(
    _ candidate: VirtualMachineStorageResidueCandidate,
    rootURL: URL
  ) throws -> Bool {
    guard candidate.machineID == nil,
      classifyLibraryEntry(candidate.entryName) == candidate.kind
    else {
      return false
    }
    return try retireCandidate(
      candidate,
      at: rootURL.appending(path: candidate.entryName),
      parentURL: rootURL
    )
  }

  private func reclaimBundleCandidate(
    _ candidate: VirtualMachineStorageResidueCandidate,
    bundleURL: URL
  ) throws -> Bool {
    guard let machineID = candidate.machineID else { return false }
    let manifest = try currentManifest(in: bundleURL, expectedID: machineID)
    guard manifest.installState != .installing,
      try manifestFingerprint(manifest) == candidate.manifestFingerprint,
      classifyBundleEntry(candidate.entryName, manifest: manifest)?.kind
        == candidate.kind
    else {
      return false
    }
    return try retireCandidate(
      candidate,
      at: bundleURL.appending(path: candidate.entryName),
      parentURL: bundleURL
    )
  }

  private func retireCandidate(
    _ candidate: VirtualMachineStorageResidueCandidate,
    at url: URL,
    parentURL: URL
  ) throws -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    let currentIdentity = try artifactInspector.inspect(at: url)
    guard currentIdentity == candidate.artifactIdentity else { return false }
    try Task.checkCancellation()

    let tombstone = parentURL.appending(
      path: retirementName(for: candidate),
      directoryHint: candidate.artifactIdentity.fileType == .directory
        ? .isDirectory : .notDirectory
    )
    guard !fileManager.fileExists(atPath: tombstone.path) else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a cleanup tombstone already exists"
      )
    }
    try fileManager.moveItem(at: url, to: tombstone)
    try syncDirectory(parentURL)

    // Rename is the commit point. Finish or leave an allowlisted tombstone for
    // the next recovery/review pass; never reactivate the retired artifact.
    try fileManager.removeItem(at: tombstone)
    try syncDirectory(parentURL)
    return true
  }

  private func withBundleLocks<T>(
    rootURL: URL,
    bundleURL: URL,
    machineID: UUID,
    operation: () throws -> T
  ) throws -> T {
    let libraryLock = try acquireLibraryLock(rootURL: rootURL)
    do {
      guard
        let runtimeLock = try AdvisoryFileLock.acquire(
          at: bundleURL.appending(path: VirtualMachineLibrary.runtimeLockFilename)
        )
      else {
        throw MacVirtualMachineRuntimeError.ownedElsewhere(machineID)
      }
      defer { runtimeLock.release() }
      let value = try operation()
      libraryLock.release()
      return value
    } catch {
      libraryLock.release()
      throw error
    }
  }

  private func acquireLibraryLock(
    rootURL: URL
  ) throws -> AdvisoryFileLockLease {
    guard
      let lock = try AdvisoryFileLock.acquire(
        at: rootURL.appending(path: VirtualMachineLibrary.operationLockFilename)
      )
    else {
      throw VirtualMachineStorageReclamationError.libraryInUse
    }
    return lock
  }

  private func currentManifest(
    in bundleURL: URL,
    expectedID: UUID
  ) throws -> VirtualMachineManifest {
    let data = try Data(
      contentsOf: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename)
    )
    let manifest = try JSONDecoder().decode(
      VirtualMachineManifest.self,
      from: data
    )
    guard manifest.id == expectedID else {
      throw VirtualMachineModelError.bundleIdentifierMismatch(
        expected: expectedID,
        bundleName: bundleURL.lastPathComponent
      )
    }
    return manifest
  }

  private func manifestFingerprint(
    _ manifest: VirtualMachineManifest
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(manifest)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private func classifyLibraryEntry(
    _ name: String
  ) -> VirtualMachineStorageResidueKind? {
    if matchesTwoUUIDs(
      name,
      prefix: VirtualMachineLibrary.deletionTombstonePrefix,
      suffix: VirtualMachineLibrary.deletionTombstoneSuffix
    ) {
      return .deletionTombstone
    }
    if matchesTwoUUIDs(
      name,
      prefix: VirtualMachineLibrary.cloneStagingPrefix,
      suffix: VirtualMachineLibrary.cloneStagingSuffix
    ) {
      return .cloneStaging
    }
    if matchesTwoUUIDs(
      name,
      prefix: VirtualMachineLibrary.importStagingPrefix,
      suffix: VirtualMachineLibrary.importStagingSuffix
    ) {
      return .importStaging
    }
    guard name.hasPrefix("."), name.count == 1 + 36 + 9 + 36 else {
      return nil
    }
    let start = name.index(after: name.startIndex)
    let firstEnd = name.index(start, offsetBy: 36)
    guard name[firstEnd...].hasPrefix(".partial-") else { return nil }
    let secondStart = name.index(firstEnd, offsetBy: 9)
    guard UUID(uuidString: String(name[start..<firstEnd])) != nil,
      UUID(uuidString: String(name[secondStart...])) != nil
    else {
      return nil
    }
    return .draftStaging
  }

  private func classifyBundleEntry(
    _ name: String,
    manifest: VirtualMachineManifest
  ) -> (
    kind: VirtualMachineStorageResidueKind,
    expectedType: VirtualMachineStorageArtifactFileType
  )? {
    if matchesOneUUID(
      name,
      prefix: VirtualMachineLibrary.installationStagingPrefix,
      suffix: VirtualMachineLibrary.installationStagingSuffix
    ) {
      return (.installationStaging, .directory)
    }
    if matchesOneUUID(
      name,
      prefix: ".\(MacPlatformArtifactURLs.directoryName).partial-",
      suffix: ""
    ) {
      return (.platformStaging, .directory)
    }
    if [
      MacVirtualMachineSavedStateStore.stagingSuffix,
      MacVirtualMachineSavedStateStore.restoringSuffix,
      MacVirtualMachineSavedStateStore.discardingSuffix,
    ].contains(where: {
      matchesOneUUID(
        name,
        prefix: MacVirtualMachineSavedStateStore.stagingPrefix,
        suffix: $0
      )
    }) {
      return (.savedStateTransaction, .directory)
    }
    if matchesOneUUID(
      name,
      prefix: ".SharedDirectories-",
      suffix: ".partial"
    ) {
      return (.sharedDirectoriesStaging, .regularFile)
    }
    if name == VirtualMachineLibrary.installationInstalledDirectoryName,
      manifest.installState != .installing,
      !manifest.diskImagePath.hasPrefix(
        "\(VirtualMachineLibrary.installationInstalledDirectoryName)/"
      )
    {
      return (.orphanedInstalledMedia, .directory)
    }
    return nil
  }

  private func matchesOneUUID(
    _ name: String,
    prefix: String,
    suffix: String
  ) -> Bool {
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    guard start <= end else { return false }
    return UUID(uuidString: String(name[start..<end])) != nil
  }

  private func matchesTwoUUIDs(
    _ name: String,
    prefix: String,
    suffix: String
  ) -> Bool {
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    let body = name[start..<end]
    guard body.count == 73 else { return false }
    let divider = body.index(body.startIndex, offsetBy: 36)
    guard body[divider] == "-" else { return false }
    let second = body.index(after: divider)
    return UUID(uuidString: String(body[..<divider])) != nil
      && UUID(uuidString: String(body[second...])) != nil
  }

  private func retirementName(
    for candidate: VirtualMachineStorageResidueCandidate
  ) -> String {
    let token = UUID().uuidString.lowercased()
    guard candidate.machineID != nil else {
      return
        "\(VirtualMachineLibrary.deletionTombstonePrefix)reclamation-\(token)\(VirtualMachineLibrary.deletionTombstoneSuffix)"
    }
    switch candidate.kind {
    case .savedStateTransaction:
      return
        "\(MacVirtualMachineSavedStateStore.stagingPrefix)\(token)\(MacVirtualMachineSavedStateStore.discardingSuffix)"
    case .sharedDirectoriesStaging:
      return ".SharedDirectories-\(token).partial"
    case .platformStaging:
      return ".\(MacPlatformArtifactURLs.directoryName).partial-\(token)"
    default:
      return
        "\(VirtualMachineLibrary.installationStagingPrefix)\(token)\(VirtualMachineLibrary.installationStagingSuffix)"
    }
  }

  private func planningIssue(
    id: String,
    machineID: UUID?,
    message: String
  ) -> VirtualMachineStorageReclamationPlanningIssue {
    VirtualMachineStorageReclamationPlanningIssue(
      id: id,
      category: .interruptedResidue,
      machineID: machineID,
      message: message
    )
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

  private func partial(
    result: VirtualMachineStorageReclamationBatchResult,
    remaining: ArraySlice<VirtualMachineStorageResidueCandidate>
  ) -> VirtualMachineStorageReclamationBatchPartialCompletionError {
    VirtualMachineStorageReclamationBatchPartialCompletionError(
      result: result,
      remainingCandidateIDs: remaining.map(\.id)
    )
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
