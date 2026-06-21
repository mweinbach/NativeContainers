import Foundation

struct VirtualMachineCloneTransaction: Equatable, Sendable {
  let operationID: UUID
  let source: VirtualMachineManifest
  let clone: VirtualMachineManifest
  let sourceBundleURL: URL
  let stagingBundleURL: URL
  let finalBundleURL: URL
}

enum VirtualMachineCloneError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidSourceState(VirtualMachineInstallState)
  case staleTransaction(UUID)
  case invalidBundle(String)
  case operationAndCleanupFailed(operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine cloning is unavailable."
    case .invalidSourceState(let state):
      "A virtual machine in the \(state.rawValue) state cannot be cloned. Shut it down first."
    case .staleTransaction(let identifier):
      "The clone transaction for virtual machine \(identifier.uuidString) is no longer current."
    case .invalidBundle(let reason):
      "The virtual machine bundle cannot be cloned: \(reason)"
    case .operationAndCleanupFailed(let operation, let cleanup):
      "Cloning failed (\(operation)), and cleanup also failed (\(cleanup))."
    }
  }
}
