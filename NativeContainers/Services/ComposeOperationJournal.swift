import Darwin
import Foundation

enum ComposeOperationRecoveryDisposition: String, Equatable, Sendable {
  case manualReviewRequired
}

enum ComposeOperationJournalPhase: String, CaseIterable, Codable, Equatable, Sendable {
  case prepared
  case executing
  case verifying
  case finished

  fileprivate var order: Int {
    switch self {
    case .prepared: 0
    case .executing: 1
    case .verifying: 2
    case .finished: 3
    }
  }
}

struct ComposeOperationJournalProgress: Equatable, Sendable {
  let phase: ComposeOperationJournalPhase
  let completedStepTokens: [String]

  init(
    phase: ComposeOperationJournalPhase,
    completedStepTokens: [String] = []
  ) {
    self.phase = phase
    self.completedStepTokens = completedStepTokens
  }
}

struct ComposeOperationJournalEntry: Equatable, Sendable {
  let operationID: UUID
  let planID: UUID
  let action: ComposeProjectLifecycleAction
  let projectName: String
  let preparedAt: Date
  let sourceFileSHA256: String
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let composeBinarySHA256: String
  let composeSourceRevision: String
  let environmentSHA256: String
  let removeOrphans: Bool
  let removeVolumes: Bool
  let affectedContainerCount: Int
  let affectedVolumeCount: Int
  let affectedNetworkCount: Int
  let orphanContainerCount: Int
  let phase: ComposeOperationJournalPhase
  let plannedStepTokens: [String]
  let completedStepTokens: [String]

  init(
    operationID: UUID = UUID(),
    planID: UUID,
    action: ComposeProjectLifecycleAction,
    projectName: String,
    preparedAt: Date = Date(),
    sourceFileSHA256: String,
    fullConfigurationSHA256: String,
    activeConfigurationSHA256: String,
    composeBinarySHA256: String,
    composeSourceRevision: String,
    environmentSHA256: String,
    removeOrphans: Bool,
    removeVolumes: Bool,
    affectedContainerCount: Int,
    affectedVolumeCount: Int,
    affectedNetworkCount: Int,
    orphanContainerCount: Int,
    phase: ComposeOperationJournalPhase = .prepared,
    plannedStepTokens: [String],
    completedStepTokens: [String] = []
  ) {
    self.operationID = operationID
    self.planID = planID
    self.action = action
    self.projectName = projectName
    self.preparedAt = preparedAt
    self.sourceFileSHA256 = sourceFileSHA256
    self.fullConfigurationSHA256 = fullConfigurationSHA256
    self.activeConfigurationSHA256 = activeConfigurationSHA256
    self.composeBinarySHA256 = composeBinarySHA256
    self.composeSourceRevision = composeSourceRevision
    self.environmentSHA256 = environmentSHA256
    self.removeOrphans = removeOrphans
    self.removeVolumes = removeVolumes
    self.affectedContainerCount = affectedContainerCount
    self.affectedVolumeCount = affectedVolumeCount
    self.affectedNetworkCount = affectedNetworkCount
    self.orphanContainerCount = orphanContainerCount
    self.phase = phase
    self.plannedStepTokens = plannedStepTokens
    self.completedStepTokens = completedStepTokens
  }

  init(
    operationID: UUID = UUID(),
    plan: ComposeProjectPlan,
    preparedAt: Date = Date()
  ) {
    self.init(
      operationID: operationID,
      planID: plan.id,
      action: plan.options.action,
      projectName: plan.options.projectName,
      preparedAt: preparedAt,
      sourceFileSHA256: plan.source.fileIdentity.sha256,
      fullConfigurationSHA256: plan.fullConfigurationSHA256,
      activeConfigurationSHA256: plan.activeConfigurationSHA256,
      composeBinarySHA256: plan.composeBinarySHA256,
      composeSourceRevision: plan.composeSourceRevision,
      environmentSHA256: plan.environmentSHA256,
      removeOrphans: plan.options.removeOrphans,
      removeVolumes: plan.options.removeVolumes,
      affectedContainerCount: plan.containerActions.count,
      affectedVolumeCount: plan.volumeActions.count,
      affectedNetworkCount: plan.networkActions.count,
      orphanContainerCount: plan.orphanContainerIDs.count,
      plannedStepTokens: plan.executionStepTokens
    )
  }
}

