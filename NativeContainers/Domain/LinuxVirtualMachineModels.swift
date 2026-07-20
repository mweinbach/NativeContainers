import Foundation

struct LinuxBoxDescriptor: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2
  static let currentGuestAgentProtocolVersion = 2

  let schemaVersion: Int
  let imageID: String
  let imageBuildRevision: String
  let rawImageSHA512: String
  let profile: LinuxBoxProfile
  let guestAgentProtocolVersion: Int

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    imageID: String,
    imageBuildRevision: String,
    rawImageSHA512: String,
    profile: LinuxBoxProfile = .standard,
    guestAgentProtocolVersion: Int = Self.currentGuestAgentProtocolVersion
  ) throws {
    self.schemaVersion = schemaVersion
    self.imageID = imageID
    self.imageBuildRevision = imageBuildRevision
    self.rawImageSHA512 = rawImageSHA512
    self.profile = profile
    self.guestAgentProtocolVersion = guestAgentProtocolVersion
    try validate()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, imageID, imageBuildRevision, rawImageSHA512, profile
    case guestAgentProtocolVersion
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
      imageID: try values.decode(String.self, forKey: .imageID),
      imageBuildRevision: try values.decode(String.self, forKey: .imageBuildRevision),
      rawImageSHA512: try values.decode(String.self, forKey: .rawImageSHA512),
      profile: try values.decode(LinuxBoxProfile.self, forKey: .profile),
      guestAgentProtocolVersion: try values.decode(Int.self, forKey: .guestAgentProtocolVersion)
    )
  }

  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Linux box descriptor schema \(schemaVersion) is unsupported"
      )
    }
    guard Self.isBoundedASCIIIdentifier(imageID) else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Linux box imageID is invalid"
      )
    }
    guard Self.isBoundedASCIIIdentifier(imageBuildRevision) else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Linux box imageBuildRevision is invalid"
      )
    }
    guard rawImageSHA512.utf8.count == 128,
      rawImageSHA512.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Linux box rawImageSHA512 must be 128 lowercase hexadecimal characters"
      )
    }
    guard guestAgentProtocolVersion == Self.currentGuestAgentProtocolVersion else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Linux box guest-agent protocol \(guestAgentProtocolVersion) is unsupported"
      )
    }
  }

  private static func isBoundedASCIIIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    return (1...128).contains(bytes.count)
      && bytes.allSatisfy { (0x21...0x7e).contains($0) }
  }
}

struct LinuxVirtualMachineConfiguration: Codable, Equatable, Sendable {
  let efiVariableStorePath: String
  let machineIdentifierPath: String
  var installationMediaPath: String?
  var macAddress: String
  var sharesClipboard: Bool
  let linuxBoxDescriptor: LinuxBoxDescriptor?

  init(
    efiVariableStorePath: String,
    machineIdentifierPath: String,
    installationMediaPath: String?,
    macAddress: String,
    sharesClipboard: Bool = true,
    linuxBoxDescriptor: LinuxBoxDescriptor? = nil
  ) {
    self.efiVariableStorePath = efiVariableStorePath
    self.machineIdentifierPath = machineIdentifierPath
    self.installationMediaPath = installationMediaPath
    self.macAddress = macAddress
    self.sharesClipboard = sharesClipboard
    self.linuxBoxDescriptor = linuxBoxDescriptor
  }
}

struct LinuxPlatformPreparationResult: Equatable, Sendable {
  let macAddress: String
}

struct ResolvedLinuxVirtualMachine: Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let diskImageURL: URL
  let diskSnapshotLayerURLs: [URL]
  let efiVariableStoreURL: URL
  let machineIdentifierURL: URL
  let installationMediaURL: URL?
  let sharedDirectories: LinuxVirtualMachineSharedDirectoryConfiguration

  init(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    diskImageURL: URL,
    diskSnapshotLayerURLs: [URL] = [],
    efiVariableStoreURL: URL,
    machineIdentifierURL: URL,
    installationMediaURL: URL?,
    sharedDirectories: LinuxVirtualMachineSharedDirectoryConfiguration = .empty
  ) {
    self.manifest = manifest
    self.bundleURL = bundleURL
    self.diskImageURL = diskImageURL
    self.diskSnapshotLayerURLs = diskSnapshotLayerURLs
    self.efiVariableStoreURL = efiVariableStoreURL
    self.machineIdentifierURL = machineIdentifierURL
    self.installationMediaURL = installationMediaURL
    self.sharedDirectories = sharedDirectories
  }
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
