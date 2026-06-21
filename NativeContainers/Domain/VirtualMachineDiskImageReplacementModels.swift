import Foundation

enum VirtualMachineDiskImageReplacementOperation:
  String,
  Codable,
  CaseIterable,
  Sendable
{
  case rawToASIF
  case rewriteASIF

  var sourceFormat: VirtualMachineDiskImageFormat {
    switch self {
    case .rawToASIF:
      .raw
    case .rewriteASIF:
      .asif
    }
  }

  var destinationFormat: VirtualMachineDiskImageFormat {
    .asif
  }
}

enum VirtualMachineDiskImageReplacementPhase:
  String,
  Codable,
  CaseIterable,
  Sendable
{
  case planned
  case terminationQuarantined
  case converted
  case promoted
  case manifestUpdated
}

enum VirtualMachineDiskImageReplacementTerminationQuarantine:
  String,
  Codable,
  Sendable
{
  case untilAppRestart
  case untilHostRestart
  case manualIntervention
}

enum VirtualMachineDiskImageReplacementArtifacts {
  static let journalFilename = ".DiskImageMigration.json"
  static let stagingPrefix = ".DiskImageMigration-"
  static let stagingSuffix = ".asif.partial"

  static func isControlArtifact(relativePath: String) -> Bool {
    let name = NSString(string: relativePath).lastPathComponent
    return name == journalFilename
      || (name.hasPrefix(stagingPrefix) && name.hasSuffix(stagingSuffix))
  }
}

struct VirtualMachineDiskImageReplacementJournal:
  Codable,
  Equatable,
  Sendable
{
  static let currentVersion = 2
  static let legacyVersion = 1

  let version: Int
  let operation: VirtualMachineDiskImageReplacementOperation
  let operationID: UUID
  let machineID: UUID
  let sourcePath: String
  let destinationPath: String
  let stagingPath: String
  let sourceFormat: VirtualMachineDiskImageFormat
  let destinationFormat: VirtualMachineDiskImageFormat
  let sourceIdentity: VirtualMachineStorageArtifactIdentity
  let sourceLogicalBytes: UInt64
  var destinationIdentity: VirtualMachineStorageArtifactIdentity?
  var phase: VirtualMachineDiskImageReplacementPhase
  var terminationQuarantine: VirtualMachineDiskImageReplacementTerminationQuarantine?
  var hostBootIdentifier: String?

  init(
    version: Int = Self.currentVersion,
    operation: VirtualMachineDiskImageReplacementOperation = .rawToASIF,
    operationID: UUID,
    machineID: UUID,
    sourcePath: String,
    destinationPath: String,
    stagingPath: String,
    sourceFormat: VirtualMachineDiskImageFormat? = nil,
    destinationFormat: VirtualMachineDiskImageFormat? = nil,
    sourceIdentity: VirtualMachineStorageArtifactIdentity,
    sourceLogicalBytes: UInt64,
    destinationIdentity: VirtualMachineStorageArtifactIdentity?,
    phase: VirtualMachineDiskImageReplacementPhase,
    terminationQuarantine:
      VirtualMachineDiskImageReplacementTerminationQuarantine? = nil,
    hostBootIdentifier: String? = nil
  ) {
    self.version = version
    self.operation = operation
    self.operationID = operationID
    self.machineID = machineID
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.stagingPath = stagingPath
    self.sourceFormat = sourceFormat ?? operation.sourceFormat
    self.destinationFormat = destinationFormat ?? operation.destinationFormat
    self.sourceIdentity = sourceIdentity
    self.sourceLogicalBytes = sourceLogicalBytes
    self.destinationIdentity = destinationIdentity
    self.phase = phase
    self.terminationQuarantine = terminationQuarantine
    self.hostBootIdentifier = hostBootIdentifier
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case operation
    case operationID
    case machineID
    case sourcePath
    case destinationPath
    case stagingPath
    case sourceFormat
    case destinationFormat
    case sourceIdentity
    case sourceLogicalBytes
    case destinationIdentity
    case phase
    case terminationQuarantine
    case hostBootIdentifier
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    let operation =
      try container.decodeIfPresent(
        VirtualMachineDiskImageReplacementOperation.self,
        forKey: .operation
      ) ?? .rawToASIF

    self.init(
      version: version,
      operation: operation,
      operationID: try container.decode(UUID.self, forKey: .operationID),
      machineID: try container.decode(UUID.self, forKey: .machineID),
      sourcePath: try container.decode(String.self, forKey: .sourcePath),
      destinationPath: try container.decode(String.self, forKey: .destinationPath),
      stagingPath: try container.decode(String.self, forKey: .stagingPath),
      sourceFormat:
        try container.decodeIfPresent(
          VirtualMachineDiskImageFormat.self,
          forKey: .sourceFormat
        ) ?? operation.sourceFormat,
      destinationFormat:
        try container.decodeIfPresent(
          VirtualMachineDiskImageFormat.self,
          forKey: .destinationFormat
        ) ?? operation.destinationFormat,
      sourceIdentity:
        try container.decode(
          VirtualMachineStorageArtifactIdentity.self,
          forKey: .sourceIdentity
        ),
      sourceLogicalBytes:
        try container.decode(UInt64.self, forKey: .sourceLogicalBytes),
      destinationIdentity:
        try container.decodeIfPresent(
          VirtualMachineStorageArtifactIdentity.self,
          forKey: .destinationIdentity
        ),
      phase:
        try container.decode(
          VirtualMachineDiskImageReplacementPhase.self,
          forKey: .phase
        ),
      terminationQuarantine:
        try container.decodeIfPresent(
          VirtualMachineDiskImageReplacementTerminationQuarantine.self,
          forKey: .terminationQuarantine
        ),
      hostBootIdentifier:
        try container.decodeIfPresent(
          String.self,
          forKey: .hostBootIdentifier
        )
    )
  }
}

