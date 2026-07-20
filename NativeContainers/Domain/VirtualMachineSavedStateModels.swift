import Foundation

struct VirtualMachineSavedStateSummary: Codable, Equatable, Sendable {
  let createdAt: Date
  let stateSizeBytes: UInt64
}

enum VirtualMachineSavedStateStatus: Equatable, Sendable {
  case unknown
  case none
  case available(VirtualMachineSavedStateSummary)
  case incompatible(String)

  var summary: VirtualMachineSavedStateSummary? {
    guard case .available(let summary) = self else { return nil }
    return summary
  }
}

struct VirtualMachineSavedStateArtifact: Equatable, Sendable {
  let stateURL: URL
  let summary: VirtualMachineSavedStateSummary
  let configurationFingerprint: String
}

struct VirtualMachineSavedStateTransaction: Equatable, Sendable {
  let operationID: UUID
  let target: VirtualMachineRuntimeTarget
  let stagingDirectoryURL: URL
  let stateURL: URL
}

struct VirtualMachineSavedStateRestoreTransaction: Equatable, Sendable {
  let operationID: UUID
  let target: VirtualMachineRuntimeTarget
  let consumingDirectoryURL: URL
  let artifact: VirtualMachineSavedStateArtifact
}

struct VirtualMachineSavedStateMetadata: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let machineID: UUID
  let configurationFingerprint: String
  let stateFilename: String
  let createdAt: Date
  let stateSizeBytes: UInt64
  let hostOperatingSystemVersion: String
}

enum VirtualMachineSavedStateError: LocalizedError, Equatable, Sendable {
  case missing(UUID)
  case incompatible(UUID, String)
  case checkpointAlreadyExists(UUID)
  case operationInProgress(UUID)
  case invalidTransaction(UUID)
  case invalidBundle(String)
  case unsupportedSchema(Int)
  case managedLinuxBoxUnsupported(UUID)
  case operationAndCleanupFailed(operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .missing(let identifier):
      "Virtual machine \(identifier.uuidString) has no saved state to restore."
    case .incompatible(let identifier, let reason):
      "The saved state for virtual machine \(identifier.uuidString) is incompatible: \(reason)"
    case .checkpointAlreadyExists(let identifier):
      "Virtual machine \(identifier.uuidString) already has saved state. Discard it before saving another checkpoint."
    case .operationInProgress(let identifier):
      "Virtual machine \(identifier.uuidString) already has a saved-state transaction in progress."
    case .invalidTransaction(let identifier):
      "The saved-state transaction for virtual machine \(identifier.uuidString) is no longer current."
    case .invalidBundle(let reason):
      "The saved-state bundle is invalid: \(reason)"
    case .unsupportedSchema(let version):
      "The saved state uses unsupported metadata version \(version)."
    case .managedLinuxBoxUnsupported(let identifier):
      "Residential Linux box \(identifier.uuidString) does not support machine-state save or restore."
    case .operationAndCleanupFailed(let operation, let cleanup):
      "The saved-state operation failed (\(operation)), and cleanup also failed (\(cleanup))."
    }
  }
}

typealias MacVirtualMachineSavedStateSummary = VirtualMachineSavedStateSummary
typealias MacVirtualMachineSavedStateStatus = VirtualMachineSavedStateStatus
typealias MacVirtualMachineSavedStateArtifact = VirtualMachineSavedStateArtifact
typealias MacVirtualMachineSavedStateTransaction = VirtualMachineSavedStateTransaction
typealias MacVirtualMachineSavedStateRestoreTransaction =
  VirtualMachineSavedStateRestoreTransaction
typealias MacVirtualMachineSavedStateMetadata = VirtualMachineSavedStateMetadata
typealias MacVirtualMachineSavedStateError = VirtualMachineSavedStateError

typealias LinuxVirtualMachineSavedStateSummary = VirtualMachineSavedStateSummary
typealias LinuxVirtualMachineSavedStateStatus = VirtualMachineSavedStateStatus
typealias LinuxVirtualMachineSavedStateArtifact = VirtualMachineSavedStateArtifact
typealias LinuxVirtualMachineSavedStateTransaction = VirtualMachineSavedStateTransaction
typealias LinuxVirtualMachineSavedStateRestoreTransaction =
  VirtualMachineSavedStateRestoreTransaction
typealias LinuxVirtualMachineSavedStateMetadata = VirtualMachineSavedStateMetadata
typealias LinuxVirtualMachineSavedStateError = VirtualMachineSavedStateError
