import Foundation

enum WindowsVirtualMachineSecurityMode: String, Codable, CaseIterable, Sendable {
  case productionSecureBoot
  case developmentTestSigning

  var usesSecureBoot: Bool {
    self == .productionSecureBoot
  }
}

enum WindowsInstallationMediaArchitecture: String, Codable, Sendable {
  case arm64
}

struct WindowsInstallationMediaMetadata: Codable, Equatable, Sendable {
  let sha256: String
  let byteCount: UInt64
  let volumeLabel: String
  let architecture: WindowsInstallationMediaArchitecture
  let sourceFilename: String
  let efiBootManagerPath: String
  let bootImagePath: String
  let installImagePath: String
}

struct WindowsGuestToolsReleaseReference: Codable, Equatable, Sendable {
  let version: String
  let artifactURL: URL
  let sha256: String
  let byteCount: UInt64
  let isMicrosoftSigned: Bool
}

struct WindowsVirtualMachineConfiguration: Codable, Equatable, Sendable {
  let efiVariableStorePath: String
  let machineIdentifierPath: String
  var installationMediaPath: String?
  var setupConfigurationMediaPath: String?
  let guestAgentSecretPath: String
  let installationMedia: WindowsInstallationMediaMetadata
  var macAddress: String
  let securityMode: WindowsVirtualMachineSecurityMode
  var guestTools: WindowsGuestToolsReleaseReference?
  var guestToolsMediaAttached: Bool
  var sharesClipboard: Bool

  init(
    efiVariableStorePath: String,
    machineIdentifierPath: String,
    installationMediaPath: String?,
    setupConfigurationMediaPath: String?,
    guestAgentSecretPath: String,
    installationMedia: WindowsInstallationMediaMetadata,
    macAddress: String,
    securityMode: WindowsVirtualMachineSecurityMode = .productionSecureBoot,
    guestTools: WindowsGuestToolsReleaseReference? = nil,
    guestToolsMediaAttached: Bool? = nil,
    sharesClipboard: Bool = true
  ) {
    self.efiVariableStorePath = efiVariableStorePath
    self.machineIdentifierPath = machineIdentifierPath
    self.installationMediaPath = installationMediaPath
    self.setupConfigurationMediaPath = setupConfigurationMediaPath
    self.guestAgentSecretPath = guestAgentSecretPath
    self.installationMedia = installationMedia
    self.macAddress = macAddress
    self.securityMode = securityMode
    self.guestTools = guestTools
    self.guestToolsMediaAttached = guestToolsMediaAttached ?? (guestTools != nil)
    self.sharesClipboard = sharesClipboard
  }
}

struct WindowsPlatformPreparationResult: Equatable, Sendable {
  let macAddress: String
  let installationMedia: WindowsInstallationMediaMetadata
}

enum WindowsVirtualMachineError: LocalizedError, Equatable {
  case missingManifestValue(String)
  case invalidBundle(String)
  case invalidArtifact(String)
  case invalidMachineIdentifier
  case invalidMACAddress(String)
  case unsupportedCPUCount(Int)
  case unsupportedMemorySize(UInt64)
  case insufficientCPUCount(Int)
  case insufficientMemory(UInt64)
  case insufficientDisk(UInt64)
  case secureBootRequiresMacOS27
  case productionGuestToolsUnavailable
  case invalidConfiguration(String)

  var errorDescription: String? {
    switch self {
    case .missingManifestValue(let name):
      "The Windows virtual machine manifest is missing \(name)."
    case .invalidBundle(let reason):
      "The Windows virtual machine bundle is invalid: \(reason)."
    case .invalidArtifact(let name):
      "The Windows virtual machine has an invalid \(name) artifact."
    case .invalidMachineIdentifier:
      "The Windows virtual machine has an invalid generic machine identifier."
    case .invalidMACAddress(let address):
      "The Windows virtual machine has an invalid MAC address: \(address)."
    case .unsupportedCPUCount(let count):
      "The Windows virtual machine cannot use \(count) CPUs on this Mac."
    case .unsupportedMemorySize(let bytes):
      "The Windows virtual machine cannot use \(bytes) bytes of memory on this Mac."
    case .insufficientCPUCount(let count):
      "Windows 11 requires at least 2 virtual CPUs; \(count) was requested."
    case .insufficientMemory(let bytes):
      "Windows 11 requires at least 4 GiB of memory; \(bytes) bytes were requested."
    case .insufficientDisk(let bytes):
      "Windows 11 requires at least 64 GiB of disk capacity; \(bytes) bytes were requested."
    case .secureBootRequiresMacOS27:
      "Secure Boot for Windows requires macOS 27 or newer."
    case .productionGuestToolsUnavailable:
      "Production Windows support remains unavailable until the required guest drivers are Microsoft-signed."
    case .invalidConfiguration(let reason):
      "The Windows virtual machine configuration is invalid: \(reason)"
    }
  }
}