struct VirtualMachineDiskImageReplacementCommit: Equatable, Sendable {
  let sourcePath: String
  let destinationPath: String
  let sourceFormat: VirtualMachineDiskImageFormat
  let destinationFormat: VirtualMachineDiskImageFormat
  let sourceIdentity: VirtualMachineStorageArtifactIdentity
  let destinationIdentity: VirtualMachineStorageArtifactIdentity
}

struct VirtualMachineDiskImageReplacementResult: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let sourceAllocatedBytes: UInt64
  let destinationAllocatedBytes: UInt64
  let didReplace: Bool

  init(
    manifest: VirtualMachineManifest,
    sourceAllocatedBytes: UInt64,
    destinationAllocatedBytes: UInt64,
    didReplace: Bool = true
  ) {
    self.manifest = manifest
    self.sourceAllocatedBytes = sourceAllocatedBytes
    self.destinationAllocatedBytes = destinationAllocatedBytes
    self.didReplace = didReplace
  }

  var reclaimedBytes: UInt64 {
    sourceAllocatedBytes > destinationAllocatedBytes
      ? sourceAllocatedBytes - destinationAllocatedBytes
      : 0
  }
}

struct VirtualMachineDiskImageReplacementRecoveryReport:
  Equatable,
  Sendable
{
  let recoveredMachineIDs: [UUID]
  let deferredMachineIDs: [UUID]
  let failures: [VirtualMachineDiskImageReplacementRecoveryFailure]

  static let empty = Self(
    recoveredMachineIDs: [],
    deferredMachineIDs: [],
    failures: []
  )
}

struct VirtualMachineDiskImageReplacementRecoveryFailure:
  Equatable,
  Sendable
{
  let machineID: UUID
  let diagnostic: String
}

enum VirtualMachineDiskImageReplacementError:
  LocalizedError,
  Equatable,
  Sendable
{
  case unavailable
  case alreadyASIF
  case requiresASIF
  case savedStateMustBeDiscarded
  case stackedImageUnsupported
  case destinationExists(URL)
  case conversionFailed(exitCode: Int32, diagnostic: String)
  case conversionOutputTruncated
  case logicalSizeMismatch(expected: UInt64, actual: UInt64)
  case blockSizeMismatch(expected: UInt64, actual: UInt64)
  case unsafeArtifact(String)
  case staleSource
  case invalidJournal
  case converterTerminationUnconfirmed(String)
  case operationAndCleanupFailed(operation: String, cleanup: String)
  case committedCleanupPending(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual disk replacement requires macOS 27 or later."
    case .alreadyASIF:
      "This virtual machine already uses an Apple sparse image."
    case .requiresASIF:
      "Rewrite-based storage reclamation requires a standalone ASIF disk."
    case .savedStateMustBeDiscarded:
      "Discard this virtual machine’s saved state before changing its disk image."
    case .stackedImageUnsupported:
      "Stacked cache and overlay disk layers cannot be rewritten safely."
    case .destinationExists(let url):
      "The disk replacement destination already exists: \(url.lastPathComponent)"
    case .conversionFailed(let exitCode, let diagnostic):
      diagnostic.isEmpty
        ? "diskutil could not rewrite the disk image (exit \(exitCode))."
        : "diskutil could not rewrite the disk image (exit \(exitCode)): \(diagnostic)"
    case .conversionOutputTruncated:
      "diskutil produced more output than could be safely retained, so the replacement was not accepted."
    case .logicalSizeMismatch(let expected, let actual):
      "The replacement image reports \(actual) logical bytes instead of \(expected)."
    case .blockSizeMismatch(let expected, let actual):
      "The replacement image reports a \(actual)-byte block size instead of \(expected) bytes."
    case .unsafeArtifact(let reason):
      "The disk replacement stopped because an artifact was unsafe: \(reason)"
    case .staleSource:
      "The source disk changed during replacement, so the new image was not committed."
    case .invalidJournal:
      "The disk replacement journal is invalid or no longer matches this virtual machine."
    case .converterTerminationUnconfirmed(let reason):
      "The disk converter did not confirm exit, so its staging data remains quarantined: \(reason)"
    case .operationAndCleanupFailed(let operation, let cleanup):
      "Disk replacement failed (\(operation)), and its private staging cleanup also failed (\(cleanup))."
    case .committedCleanupPending(let reason):
      "The replacement disk was committed, but old-disk cleanup is pending: \(reason)"
    }
  }
}

typealias VirtualMachineDiskImageMigrationPhase =
  VirtualMachineDiskImageReplacementPhase
typealias VirtualMachineDiskImageMigrationTerminationQuarantine =
  VirtualMachineDiskImageReplacementTerminationQuarantine
typealias VirtualMachineDiskImageMigrationArtifacts =
  VirtualMachineDiskImageReplacementArtifacts
typealias VirtualMachineDiskImageMigrationJournal =
  VirtualMachineDiskImageReplacementJournal
typealias VirtualMachineDiskImageMigrationCommit =
  VirtualMachineDiskImageReplacementCommit
typealias VirtualMachineDiskImageMigrationResult =
  VirtualMachineDiskImageReplacementResult
typealias VirtualMachineDiskImageRewriteResult =
  VirtualMachineDiskImageReplacementResult
typealias VirtualMachineDiskImageMigrationRecoveryReport =
  VirtualMachineDiskImageReplacementRecoveryReport
typealias VirtualMachineDiskImageMigrationRecoveryFailure =
  VirtualMachineDiskImageReplacementRecoveryFailure
typealias VirtualMachineDiskImageMigrationError =
  VirtualMachineDiskImageReplacementError
