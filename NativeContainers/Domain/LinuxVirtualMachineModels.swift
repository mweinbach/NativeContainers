import Foundation

struct LinuxVirtualMachineConfiguration: Codable, Equatable, Sendable {
  let efiVariableStorePath: String
  let machineIdentifierPath: String
  var installationMediaPath: String?
  let macAddress: String
  var sharesClipboard: Bool

  init(
    efiVariableStorePath: String,
    machineIdentifierPath: String,
    installationMediaPath: String?,
    macAddress: String,
    sharesClipboard: Bool = true
  ) {
    self.efiVariableStorePath = efiVariableStorePath
    self.machineIdentifierPath = machineIdentifierPath
    self.installationMediaPath = installationMediaPath
    self.macAddress = macAddress
    self.sharesClipboard = sharesClipboard
  }
}

struct LinuxPlatformPreparationResult: Equatable, Sendable {
  let macAddress: String
}

struct ResolvedLinuxVirtualMachine: Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let diskImageURL: URL
  let efiVariableStoreURL: URL
  let machineIdentifierURL: URL
  let installationMediaURL: URL?
}

enum LinuxVirtualMachineError: LocalizedError, Equatable {
  case missingManifestValue(String)
  case invalidBundle(String)
  case invalidArtifact(String)
  case invalidMachineIdentifier
  case invalidMACAddress(String)
  case unsupportedCPUCount(Int)
  case unsupportedMemorySize(UInt64)
  case invalidConfiguration(String)

  var errorDescription: String? {
    switch self {
    case .missingManifestValue(let name):
      "The Linux virtual machine manifest is missing \(name)."
    case .invalidBundle(let reason):
      "The Linux virtual machine bundle is invalid: \(reason)."
    case .invalidArtifact(let name):
      "The Linux virtual machine has an invalid \(name) artifact."
    case .invalidMachineIdentifier:
      "The Linux virtual machine has an invalid generic machine identifier."
    case .invalidMACAddress(let address):
      "The Linux virtual machine has an invalid MAC address: \(address)."
    case .unsupportedCPUCount(let count):
      "The Linux virtual machine cannot use \(count) CPUs on this Mac."
    case .unsupportedMemorySize(let bytes):
      "The Linux virtual machine cannot use \(bytes) bytes of memory on this Mac."
    case .invalidConfiguration(let reason):
      "The Linux virtual machine configuration is invalid: \(reason)"
    }
  }
}
