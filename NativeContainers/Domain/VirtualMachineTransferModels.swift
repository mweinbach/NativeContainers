import Foundation

extension VirtualMachineManifest {
  func portableRepresentation() -> VirtualMachineManifest {
    var manifest = self
    manifest.installState = .stopped
    manifest.restoreImageURL = nil
    manifest.installationOperationID = nil
    manifest.installationFailure = nil
    manifest.audioConfiguration = nil
    manifest.networkConfiguration = nil
    return manifest
  }

  func imported(
    using mode: VirtualMachineImportMode,
    linuxMACAddress: String? = nil
  ) throws -> VirtualMachineManifest {
    let portable = portableRepresentation()
    switch mode {
    case .preserveIdentity:
      return portable
    case .clone(let name):
      return try VirtualMachineManifest(
        cloning: portable,
        name: name,
        linuxMACAddress: linuxMACAddress
      )
      .portableRepresentation()
    }
  }
}

enum VirtualMachineImportMode: Equatable, Sendable {
  case preserveIdentity
  case clone(name: String)
}

struct VirtualMachineExportReceipt: Equatable, Sendable {
  let machineID: UUID
  let destinationURL: URL
}

struct VirtualMachineImportTransaction: Equatable, Sendable {
  let operationID: UUID
  let source: VirtualMachineManifest
  let imported: VirtualMachineManifest
  let sourceBundleURL: URL
  let stagingBundleURL: URL
  let finalBundleURL: URL
  let mode: VirtualMachineImportMode
}

enum VirtualMachineBundleIdentityPolicy: Equatable, Sendable {
  case preserve
  case regenerate
}

enum VirtualMachineBundlePortability: Equatable, Sendable {
  case sameHost
  case portable
}

struct VirtualMachineBundlePreparationRequest: Equatable, Sendable {
  let sourceBundleURL: URL
  let destinationBundleURL: URL
  let sourceManifest: VirtualMachineManifest
  let destinationManifest: VirtualMachineManifest
  let identityPolicy: VirtualMachineBundleIdentityPolicy
  let portability: VirtualMachineBundlePortability
}

enum VirtualMachineBundleError: LocalizedError, Equatable, Sendable {
  case invalidBundle(String)
  case sourceChanged
  case invalidMachineIdentifier
  case duplicateMachineIdentifier
  case invalidMACAddress
  case duplicateMACAddress

  var errorDescription: String? {
    switch self {
    case .invalidBundle(let reason):
      "The virtual machine package is invalid: \(reason)"
    case .sourceChanged:
      "The virtual machine package changed while it was being copied. Stop changing it and try again."
    case .invalidMachineIdentifier:
      "The virtual machine package contains an invalid platform identity."
    case .duplicateMachineIdentifier:
      "The generated virtual machine platform identity duplicates an existing identity."
    case .invalidMACAddress:
      "The virtual machine package contains an invalid network identity."
    case .duplicateMACAddress:
      "The generated virtual machine network identity duplicates an existing identity."
    }
  }
}

enum VirtualMachineTransferError: LocalizedError, Equatable, Sendable {
  case unavailable
  case managedLinuxBoxUnsupported
  case invalidSourceState(VirtualMachineInstallState)
  case invalidPackage(String)
  case invalidDestination(String)
  case destinationExists(URL)
  case identityCollision(UUID)
  case platformIdentityCollision
  case staleTransaction(UUID)
  case operationAndCleanupFailed(operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine import and export are unavailable."
    case .managedLinuxBoxUnsupported:
      "Residential Linux boxes cannot be imported or exported."
    case .invalidSourceState(let state):
      "A virtual machine in the \(state.rawValue) state cannot be transferred. Shut it down first."
    case .invalidPackage(let reason):
      "The virtual machine package cannot be imported: \(reason)"
    case .invalidDestination(let reason):
      "The virtual machine package cannot be exported there: \(reason)"
    case .destinationExists(let url):
      "A file already exists at \(url.path). Choose another export name."
    case .identityCollision(let identifier):
      "Virtual machine identity \(identifier.uuidString) already exists in this library. Import it as a copy instead."
    case .platformIdentityCollision:
      "This virtual machine platform identity already exists in the library. Import it as a copy instead."
    case .staleTransaction(let identifier):
      "The import transaction for virtual machine \(identifier.uuidString) is no longer current."
    case .operationAndCleanupFailed(let operation, let cleanup):
      "The transfer failed (\(operation)), and cleanup also failed (\(cleanup))."
    }
  }
}
