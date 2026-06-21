import Foundation

struct ComposeOperationJournalRecordCodec: Sendable {
  static let schemaVersion = 3

  func encode(_ entry: ComposeOperationJournalEntry) throws -> Data {
    try validate(entry)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(StoredComposeOperationRecord(entry: entry))
    guard data.count <= ComposeOperationJournal.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(data.count))
    }
    return data
  }

  func decode(
    _ data: Data,
    expectedOperationID: UUID
  ) throws -> ComposeOperationRecoverySnapshot {
    let record: StoredComposeOperationRecord
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      record = try decoder.decode(StoredComposeOperationRecord.self, from: data)
    } catch {
      throw ComposeOperationJournalError.invalidRecord("the JSON payload could not be decoded")
    }

    guard record.schemaVersion == Self.schemaVersion || record.schemaVersion == 2 else {
      throw ComposeOperationJournalError.unsupportedSchema(record.schemaVersion)
    }
    guard record.operationID == expectedOperationID else {
      throw ComposeOperationJournalError.invalidRecord(
        "the operation identifier does not match its filename"
      )
    }
    guard let action = ComposeProjectLifecycleAction(rawValue: record.action) else {
      throw ComposeOperationJournalError.invalidRecord("the lifecycle action is unknown")
    }

    let plannedStepTokens: [String]
    let completedStepTokens: [String]
    if record.schemaVersion == Self.schemaVersion {
      guard let planned = record.plannedStepTokens,
        let completed = record.completedStepTokens
      else {
        throw ComposeOperationJournalError.invalidRecord(
          "the opaque execution steps are missing"
        )
      }
      plannedStepTokens = planned
      completedStepTokens = completed
    } else {
      (plannedStepTokens, completedStepTokens) = try legacyStepTokens(from: record)
    }

    let entry = ComposeOperationJournalEntry(
      operationID: record.operationID,
      planID: record.planID,
      action: action,
      projectName: record.projectName,
      preparedAt: record.preparedAt,
      sourceFileSHA256: record.sourceFileSHA256,
      fullConfigurationSHA256: record.fullConfigurationSHA256,
      activeConfigurationSHA256: record.activeConfigurationSHA256,
      composeBinarySHA256: record.composeBinarySHA256,
      composeSourceRevision: record.composeSourceRevision,
      environmentSHA256: record.environmentSHA256,
      removeOrphans: record.removeOrphans,
      removeVolumes: record.removeVolumes,
      affectedContainerCount: record.affectedContainerCount,
      affectedVolumeCount: record.affectedVolumeCount,
      affectedNetworkCount: record.affectedNetworkCount,
      orphanContainerCount: record.orphanContainerCount,
      phase: record.phase,
      plannedStepTokens: plannedStepTokens,
      completedStepTokens: completedStepTokens
    )
    try validate(entry, isLegacyRecord: record.schemaVersion == 2)

    return ComposeOperationRecoverySnapshot(
      schemaVersion: record.schemaVersion,
      operationID: entry.operationID,
      planID: entry.planID,
      action: entry.action,
      projectName: entry.projectName,
      preparedAt: entry.preparedAt,
      sourceFileSHA256: entry.sourceFileSHA256,
      fullConfigurationSHA256: entry.fullConfigurationSHA256,
      activeConfigurationSHA256: entry.activeConfigurationSHA256,
      composeBinarySHA256: entry.composeBinarySHA256,
      composeSourceRevision: entry.composeSourceRevision,
      environmentSHA256: entry.environmentSHA256,
      removeOrphans: entry.removeOrphans,
      removeVolumes: entry.removeVolumes,
      affectedContainerCount: entry.affectedContainerCount,
      affectedVolumeCount: entry.affectedVolumeCount,
      affectedNetworkCount: entry.affectedNetworkCount,
      orphanContainerCount: entry.orphanContainerCount,
      phase: entry.phase,
      plannedStepTokens: entry.plannedStepTokens,
      completedStepTokens: entry.completedStepTokens
    )
  }

  func updatedEntry(
    from current: ComposeOperationRecoverySnapshot,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) throws -> ComposeOperationJournalEntry {
    guard current.schemaVersion == Self.schemaVersion else {
      throw ComposeOperationJournalError.invalidProgress(
        "legacy journal records require manual reconciliation and cannot be resumed"
      )
    }
    guard current.phase == expectedPhase else {
      throw ComposeOperationJournalError.staleProgress(
        expected: expectedPhase,
        actual: current.phase
      )
    }
    try validateTransition(from: current, to: progress)

    return ComposeOperationJournalEntry(
      operationID: current.operationID,
      planID: current.planID,
      action: current.action,
      projectName: current.projectName,
      preparedAt: current.preparedAt,
      sourceFileSHA256: current.sourceFileSHA256,
      fullConfigurationSHA256: current.fullConfigurationSHA256,
      activeConfigurationSHA256: current.activeConfigurationSHA256,
      composeBinarySHA256: current.composeBinarySHA256,
      composeSourceRevision: current.composeSourceRevision,
      environmentSHA256: current.environmentSHA256,
      removeOrphans: current.removeOrphans,
      removeVolumes: current.removeVolumes,
      affectedContainerCount: current.affectedContainerCount,
      affectedVolumeCount: current.affectedVolumeCount,
      affectedNetworkCount: current.affectedNetworkCount,
      orphanContainerCount: current.orphanContainerCount,
      phase: progress.phase,
      plannedStepTokens: current.plannedStepTokens,
      completedStepTokens: progress.completedStepTokens
    )
  }

  private func legacyStepTokens(
    from record: StoredComposeOperationRecord
  ) throws -> ([String], [String]) {
    guard let legacyContainerIDs = record.completedContainerIDs,
      let legacyNetworkNames = record.completedNetworkNames,
      let legacyVolumeNames = record.completedVolumeNames,
      [
        record.affectedContainerCount,
        record.affectedNetworkCount,
        record.affectedVolumeCount,
      ].allSatisfy({ $0 >= 0 && $0 <= 1_024 }),
      legacyContainerIDs.count <= record.affectedContainerCount,
      legacyNetworkNames.count <= record.affectedNetworkCount,
      legacyVolumeNames.count <= record.affectedVolumeCount,
      record.affectedContainerCount + record.affectedNetworkCount
        + record.affectedVolumeCount <= 1_024,
      legacyContainerIDs.allSatisfy({ isSafeIdentifier($0, maximumByteCount: 256) }),
      legacyNetworkNames.allSatisfy({ isSafeIdentifier($0, maximumByteCount: 256) }),
      legacyVolumeNames.allSatisfy({ isSafeIdentifier($0, maximumByteCount: 256) })
    else {
      throw ComposeOperationJournalError.invalidRecord(
        "the legacy progress summary is invalid"
      )
    }
    let containerTokens = stepTokens(
      prefix: "container",
      count: record.affectedContainerCount
    )
    let networkTokens = stepTokens(
      prefix: "network",
      count: record.affectedNetworkCount
    )
    let volumeTokens = stepTokens(
      prefix: "volume",
      count: record.affectedVolumeCount
    )
    return (
      containerTokens + networkTokens + volumeTokens,
      Array(containerTokens.prefix(legacyContainerIDs.count))
        + Array(networkTokens.prefix(legacyNetworkNames.count))
        + Array(volumeTokens.prefix(legacyVolumeNames.count))
    )
  }

  private func validate(
    _ entry: ComposeOperationJournalEntry,
    isLegacyRecord: Bool = false
  ) throws {
    guard isValidComposeProjectName(entry.projectName) else {
      throw ComposeOperationJournalError.invalidRecord("the project name is invalid")
    }
    guard entry.preparedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ComposeOperationJournalError.invalidRecord("the preparation date is invalid")
    }
    guard isSHA256(entry.sourceFileSHA256),
      isSHA256(entry.fullConfigurationSHA256),
      isSHA256(entry.activeConfigurationSHA256),
      isSHA256(entry.composeBinarySHA256),
      isSHA256(entry.environmentSHA256)
    else {
      throw ComposeOperationJournalError.invalidRecord(
        "a source, executable, environment, or configuration fingerprint is invalid"
      )
    }
    guard isSafeIdentifier(entry.composeSourceRevision, maximumByteCount: 128) else {
      throw ComposeOperationJournalError.invalidRecord(
        "the Compose source revision is invalid"
      )
    }
    let counts = [
      entry.affectedContainerCount,
      entry.affectedVolumeCount,
      entry.affectedNetworkCount,
      entry.orphanContainerCount,
    ]
    guard counts.allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }) else {
      throw ComposeOperationJournalError.invalidRecord("an affected-resource count is invalid")
    }
    try validateProgress(
      phase: entry.phase,
      plannedStepTokens: entry.plannedStepTokens,
      completedStepTokens: entry.completedStepTokens,
      requireCompleteBeforeVerification: !isLegacyRecord
    )
  }

  private func validateTransition(
    from current: ComposeOperationRecoverySnapshot,
    to progress: ComposeOperationJournalProgress
  ) throws {
    guard progress.phase.order >= current.phase.order else {
      throw ComposeOperationJournalError.invalidProgress(
        "operation phases cannot move backward"
      )
    }
    guard progress.completedStepTokens.starts(with: current.completedStepTokens) else {
      throw ComposeOperationJournalError.invalidProgress(
        "completed execution steps cannot be removed or reordered"
      )
    }
    if current.phase == .finished {
      guard progress.phase == .finished,
        progress.completedStepTokens == current.completedStepTokens
      else {
        throw ComposeOperationJournalError.invalidProgress(
          "finished operation progress is immutable"
        )
      }
    }
    try validateProgress(
      phase: progress.phase,
      plannedStepTokens: current.plannedStepTokens,
      completedStepTokens: progress.completedStepTokens,
      requireCompleteBeforeVerification: true
    )
  }

  private func validateProgress(
    phase: ComposeOperationJournalPhase,
    plannedStepTokens: [String],
    completedStepTokens: [String],
    requireCompleteBeforeVerification: Bool
  ) throws {
    guard plannedStepTokens.count <= 1_024 else {
      throw ComposeOperationJournalError.invalidProgress(
        "too many execution steps were recorded"
      )
    }
    guard plannedStepTokens.count == Set(plannedStepTokens).count,
      plannedStepTokens.allSatisfy(isOpaqueStepToken)
    else {
      throw ComposeOperationJournalError.invalidProgress(
        "planned execution step tokens must be unique and opaque"
      )
    }
    guard completedStepTokens == Array(plannedStepTokens.prefix(completedStepTokens.count)) else {
      throw ComposeOperationJournalError.invalidProgress(
        "completed execution steps must be an ordered prefix of the reviewed plan"
      )
    }
    if phase == .prepared {
      guard completedStepTokens.isEmpty else {
        throw ComposeOperationJournalError.invalidProgress(
          "prepared operations cannot contain completed execution steps"
        )
      }
    }
    if requireCompleteBeforeVerification,
      phase.order >= ComposeOperationJournalPhase.verifying.order,
      completedStepTokens != plannedStepTokens
    {
      throw ComposeOperationJournalError.invalidProgress(
        "verification cannot begin before every reviewed execution step completes"
      )
    }
  }

  private func stepTokens(prefix: String, count: Int) -> [String] {
    guard count > 0 else { return [] }
    return (1...count).map {
      "\(prefix)-\(String(format: "%04d", $0))"
    }
  }

  private func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private func isSafeIdentifier(
    _ value: String,
    maximumByteCount: Int
  ) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumByteCount else { return false }
    return bytes.allSatisfy {
      ($0 >= 48 && $0 <= 57)
        || ($0 >= 65 && $0 <= 90)
        || ($0 >= 97 && $0 <= 122)
        || $0 == 45
        || $0 == 46
        || $0 == 58
        || $0 == 64
        || $0 == 95
    }
  }

  private func isOpaqueStepToken(_ value: String) -> Bool {
    let prefixes = ["compose-up-", "container-", "network-", "volume-"]
    guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return false }
    let suffix = value.dropFirst(prefix.count)
    let bytes = suffix.utf8
    return bytes.count == 4
      && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
      && suffix != "0000"
  }
}
