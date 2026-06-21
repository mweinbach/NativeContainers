import CryptoKit
import Foundation

struct MacVirtualMachineConfigurationDescriptor: Codable, Equatable, Sendable {
  static let currentTopologyVersion = 1

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
      memoryBalloonDevices: ["VirtioTraditional"]
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
