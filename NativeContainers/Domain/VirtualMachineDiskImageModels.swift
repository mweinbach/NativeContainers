import Foundation

enum VirtualMachineDiskImageFormat: String, Codable, CaseIterable, Sendable {
  case raw
  case asif

  var label: LocalizedStringResource {
    switch self {
    case .raw:
      "RAW"
    case .asif:
      "Apple sparse image"
    }
  }
}

struct VirtualMachineDiskImageDescriptor: Equatable, Sendable {
  let format: VirtualMachineDiskImageFormat
  let logicalBytes: UInt64
  let blockSizeBytes: UInt64

  var blockCount: UInt64 {
    logicalBytes / blockSizeBytes
  }
}

enum VirtualMachineDiskImageError: LocalizedError, Equatable, Sendable {
  case unsupportedHost(VirtualMachineDiskImageFormat)
  case unexpectedFormat(
    expected: VirtualMachineDiskImageFormat,
    actual: String
  )
  case invalidLogicalSize(UInt64)
  case inspectionFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedHost(let format):
      "The \(String(localized: format.label)) disk format requires macOS 27 or later."
    case .unexpectedFormat(let expected, let actual):
      "The disk manifest declares \(String(localized: expected.label)), but the image is \(actual)."
    case .invalidLogicalSize(let bytes):
      "The virtual disk reports an invalid logical size of \(bytes) bytes."
    case .inspectionFailed(let reason):
      "The virtual disk could not be inspected: \(reason)"
    }
  }
}

enum VirtualMachineDiskImageMigrationPhase: String, Codable, CaseIterable, Sendable {
  case planned
  case terminationQuarantined
  case converted
  case promoted
  case manifestUpdated
}

enum VirtualMachineDiskImageMigrationTerminationQuarantine:
  String,
  Codable,
  Sendable
{
  case untilAppRestart
  case untilHostRestart
  case manualIntervention
}

enum VirtualMachineDiskImageMigrationArtifacts {
  static let journalFilename = ".DiskImageMigration.json"
  static let stagingPrefix = ".DiskImageMigration-"
  static let stagingSuffix = ".asif.partial"

  static func isControlArtifact(relativePath: String) -> Bool {
    let name = NSString(string: relativePath).lastPathComponent
    return name == journalFilename
      || (name.hasPrefix(stagingPrefix) && name.hasSuffix(stagingSuffix))
  }
}

struct VirtualMachineDiskImageMigrationJournal: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let operationID: UUID
  let machineID: UUID
  let sourcePath: String
  let destinationPath: String
  let stagingPath: String
  let sourceIdentity: VirtualMachineStorageArtifactIdentity
  let sourceLogicalBytes: UInt64
  var destinationIdentity: VirtualMachineStorageArtifactIdentity?
  var phase: VirtualMachineDiskImageMigrationPhase
  var terminationQuarantine: VirtualMachineDiskImageMigrationTerminationQuarantine? = nil
  var hostBootIdentifier: String? = nil
}

struct VirtualMachineDiskImageMigrationCommit: Equatable, Sendable {
  let sourcePath: String
  let destinationPath: String
  let sourceFormat: VirtualMachineDiskImageFormat
  let destinationFormat: VirtualMachineDiskImageFormat
  let sourceIdentity: VirtualMachineStorageArtifactIdentity
  let destinationIdentity: VirtualMachineStorageArtifactIdentity
}

struct VirtualMachineDiskImageMigrationResult: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let sourceAllocatedBytes: UInt64
  let destinationAllocatedBytes: UInt64

  var reclaimedBytes: UInt64 {
    sourceAllocatedBytes > destinationAllocatedBytes
      ? sourceAllocatedBytes - destinationAllocatedBytes
      : 0
  }
}

struct VirtualMachineDiskImageMigrationRecoveryReport: Equatable, Sendable {
  let recoveredMachineIDs: [UUID]
  let deferredMachineIDs: [UUID]
  let failures: [VirtualMachineDiskImageMigrationRecoveryFailure]

  static let empty = Self(
    recoveredMachineIDs: [],
    deferredMachineIDs: [],
    failures: []
  )
}

struct VirtualMachineDiskImageMigrationRecoveryFailure: Equatable, Sendable {
  let machineID: UUID
  let diagnostic: String
}

enum VirtualMachineDiskImageMigrationError:
  LocalizedError,
  Equatable,
  Sendable
{
  case unavailable
  case alreadyASIF
  case savedStateMustBeDiscarded
  case destinationExists(URL)
  case conversionFailed(exitCode: Int32, diagnostic: String)
  case conversionOutputTruncated
  case logicalSizeMismatch(expected: UInt64, actual: UInt64)
  case unsafeArtifact(String)
  case staleSource
  case invalidJournal
  case converterTerminationUnconfirmed(String)
  case operationAndCleanupFailed(operation: String, cleanup: String)
  case committedCleanupPending(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "RAW-to-ASIF migration requires macOS 27 or later."
    case .alreadyASIF:
      "This virtual machine already uses an Apple sparse image."
    case .savedStateMustBeDiscarded:
      "Discard this virtual machine’s saved state before changing its disk format."
    case .destinationExists(let url):
      "The migration destination already exists: \(url.lastPathComponent)"
    case .conversionFailed(let exitCode, let diagnostic):
      diagnostic.isEmpty
        ? "diskutil could not convert the disk image (exit \(exitCode))."
        : "diskutil could not convert the disk image (exit \(exitCode)): \(diagnostic)"
    case .conversionOutputTruncated:
      "diskutil produced more output than could be safely retained, so the conversion was not accepted."
    case .logicalSizeMismatch(let expected, let actual):
      "The converted image reports \(actual) logical bytes instead of \(expected)."
    case .unsafeArtifact(let reason):
      "The disk migration stopped because an artifact was unsafe: \(reason)"
    case .staleSource:
      "The source disk changed during conversion, so the migrated image was not committed."
    case .invalidJournal:
      "The disk migration journal is invalid or no longer matches this virtual machine."
    case .converterTerminationUnconfirmed(let reason):
      "The disk converter did not confirm exit, so its staging data remains quarantined: \(reason)"
    case .operationAndCleanupFailed(let operation, let cleanup):
      "Disk migration failed (\(operation)), and its private staging cleanup also failed (\(cleanup))."
    case .committedCleanupPending(let reason):
      "The ASIF disk was committed, but old-disk cleanup is pending: \(reason)"
    }
  }
}
