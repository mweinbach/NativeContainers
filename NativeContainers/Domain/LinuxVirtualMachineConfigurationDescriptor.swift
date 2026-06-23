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
  static let currentTopologyVersion = 2

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
    let efiVariableStorePath: String
    let machineIdentifierPath: String
    let installationMediaPath: String?
    let macAddress: String
    let sharesClipboard: Bool
    switch machine.manifest.guest {
    case .linux:
      guard let configuration = machine.manifest.linuxConfiguration else {
        throw LinuxVirtualMachineError.missingManifestValue(
          "linuxConfiguration"
        )
      }
      efiVariableStorePath = configuration.efiVariableStorePath
      machineIdentifierPath = configuration.machineIdentifierPath
      installationMediaPath = configuration.installationMediaPath
      macAddress = configuration.macAddress
      sharesClipboard = configuration.sharesClipboard
    case .windows:
      guard let configuration = machine.manifest.windowsConfiguration else {
        throw WindowsVirtualMachineError.missingManifestValue(
          "windowsConfiguration"
        )
      }
      efiVariableStorePath = configuration.efiVariableStorePath
      machineIdentifierPath = configuration.machineIdentifierPath
      installationMediaPath = configuration.installationMediaPath
      macAddress = configuration.macAddress
      sharesClipboard = configuration.sharesClipboard
    case .macOS:
      throw VirtualMachineModelError.requiresLinuxGuest(machine.manifest.id)
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

    return LinuxVirtualMachineConfigurationDescriptor(
      topologyVersion: LinuxVirtualMachineConfigurationDescriptor
        .currentTopologyVersion,
      cpuCount: machine.manifest.resources.cpuCount,
      memoryBytes: machine.manifest.resources.memoryBytes,
      diskBytes: machine.manifest.resources.diskBytes,
      diskImagePath: machine.manifest.diskImagePath,
      diskImageFormat: machine.manifest.effectiveDiskImageFormat.rawValue,
      diskSnapshotRevision:
        machine.manifest.effectiveDiskSnapshotConfiguration.revision > 0
        ? machine.manifest.effectiveDiskSnapshotConfiguration.revision
        : nil,
      diskSnapshotLayerPaths:
        machine.manifest.effectiveDiskSnapshotConfiguration.hasSnapshots
        ? machine.manifest.effectiveDiskSnapshotConfiguration.layers.map(
          \.relativePath
        )
        : nil,
      efiVariableStorePath: efiVariableStorePath,
      machineIdentifierPath: machineIdentifierPath,
      installationMediaPath: installationMediaPath,
      platform: "Generic",
      bootLoader: "EFI",
      diskDevice: machine.manifest.guest == .windows ? "NVMe" : "VirtioBlock",
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
      macAddress: macAddress,
      audioDevices: ["VirtioSound/HostOutput"],
      keyboardDevices: ["USB"],
      pointingDevices: ["USBScreenCoordinate"],
      entropyDevices: ["Virtio"],
      memoryBalloonDevices: ["VirtioTraditional"],
      consoleDevices: machine.manifest.guest == .linux && sharesClipboard
        ? ["VirtioConsole/SPICEAgent"] : [],
      sharesClipboard: sharesClipboard,
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
}