struct ComposeOperationRecoverySnapshot: Equatable, Identifiable, Sendable {
  let schemaVersion: Int
  let operationID: UUID
  let planID: UUID
  let action: ComposeProjectLifecycleAction
  let projectName: String
  let preparedAt: Date
  let sourceFileSHA256: String
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let composeBinarySHA256: String
  let composeSourceRevision: String
  let environmentSHA256: String
  let removeOrphans: Bool
  let removeVolumes: Bool
  let affectedContainerCount: Int
  let affectedVolumeCount: Int
  let affectedNetworkCount: Int
  let orphanContainerCount: Int
  let phase: ComposeOperationJournalPhase
  let plannedStepTokens: [String]
  let completedStepTokens: [String]

  var id: UUID { operationID }
  var recoveryDisposition: ComposeOperationRecoveryDisposition { .manualReviewRequired }
  var allowsAutomaticExecution: Bool { false }
  var isLegacyRecord: Bool { schemaVersion < 3 }

  var completedContainerIDs: [String] {
    completedStepTokens.filter { $0.hasPrefix("container-") }
  }

  var completedNetworkNames: [String] {
    completedStepTokens.filter { $0.hasPrefix("network-") }
  }

  var completedVolumeNames: [String] {
    completedStepTokens.filter { $0.hasPrefix("volume-") }
  }
}

enum ComposeOperationJournalError: LocalizedError, Equatable, Sendable {
  case unsafeDirectory(String)
  case unsafeRecord(name: String, reason: String)
  case recordTooLarge(Int64)
  case recordAlreadyExists(UUID)
  case invalidRecord(String)
  case invalidProgress(String)
  case staleProgress(
    expected: ComposeOperationJournalPhase,
    actual: ComposeOperationJournalPhase
  )
  case unsupportedSchema(Int)
  case ioFailure(operation: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .unsafeDirectory(let reason):
      "The Compose operation journal directory is unsafe: \(reason)"
    case .unsafeRecord(let name, let reason):
      "The Compose operation journal record \(name) is unsafe: \(reason)"
    case .recordTooLarge(let byteCount):
      "The Compose operation journal record exceeds the bounded size limit (\(byteCount) bytes)."
    case .recordAlreadyExists(let operationID):
      "A pending Compose operation record already exists for \(operationID.uuidString.lowercased())."
    case .invalidRecord(let reason):
      "The Compose operation journal record is invalid: \(reason)"
    case .invalidProgress(let reason):
      "The Compose operation journal progress is invalid: \(reason)"
    case .staleProgress(let expected, let actual):
      "The pending Compose operation moved from \(expected.rawValue) to \(actual.rawValue)."
    case .unsupportedSchema(let version):
      "The Compose operation journal schema \(version) is not supported."
    case .ioFailure(let operation, let code):
      "The Compose operation journal could not \(operation) (POSIX error \(code))."
    }
  }
}

protocol ComposeOperationJournaling: Sendable {
  func persistPending(_ entry: ComposeOperationJournalEntry) async throws
  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws
  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot]
  func discardPendingAfterReview(operationID: UUID) async throws
}

protocol ComposeOperationJournalDurabilitySyncing: Sendable {
  func syncFile(descriptor: Int32) throws
  func syncDirectory(descriptor: Int32) throws
}

