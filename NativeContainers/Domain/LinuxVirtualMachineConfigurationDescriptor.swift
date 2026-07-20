import Foundation

struct LinuxVirtualMachineSharedDirectoryDescriptor:
  Codable, Equatable, Sendable
{
  let id: UUID
  let guestName: String
  let readOnly: Bool
  let sourceDevice: UInt64
  let sourceInode: UInt64
}

struct LinuxVirtualMachineConfigurationDescriptor:
  Codable, Equatable, Sendable
{
  static let currentTopologyVersion = 3
  static let guestAgentSocketPort: UInt32 = 4050

  let topologyVersion: Int
  let cpuCount: Int
  let memoryBytes: UInt64
  let diskBytes: UInt64
  let diskImagePath: String
  let diskImageFormat: String
  let diskSnapshotRevision: UInt64?
  let diskSnapshotLayerPaths: [String]?
  let efiVariableStorePath: String
  let machineIdentifierPath: String
  let installationMediaPath: String?
  let linuxBoxDescriptor: LinuxBoxDescriptor?
  let platform: String
  let bootLoader: String
  let diskDevice: String
  let diskCachingMode: String
  let diskSynchronizationMode: String
  let displayWidth: Int
  let displayHeight: Int
  let networkDevice: String
  let networkAttachment: String
  let networkConfigurationRevision: UInt64?
  let macAddress: String
  let audioDevices: [String]
  let keyboardDevices: [String]
  let pointingDevices: [String]
  let entropyDevices: [String]
  let memoryBalloonDevices: [String]
  let consoleDevices: [String]
  let socketDevices: [String]
  let sharesClipboard: Bool
  let directorySharingDevice: String?
  let directorySharingRevision: UInt64?
  let sharedDirectories: [LinuxVirtualMachineSharedDirectoryDescriptor]?
}

protocol LinuxVirtualMachineConfigurationDescribing: Sendable {
  func descriptor(
    for machine: ResolvedLinuxVirtualMachine
  ) throws -> LinuxVirtualMachineConfigurationDescriptor
}

struct LinuxVirtualMachineConfigurationDescriptorService:
  LinuxVirtualMachineConfigurationDescribing
{
  func descriptor(
    for machine: ResolvedLinuxVirtualMachine
  ) throws -> LinuxVirtualMachineConfigurationDescriptor {
    guard let linux = machine.manifest.linuxConfiguration else {
      throw LinuxVirtualMachineError.missingManifestValue(
        "linuxConfiguration"
      )
    }

    let network = machine.manifest.effectiveNetworkConfiguration
    let networkAttachment =
      switch network.attachment {
      case .nat:
        "NAT"
      case .shared:
        "VmnetShared"
      case .hostOnly:
        "VmnetHostOnly"
      }
    let hasDirectorySharingHistory =
      machine.sharedDirectories.revision > 0
      || !machine.sharedDirectories.directories.isEmpty

    if machine.manifest.isManagedLinuxBox {
      guard let descriptor = linux.linuxBoxDescriptor else {
        throw LinuxVirtualMachineError.invalidConfiguration(
          "managed Linux boxes require an image descriptor"
        )
      }
      try descriptor.validate()
    }

    if machine.manifest.isHardenedLinuxBox {
      try validateManagedTopology(
        machine: machine,
        linux: linux,
        network: network
      )
    }
    return LinuxVirtualMachineConfigurationDescriptor(
      topologyVersion: LinuxVirtualMachineConfigurationDescriptor
        .currentTopologyVersion,
      cpuCount: machine.manifest.resources.cpuCount,
      memoryBytes: machine.manifest.resources.memoryBytes,
      diskBytes: machine.manifest.resources.diskBytes,
      diskImagePath: machine.manifest.diskImagePath,
      diskImageFormat: machine.manifest.effectiveDiskImageFormat.rawValue,
      diskSnapshotRevision:
        machine.manifest.effectiveLinuxDiskSnapshotConfiguration.revision > 0
        ? machine.manifest.effectiveLinuxDiskSnapshotConfiguration.revision
        : nil,
      diskSnapshotLayerPaths:
        machine.manifest.effectiveLinuxDiskSnapshotConfiguration.hasSnapshots
        ? machine.manifest.effectiveLinuxDiskSnapshotConfiguration.layers.map(
          \.relativePath
        )
        : nil,
      efiVariableStorePath: linux.efiVariableStorePath,
      machineIdentifierPath: linux.machineIdentifierPath,
      installationMediaPath: linux.installationMediaPath,
      linuxBoxDescriptor: linux.linuxBoxDescriptor,
      platform: "Generic",
      bootLoader: "EFI",
      diskDevice: "VirtioBlock",
      diskCachingMode: "automatic",
      diskSynchronizationMode: "full",
      displayWidth: AppleLinuxVirtualMachineConfigurationFactory
        .defaultDisplayWidth,
      displayHeight: AppleLinuxVirtualMachineConfigurationFactory
        .defaultDisplayHeight,
      networkDevice: "Virtio",
      networkAttachment: networkAttachment,
      networkConfigurationRevision: network.revision > 0
        ? network.revision : nil,
      macAddress: linux.macAddress,
      audioDevices: ["VirtioSound/HostOutput"],
      keyboardDevices: ["USB"],
      pointingDevices: ["USBScreenCoordinate"],
      entropyDevices: ["Virtio"],
      memoryBalloonDevices: ["VirtioTraditional"],
      consoleDevices: linux.sharesClipboard
        ? ["VirtioConsole/SPICEAgent"] : [],
      socketDevices: machine.manifest.isManagedLinuxBox
        ? ["VirtioSocket/\(LinuxVirtualMachineConfigurationDescriptor.guestAgentSocketPort)"] : [],
      sharesClipboard: linux.sharesClipboard,
      directorySharingDevice: hasDirectorySharingHistory
        && !machine.sharedDirectories.directories.isEmpty
        ? "VirtioFS/\(AppleLinuxVirtualMachineSharedDirectoryDeviceFactory.mountTag)"
        : nil,
      directorySharingRevision: hasDirectorySharingHistory
        ? machine.sharedDirectories.revision : nil,
      sharedDirectories: hasDirectorySharingHistory
        ? machine.sharedDirectories.directories.map { directory in
          LinuxVirtualMachineSharedDirectoryDescriptor(
            id: directory.id,
            guestName: directory.guestName,
            readOnly: directory.readOnly,
            sourceDevice: directory.sourceIdentity.device,
            sourceInode: directory.sourceIdentity.inode
          )
        } : nil
    )
  }
  private func validateManagedTopology(
    machine: ResolvedLinuxVirtualMachine,
    linux: LinuxVirtualMachineConfiguration,
    network: VirtualMachineNetworkConfiguration
  ) throws {
    guard network.attachment == .nat else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Residential Linux boxes require NAT networking"
      )
    }
    guard !linux.sharesClipboard else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Residential Linux boxes cannot share the clipboard"
      )
    }
    guard linux.installationMediaPath == nil, machine.installationMediaURL == nil else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Residential Linux boxes cannot attach installation media"
      )
    }
    guard machine.sharedDirectories.directories.isEmpty else {
      throw LinuxVirtualMachineError.invalidConfiguration(
        "Residential Linux boxes cannot share host directories"
      )
    }
  }
}
