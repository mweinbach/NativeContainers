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

  var order: Int {
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

struct StoredComposeOperationRecord: Codable {
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