struct DarwinComposeOperationJournalDurabilitySyncer:
  ComposeOperationJournalDurabilitySyncing
{
  func syncFile(descriptor: Int32) throws {
    if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
      return
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw ComposeOperationJournalError.ioFailure(
        operation: "synchronize a pending record",
        code: errno
      )
    }
  }

  func syncDirectory(descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw ComposeOperationJournalError.ioFailure(
        operation: "synchronize the journal directory",
        code: errno
      )
    }
  }
}

actor ComposeOperationJournal: ComposeOperationJournaling {
  static let maximumRecordByteCount: Int64 = 64 * 1_024

  private static let schemaVersion = 3
  private static let recordSuffix = ".json"
  private static let temporaryPrefix = ".pending-"

  private let directoryURL: URL
  private let effectiveUserID: uid_t
  private let durabilitySyncer: any ComposeOperationJournalDurabilitySyncing
  private let fileManager: FileManager

  init(
    directoryURL: URL,
    effectiveUserID: uid_t = Darwin.geteuid(),
    durabilitySyncer: any ComposeOperationJournalDurabilitySyncing =
      DarwinComposeOperationJournalDurabilitySyncer(),
    fileManager: FileManager = .default
  ) {
    var directoryPath = directoryURL.path(percentEncoded: false)
    while directoryPath.count > 1 && directoryPath.hasSuffix("/") {
      directoryPath.removeLast()
    }
    self.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: false)
    self.effectiveUserID = effectiveUserID
    self.durabilitySyncer = durabilitySyncer
    self.fileManager = fileManager
  }

  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {
    try validate(entry)
    let record = StoredRecord(entry: entry)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(record)
    guard data.count <= Self.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(data.count))
    }

    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: true) else {
      throw ComposeOperationJournalError.unsafeDirectory("the directory could not be created")
    }
    defer { Darwin.close(directoryDescriptor) }

    let finalName = Self.recordFilename(for: entry.operationID)
    if let metadata = try entryMetadata(
      named: finalName,
      directoryDescriptor: directoryDescriptor
    ) {
      try validateRecordMetadata(metadata, name: finalName)
      throw ComposeOperationJournalError.recordAlreadyExists(entry.operationID)
    }

    let temporaryName =
      "\(Self.temporaryPrefix)\(entry.operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    var temporaryExists = false
    defer {
      if temporaryExists {
        _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
      }
    }

    let recordDescriptor = Darwin.openat(
      directoryDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard recordDescriptor >= 0 else {
      throw posixError("create a pending record")
    }
    temporaryExists = true
    var recordDescriptorIsOpen = true
    defer {
      if recordDescriptorIsOpen {
        Darwin.close(recordDescriptor)
      }
    }

    guard Darwin.fchmod(recordDescriptor, mode_t(0o600)) == 0 else {
      throw posixError("make a pending record owner-private")
    }
    var temporaryMetadata = stat()
    guard Darwin.fstat(recordDescriptor, &temporaryMetadata) == 0 else {
      throw posixError("inspect a pending record")
    }
    try validateRecordSecurityMetadata(temporaryMetadata, name: temporaryName)
    try writeAll(data, descriptor: recordDescriptor)
    try durabilitySyncer.syncFile(descriptor: recordDescriptor)

    guard Darwin.close(recordDescriptor) == 0 else {
      recordDescriptorIsOpen = false
      throw posixError("close a pending record")
    }
    recordDescriptorIsOpen = false

    guard
      Darwin.renameatx_np(
        directoryDescriptor,
        temporaryName,
        directoryDescriptor,
        finalName,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      let code = errno
      if code == EEXIST,
        let metadata = try entryMetadata(
          named: finalName,
          directoryDescriptor: directoryDescriptor
        )
      {
        try validateRecordMetadata(metadata, name: finalName)
        throw ComposeOperationJournalError.recordAlreadyExists(entry.operationID)
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "publish a pending record atomically",
        code: code
      )
    }
    temporaryExists = false
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      throw ComposeOperationJournalError.invalidRecord("the pending operation is missing")
    }
    defer { Darwin.close(directoryDescriptor) }

    let name = Self.recordFilename(for: operationID)
    let current = try readSnapshot(
      named: name,
      expectedOperationID: operationID,
      directoryDescriptor: directoryDescriptor
    )
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

    let updated = ComposeOperationJournalEntry(
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
    try validate(updated)

    let record = StoredRecord(entry: updated)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(record)
    guard data.count <= Self.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(data.count))
    }

    guard
      let metadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      throw ComposeOperationJournalError.invalidRecord(
        "the pending operation disappeared before its progress was saved"
      )
    }
    try validateRecordMetadata(metadata, name: name)
    try replacePendingRecord(
      data,
      named: name,
      operationID: operationID,
      directoryDescriptor: directoryDescriptor
    )
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      return []
    }
    defer { Darwin.close(directoryDescriptor) }

    let names: [String]
    do {
      names = try fileManager.contentsOfDirectory(atPath: directoryURL.path(percentEncoded: false))
    } catch {
      throw posixError("enumerate pending records")
    }

    var snapshots: [ComposeOperationRecoverySnapshot] = []
    for name in names where name.hasSuffix(Self.recordSuffix) {
      guard let operationID = Self.operationID(fromRecordFilename: name) else {
        throw ComposeOperationJournalError.invalidRecord(
          "an unexpected record filename is present"
        )
      }
      snapshots.append(
        try readSnapshot(
          named: name,
          expectedOperationID: operationID,
          directoryDescriptor: directoryDescriptor
        )
      )
    }

    return snapshots.sorted {
      if $0.preparedAt != $1.preparedAt {
        return $0.preparedAt < $1.preparedAt
      }
      return $0.operationID.uuidString < $1.operationID.uuidString
    }
  }

  func discardPendingAfterReview(operationID: UUID) async throws {
    guard let directoryDescriptor = try openJournalDirectory(createIfMissing: false) else {
      return
    }
    defer { Darwin.close(directoryDescriptor) }

    let name = Self.recordFilename(for: operationID)
    guard
      let metadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      return
    }
    try validateRecordMetadata(metadata, name: name)

    guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 else {
      throw posixError("discard a reviewed pending record")
    }
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  static func recordFilename(for operationID: UUID) -> String {
    "\(operationID.uuidString.lowercased())\(recordSuffix)"
  }

  private static func legacyStepTokens(prefix: String, count: Int) -> [String] {
    guard count > 0 else { return [] }
    return (1...count).map {
      "\(prefix)-\(String(format: "%04d", $0))"
    }
  }

  private func replacePendingRecord(
    _ data: Data,
    named name: String,
    operationID: UUID,
    directoryDescriptor: Int32
  ) throws {
    let temporaryName =
      "\(Self.temporaryPrefix)update-\(operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
    var temporaryExists = false
    defer {
      if temporaryExists {
        _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
      }
    }

    let descriptor = Darwin.openat(
      directoryDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw posixError("create a pending progress update")
    }
    temporaryExists = true
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen {
        Darwin.close(descriptor)
      }
    }

    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
      throw posixError("make a pending progress update owner-private")
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw posixError("inspect a pending progress update")
    }
    try validateRecordSecurityMetadata(metadata, name: temporaryName)
    try writeAll(data, descriptor: descriptor)
    try durabilitySyncer.syncFile(descriptor: descriptor)

    guard Darwin.close(descriptor) == 0 else {
      descriptorIsOpen = false
      throw posixError("close a pending progress update")
    }
    descriptorIsOpen = false

    guard
      Darwin.renameat(
        directoryDescriptor,
        temporaryName,
        directoryDescriptor,
        name
      ) == 0
    else {
      throw posixError("publish a pending progress update atomically")
    }
    temporaryExists = false
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
  }

  private func readSnapshot(
    named name: String,
    expectedOperationID: UUID,
    directoryDescriptor: Int32
  ) throws -> ComposeOperationRecoverySnapshot {
    guard
      let pathMetadata = try entryMetadata(
        named: name,
        directoryDescriptor: directoryDescriptor
      )
    else {
      throw ComposeOperationJournalError.invalidRecord("a pending record disappeared")
    }
    try validateRecordMetadata(pathMetadata, name: name)

    let descriptor = Darwin.openat(
      directoryDescriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        throw ComposeOperationJournalError.unsafeRecord(
          name: name,
          reason: "symbolic links are not allowed"
        )
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "open a pending record",
        code: code
      )
    }
    defer { Darwin.close(descriptor) }

    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
      throw posixError("inspect an opened pending record")
    }
    try validateRecordMetadata(openedMetadata, name: name)
    guard sameFile(pathMetadata, openedMetadata) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record changed while it was opened"
      )
    }

    let data = try readAll(
      descriptor: descriptor,
      expectedByteCount: Int(openedMetadata.st_size),
      name: name
    )
    var finalMetadata = stat()
    guard Darwin.fstat(descriptor, &finalMetadata) == 0 else {
      throw posixError("reinspect a pending record")
    }
    guard stableFile(openedMetadata, finalMetadata) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record changed while it was read"
      )
    }

    let record: StoredRecord
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      record = try decoder.decode(StoredRecord.self, from: data)
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
        legacyContainerIDs.allSatisfy({
          Self.isSafeIdentifier($0, maximumByteCount: 256)
        }),
        legacyNetworkNames.allSatisfy({
          Self.isSafeIdentifier($0, maximumByteCount: 256)
        }),
        legacyVolumeNames.allSatisfy({
          Self.isSafeIdentifier($0, maximumByteCount: 256)
        })
      else {
        throw ComposeOperationJournalError.invalidRecord(
          "the legacy progress summary is invalid"
        )
      }
      let containerTokens = Self.legacyStepTokens(
        prefix: "container",
        count: record.affectedContainerCount
      )
      let networkTokens = Self.legacyStepTokens(
        prefix: "network",
        count: record.affectedNetworkCount
      )
      let volumeTokens = Self.legacyStepTokens(
        prefix: "volume",
        count: record.affectedVolumeCount
      )
      plannedStepTokens = containerTokens + networkTokens + volumeTokens
      completedStepTokens =
        Array(containerTokens.prefix(legacyContainerIDs.count))
        + Array(networkTokens.prefix(legacyNetworkNames.count))
        + Array(volumeTokens.prefix(legacyVolumeNames.count))
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
    guard Self.isSHA256(entry.sourceFileSHA256),
      Self.isSHA256(entry.fullConfigurationSHA256),
      Self.isSHA256(entry.activeConfigurationSHA256),
      Self.isSHA256(entry.composeBinarySHA256),
      Self.isSHA256(entry.environmentSHA256)
    else {
      throw ComposeOperationJournalError.invalidRecord(
        "a source, executable, environment, or configuration fingerprint is invalid"
      )
    }
    guard Self.isSafeIdentifier(entry.composeSourceRevision, maximumByteCount: 128) else {
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
      plannedStepTokens.allSatisfy(Self.isOpaqueStepToken)
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

  private func openJournalDirectory(createIfMissing: Bool) throws -> Int32? {
    guard directoryURL.isFileURL, !directoryURL.lastPathComponent.isEmpty else {
      throw ComposeOperationJournalError.unsafeDirectory("the location is not a local directory")
    }

    let path = directoryURL.path(percentEncoded: false)
    var pathMetadata = stat()
    if Darwin.lstat(path, &pathMetadata) != 0 {
      let code = errno
      if code == ENOENT {
        guard createIfMissing else { return nil }
        try createJournalDirectory()
        guard Darwin.lstat(path, &pathMetadata) == 0 else {
          throw posixError("inspect the created journal directory")
        }
      } else {
        throw ComposeOperationJournalError.ioFailure(
          operation: "inspect the journal directory",
          code: code
        )
      }
    }
    try validateDirectoryMetadata(pathMetadata)

    let descriptor = Darwin.open(
      path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        throw ComposeOperationJournalError.unsafeDirectory(
          "symbolic links are not allowed"
        )
      }
      throw ComposeOperationJournalError.ioFailure(
        operation: "open the journal directory",
        code: code
      )
    }

    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
      Darwin.close(descriptor)
      throw posixError("inspect the opened journal directory")
    }
    do {
      try validateDirectoryMetadata(openedMetadata)
      guard sameFile(pathMetadata, openedMetadata) else {
        throw ComposeOperationJournalError.unsafeDirectory(
          "the directory changed while it was opened"
        )
      }
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func createJournalDirectory() throws {
    let parentURL = directoryURL.deletingLastPathComponent()
    let name = directoryURL.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else {
      throw ComposeOperationJournalError.unsafeDirectory("the directory name is invalid")
    }

    let parentDescriptor = Darwin.open(
      parentURL.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else {
      throw posixError("open the journal parent directory")
    }
    defer { Darwin.close(parentDescriptor) }

    if Darwin.mkdirat(parentDescriptor, name, mode_t(0o700)) != 0, errno != EEXIST {
      throw posixError("create the journal directory")
    }

    let directoryDescriptor = Darwin.openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      throw posixError("open the created journal directory")
    }
    defer { Darwin.close(directoryDescriptor) }

    var metadata = stat()
    guard Darwin.fstat(directoryDescriptor, &metadata) == 0 else {
      throw posixError("inspect the created journal directory")
    }
    if metadata.st_uid == effectiveUserID,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    {
      guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
        throw posixError("make the journal directory owner-private")
      }
    }
    try durabilitySyncer.syncDirectory(descriptor: directoryDescriptor)
    try durabilitySyncer.syncDirectory(descriptor: parentDescriptor)
  }

  private func entryMetadata(
    named name: String,
    directoryDescriptor: Int32
  ) throws -> stat? {
    var metadata = stat()
    if Darwin.fstatat(
      directoryDescriptor,
      name,
      &metadata,
      AT_SYMLINK_NOFOLLOW
    ) == 0 {
      return metadata
    }
    let code = errno
    guard code == ENOENT else {
      throw ComposeOperationJournalError.ioFailure(
        operation: "inspect a pending record",
        code: code
      )
    }
    return nil
  }

  private func validateDirectoryMetadata(_ metadata: stat) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal location is not a directory"
      )
    }
    guard metadata.st_uid == effectiveUserID else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal directory is not owned by the current user"
      )
    }
    guard metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
      throw ComposeOperationJournalError.unsafeDirectory(
        "the journal directory permissions must be 0700"
      )
    }
  }

  private func validateRecordMetadata(_ metadata: stat, name: String) throws {
    try validateRecordSecurityMetadata(metadata, name: name)
    guard metadata.st_size > 0 else {
      throw ComposeOperationJournalError.invalidRecord("a pending record is empty")
    }
    guard metadata.st_size <= Self.maximumRecordByteCount else {
      throw ComposeOperationJournalError.recordTooLarge(Int64(metadata.st_size))
    }
  }

  private func validateRecordSecurityMetadata(
    _ metadata: stat,
    name: String
  ) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "only regular files are allowed"
      )
    }
    guard metadata.st_uid == effectiveUserID else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "the record is not owned by the current user"
      )
    }
    guard metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "record permissions must be 0600"
      )
    }
    guard metadata.st_nlink == 1 else {
      throw ComposeOperationJournalError.unsafeRecord(
        name: name,
        reason: "hard-linked records are not allowed"
      )
    }
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if written < 0 {
          if errno == EINTR {
            continue
          }
          throw posixError("write a pending record")
        }
        guard written > 0 else {
          throw ComposeOperationJournalError.ioFailure(
            operation: "write a pending record",
            code: EIO
          )
        }
        offset += written
      }
    }
  }

  private func readAll(
    descriptor: Int32,
    expectedByteCount: Int,
    name: String
  ) throws -> Data {
    var data = Data()
    data.reserveCapacity(expectedByteCount)
    var buffer = [UInt8](repeating: 0, count: min(8_192, expectedByteCount))

    while data.count < expectedByteCount {
      let requested = min(buffer.count, expectedByteCount - data.count)
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requested)
      }
      if readCount < 0 {
        if errno == EINTR {
          continue
        }
        throw posixError("read a pending record")
      }
      guard readCount > 0 else {
        throw ComposeOperationJournalError.unsafeRecord(
          name: name,
          reason: "the record was truncated while it was read"
        )
      }
      data.append(contentsOf: buffer.prefix(readCount))
    }
    return data
  }

  private func posixError(_ operation: String) -> ComposeOperationJournalError {
    ComposeOperationJournalError.ioFailure(operation: operation, code: errno)
  }

  private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
    sameFile(lhs, rhs)
      && lhs.st_size == rhs.st_size
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func operationID(fromRecordFilename name: String) -> UUID? {
    guard name.hasSuffix(recordSuffix) else { return nil }
    let identifier = String(name.dropLast(recordSuffix.count))
    guard identifier == identifier.lowercased() else { return nil }
    return UUID(uuidString: identifier)
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private static func isSafeIdentifier(
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

  private static func isOpaqueStepToken(_ value: String) -> Bool {
    let prefixes = ["compose-up-", "container-", "network-", "volume-"]
    guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return false }
    let suffix = value.dropFirst(prefix.count)
    let bytes = suffix.utf8
    return bytes.count == 4
      && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
      && suffix != "0000"
  }
}

