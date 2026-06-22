import Foundation

enum VirtualMachineDiskImageResizePhase:
  String,
  Codable,
  CaseIterable,
  Sendable
{
  case planned
  case imageExtended
  case manifestUpdated
}

enum VirtualMachineDiskImageResizeArtifacts {
  static let journalFilename = ".DiskImageResize.json"

  static func isControlArtifact(relativePath: String) -> Bool {
    NSString(string: relativePath).lastPathComponent == journalFilename
  }
}

struct VirtualMachineDiskImageResizeJournal:
  Codable,
  Equatable,
  Sendable
{
  static let currentVersion = 1

  let version: Int
  let operationID: UUID
  let machineID: UUID
  let guest: VirtualMachineGuest
  let diskImagePath: String
  let resizeArtifactPath: String
  let diskImageFormat: VirtualMachineDiskImageFormat
  let sourceIdentity: VirtualMachineStorageArtifactIdentity
  let sourceLogicalBytes: UInt64
  let sourceBlockSizeBytes: UInt64
  let targetLogicalBytes: UInt64
  var resizedIdentity: VirtualMachineStorageArtifactIdentity?
  var phase: VirtualMachineDiskImageResizePhase

  init(
    version: Int = Self.currentVersion,
    operationID: UUID,
    machineID: UUID,
    guest: VirtualMachineGuest,
    diskImagePath: String,
    resizeArtifactPath: String,
    diskImageFormat: VirtualMachineDiskImageFormat,
    sourceIdentity: VirtualMachineStorageArtifactIdentity,
    sourceLogicalBytes: UInt64,
    sourceBlockSizeBytes: UInt64,
    targetLogicalBytes: UInt64,
    resizedIdentity: VirtualMachineStorageArtifactIdentity? = nil,
    phase: VirtualMachineDiskImageResizePhase = .planned
  ) {
    self.version = version
    self.operationID = operationID
    self.machineID = machineID
    self.guest = guest
    self.diskImagePath = diskImagePath
    self.resizeArtifactPath = resizeArtifactPath
    self.diskImageFormat = diskImageFormat
    self.sourceIdentity = sourceIdentity
    self.sourceLogicalBytes = sourceLogicalBytes
    self.sourceBlockSizeBytes = sourceBlockSizeBytes
    self.targetLogicalBytes = targetLogicalBytes
    self.resizedIdentity = resizedIdentity
    self.phase = phase
  }
}

struct VirtualMachineDiskImageResizeCommit: Equatable, Sendable {
  let machineID: UUID
  let guest: VirtualMachineGuest
  let diskImagePath: String
  let resizeArtifactPath: String
  let diskImageFormat: VirtualMachineDiskImageFormat
  let sourceLogicalBytes: UInt64
  let targetLogicalBytes: UInt64
  let resizedIdentity: VirtualMachineStorageArtifactIdentity
}

struct VirtualMachineDiskImageResizeResult: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let previousLogicalBytes: UInt64
  let newLogicalBytes: UInt64
  let didResize: Bool

  var addedLogicalBytes: UInt64 {
    newLogicalBytes > previousLogicalBytes
      ? newLogicalBytes - previousLogicalBytes : 0
  }
}

struct VirtualMachineDiskImageResizeRecoveryFailure:
  Equatable,
  Sendable
{
  let machineID: UUID
  let diagnostic: String
}

struct VirtualMachineDiskImageResizeRecoveryReport:
  Equatable,
  Sendable
{
  let recoveredMachineIDs: [UUID]
  let deferredMachineIDs: [UUID]
  let failures: [VirtualMachineDiskImageResizeRecoveryFailure]

  static let empty = Self(
    recoveredMachineIDs: [],
    deferredMachineIDs: [],
    failures: []
  )
}

enum VirtualMachineDiskImageResizeError:
  LocalizedError,
  Equatable,
  Sendable
{
  case unavailable
  case invalidTarget(UInt64)
  case growthRequired(current: UInt64, requested: UInt64)
  case targetNotBlockAligned(target: UInt64, blockSize: UInt64)
  case targetTooLarge(UInt64)
  case savedStateMustBeDiscarded
  case logicalSizeMismatch(expected: UInt64, actual: UInt64)
  case unsafeArtifact(String)
  case staleSource
  case invalidJournal
  case committedCleanupPending(String)
  case recoveryRequired(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual disk growth requires macOS 27 or later."
    case .invalidTarget(let bytes):
      "The requested virtual disk capacity of \(bytes) bytes is invalid."
    case .growthRequired(let current, let requested):
      "Virtual disks can only grow. The current capacity is \(current) bytes, but \(requested) bytes was requested."
    case .targetNotBlockAligned(let target, let blockSize):
      "The requested capacity of \(target) bytes is not aligned to the disk’s \(blockSize)-byte blocks."
    case .targetTooLarge(let bytes):
      "The requested virtual disk capacity of \(bytes) bytes exceeds DiskImageKit’s supported block count."
    case .savedStateMustBeDiscarded:
      "Discard the virtual machine’s saved state before growing its disk."
    case .logicalSizeMismatch(let expected, let actual):
      "The virtual disk capacity changed unexpectedly (expected \(expected) bytes, found \(actual) bytes)."
    case .unsafeArtifact(let reason):
      "The virtual disk resize artifact is unsafe: \(reason)"
    case .staleSource:
      "The virtual disk or manifest changed after the resize operation began."
    case .invalidJournal:
      "The interrupted virtual disk resize journal is invalid."
    case .committedCleanupPending(let reason):
      "The virtual disk was grown, but transaction cleanup is pending: \(reason)"
    case .recoveryRequired(let reason):
      "The virtual disk resize needs recovery before the VM can be used: \(reason)"
    }
  }
}

extension VirtualMachineStorageArtifactIdentity {
  func refersToSameFileNode(
    as other: VirtualMachineStorageArtifactIdentity
  ) -> Bool {
    device == other.device
      && inode == other.inode
      && fileType == other.fileType
      && ownerUserID == other.ownerUserID
      && linkCount == other.linkCount
  }
}
