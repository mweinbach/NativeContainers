import Foundation

struct MacVirtualMachineSavedStateSummary: Codable, Equatable, Sendable {
  let createdAt: Date
  let stateSizeBytes: UInt64
}

enum MacVirtualMachineSavedStateStatus: Equatable, Sendable {
  case unknown
  case none
  case available(MacVirtualMachineSavedStateSummary)
  case incompatible(String)

  var summary: MacVirtualMachineSavedStateSummary? {
    guard case .available(let summary) = self else { return nil }
    return summary
  }
}

struct MacVirtualMachineSavedStateArtifact: Equatable, Sendable {
  let stateURL: URL
  let summary: MacVirtualMachineSavedStateSummary
  let configurationFingerprint: String
}

struct MacVirtualMachineSavedStateTransaction: Equatable, Sendable {
  let operationID: UUID
  let target: MacVirtualMachineRuntimeTarget
  let stagingDirectoryURL: URL
  let stateURL: URL
}

struct MacVirtualMachineSavedStateRestoreTransaction: Equatable, Sendable {
  let operationID: UUID
  let target: MacVirtualMachineRuntimeTarget
  let consumingDirectoryURL: URL
  let artifact: MacVirtualMachineSavedStateArtifact
}

struct MacVirtualMachineSavedStateMetadata: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let machineID: UUID
  let configurationFingerprint: String
  let stateFilename: String
  let createdAt: Date
  let stateSizeBytes: UInt64
  let hostOperatingSystemVersion: String
}

enum MacVirtualMachineSavedStateError: LocalizedError, Equatable, Sendable {
  case missing(UUID)
  case incompatible(UUID, String)
  case checkpointAlreadyExists(UUID)
  case operationInProgress(UUID)
  case invalidTransaction(UUID)
  case invalidBundle(String)
  case unsupportedSchema(Int)
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
    case .operationAndCleanupFailed(let operation, let cleanup):
      "The saved-state operation failed (\(operation)), and cleanup also failed (\(cleanup))."
    }
  }
}