private struct StoredRecord: Codable {
  let schemaVersion: Int
  let operationID: UUID
  let planID: UUID
  let action: String
  let projectName: String
  let preparedAt: Date
  let sourceFileSHA256: String
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let composeBinarySHA256: String
  let composeSourceRevision: String
  let environmentSHA256: String
  let removeOrphans: Bool
  let removeVolumes: Bool
  let affectedContainerCount: Int
  let affectedVolumeCount: Int
  let affectedNetworkCount: Int
  let orphanContainerCount: Int
  let phase: ComposeOperationJournalPhase
  let plannedStepTokens: [String]?
  let completedStepTokens: [String]?
  let completedContainerIDs: [String]?
  let completedNetworkNames: [String]?
  let completedVolumeNames: [String]?

  init(entry: ComposeOperationJournalEntry) {
    schemaVersion = 3
    operationID = entry.operationID
    planID = entry.planID
    action = entry.action.rawValue
    projectName = entry.projectName
    preparedAt = entry.preparedAt
    sourceFileSHA256 = entry.sourceFileSHA256
    fullConfigurationSHA256 = entry.fullConfigurationSHA256
    activeConfigurationSHA256 = entry.activeConfigurationSHA256
    composeBinarySHA256 = entry.composeBinarySHA256
    composeSourceRevision = entry.composeSourceRevision
    environmentSHA256 = entry.environmentSHA256
    removeOrphans = entry.removeOrphans
    removeVolumes = entry.removeVolumes
    affectedContainerCount = entry.affectedContainerCount
    affectedVolumeCount = entry.affectedVolumeCount
    affectedNetworkCount = entry.affectedNetworkCount
    orphanContainerCount = entry.orphanContainerCount
    phase = entry.phase
    plannedStepTokens = entry.plannedStepTokens
    completedStepTokens = entry.completedStepTokens
    completedContainerIDs = nil
    completedNetworkNames = nil
    completedVolumeNames = nil
  }
}
