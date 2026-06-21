import Foundation

struct PreparedMacVirtualMachine: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let restoreImageURL: URL
  let diskImageURL: URL
  let auxiliaryStorageURL: URL
  let hardwareModelURL: URL
  let machineIdentifierURL: URL
}

enum MacVirtualMachineInstallationPhase: Equatable, Sendable {
  case preparing
  case installing
  case finalizing
}

struct MacVirtualMachineInstallationProgress: Equatable, Sendable {
  let phase: MacVirtualMachineInstallationPhase
  let fractionCompleted: Double?

  init(phase: MacVirtualMachineInstallationPhase, fractionCompleted: Double? = nil) {
    self.phase = phase
    self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
  }
}

typealias MacVirtualMachineInstallationProgressHandler =
  @MainActor @Sendable (MacVirtualMachineInstallationProgress) -> Void

enum VirtualMachineInstallationFailureKind: String, Codable, Equatable, Sendable {
  case cancelled
  case failed
  case interrupted
}

struct VirtualMachineInstallationFailure: Codable, Equatable, Sendable {
  let kind: VirtualMachineInstallationFailureKind
  let message: String
  let occurredAt: Date
}

enum MacVirtualMachineInstallationError: LocalizedError, Equatable, Sendable {
  case unavailable
  case requiresAppleSilicon
  case duplicateInstallation(UUID)
  case missingManifestValue(String)
  case invalidBundle(String)
  case invalidArtifact(String)
  case invalidRestoreImage(URL)
  case invalidHardwareModel
  case invalidMachineIdentifier
  case unsupportedCPUCount(Int)
  case unsupportedMemorySize(UInt64)
  case invalidDiskSize(UInt64)
  case invalidConfiguration(String)
  case staleOperation(UUID)
  case statePersistenceFailed(operation: String, persistence: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "macOS installation is unavailable in this app configuration."
    case .requiresAppleSilicon:
      "macOS virtual machines require a Mac with Apple silicon."
    case .duplicateInstallation(let identifier):
      "An installation is already active for virtual machine \(identifier.uuidString)."
    case .missingManifestValue(let value):
      "The virtual machine manifest is missing \(value)."
    case .invalidBundle(let reason):
      "The virtual machine bundle is invalid: \(reason)"
    case .invalidArtifact(let name):
      "The virtual machine artifact is missing or unsafe: \(name)"
    case .invalidRestoreImage(let url):
      "The macOS restore image is missing or unsafe: \(url.path)"
    case .invalidHardwareModel:
      "The saved Mac hardware model cannot be reconstructed."
    case .invalidMachineIdentifier:
      "The saved Mac machine identifier cannot be reconstructed."
    case .unsupportedCPUCount(let count):
      "The requested CPU count (\(count)) is outside Virtualization.framework limits."
    case .unsupportedMemorySize(let bytes):
      "The requested memory size (\(bytes) bytes) is outside Virtualization.framework limits or is not 1 MiB aligned."
    case .invalidDiskSize(let bytes):
      "The virtual disk size (\(bytes) bytes) must be nonzero and 512-byte aligned."
    case .invalidConfiguration(let reason):
      "Virtualization.framework rejected the virtual machine configuration: \(reason)"
    case .staleOperation(let identifier):
      "The installation lease for virtual machine \(identifier.uuidString) is no longer current."
    case .statePersistenceFailed(let operation, let persistence):
      "The VM operation ended (\(operation)), but its durable state could not be updated (\(persistence)). Restart the app before taking another action."
    }
  }
}
