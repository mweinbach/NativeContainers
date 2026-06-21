import CryptoKit
import Foundation

struct MacVirtualMachineSharedDirectoryDescriptor: Codable, Equatable, Sendable {
  let id: UUID
  let guestName: String
  let readOnly: Bool
  let sourceDevice: UInt64
  let sourceInode: UInt64
}

struct MacVirtualMachineConfigurationDescriptor: Codable, Equatable, Sendable {
  static let legacyTopologyVersion = 1
  static let directorySharingTopologyVersion = 2
  static let currentTopologyVersion = 3

  let topologyVersion: Int
  let cpuCount: Int
  let memoryBytes: UInt64
  let diskBytes: UInt64
  let diskImagePath: String
  let auxiliaryStoragePath: String
  let diskCachingMode: String
  let diskSynchronizationMode: String
  let displayWidth: Int
  let displayHeight: Int
  let displayPixelsPerInch: Int
  let networkDevice: String
  let networkAttachment: String
  let macAddress: String
  let keyboardDevices: [String]
  let pointingDevices: [String]
  let entropyDevices: [String]
  let memoryBalloonDevices: [String]
  let audioDevices: [String]?
  let audioConfigurationRevision: UInt64?
  let directorySharingDevice: String?
  let directorySharingRevision: UInt64?
  let sharedDirectories: [MacVirtualMachineSharedDirectoryDescriptor]?
}

protocol MacVirtualMachineConfigurationDescribing: Sendable {
  func descriptor(
    for machine: ResolvedMacVirtualMachine
  ) throws -> MacVirtualMachineConfigurationDescriptor
}

struct MacVirtualMachineConfigurationDescriptorService:
  MacVirtualMachineConfigurationDescribing
{
  func descriptor(
    for machine: ResolvedMacVirtualMachine
  ) throws -> MacVirtualMachineConfigurationDescriptor {
    guard let auxiliaryStoragePath = machine.manifest.auxiliaryStoragePath else {
      throw MacVirtualMachineInstallationError.missingManifestValue(
        "auxiliaryStoragePath"
      )
    }
    let hasDirectorySharingHistory =
      machine.sharedDirectories.revision > 0
      || !machine.sharedDirectories.directories.isEmpty
    let audioConfiguration = machine.manifest.effectiveAudioConfiguration
    let audioDevices =
      ["VirtioSound/HostOutput"]
      + (audioConfiguration.isMicrophoneEnabled
        ? ["VirtioSound/HostInput"] : [])
    return MacVirtualMachineConfigurationDescriptor(
      topologyVersion: MacVirtualMachineConfigurationDescriptor.currentTopologyVersion,
      cpuCount: machine.manifest.resources.cpuCount,
      memoryBytes: machine.manifest.resources.memoryBytes,
      diskBytes: machine.manifest.resources.diskBytes,
      diskImagePath: machine.manifest.diskImagePath,
      auxiliaryStoragePath: auxiliaryStoragePath,
      diskCachingMode: "automatic",
      diskSynchronizationMode: "full",
      displayWidth: 1_920,
      displayHeight: 1_200,
      displayPixelsPerInch: 144,
      networkDevice: "virtio",
      networkAttachment: "NAT",
      macAddress: Self.macAddress(for: machine.manifest.id),
      keyboardDevices: ["Mac", "USB"],
      pointingDevices: ["MacTrackpad", "USBScreenCoordinate"],
      entropyDevices: ["Virtio"],
      memoryBalloonDevices: ["VirtioTraditional"],
      audioDevices: audioDevices,
      audioConfigurationRevision: audioConfiguration.revision > 0
        ? audioConfiguration.revision : nil,
      directorySharingDevice: hasDirectorySharingHistory
        && !machine.sharedDirectories.directories.isEmpty
        ? "VirtioFS/macOSGuestAutomount" : nil,
      directorySharingRevision: hasDirectorySharingHistory
        ? machine.sharedDirectories.revision : nil,
      sharedDirectories: hasDirectorySharingHistory
        ? machine.sharedDirectories.directories.map { directory in
          MacVirtualMachineSharedDirectoryDescriptor(
            id: directory.id,
            guestName: directory.guestName,
            readOnly: directory.readOnly,
            sourceDevice: directory.sourceIdentity.device,
            sourceInode: directory.sourceIdentity.inode
          )
        } : nil
    )
  }

  static func macAddress(for machineID: UUID) -> String {
    var octets = Array(
      SHA256.hash(data: Data(machineID.uuidString.utf8)).prefix(6)
    )
    octets[0] = (octets[0] & 0b1111_1100) | 0b0000_0010
    return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
  }
}
