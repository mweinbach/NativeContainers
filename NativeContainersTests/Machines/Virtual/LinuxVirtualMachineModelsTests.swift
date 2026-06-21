import Foundation
import Testing

@testable import NativeContainers

struct LinuxVirtualMachineModelsTests {
  @Test
  func olderManifestWithoutLinuxConfigurationStillDecodes() throws {
    let data = Data(
      """
      {
        "schemaVersion": 1,
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Existing Mac",
        "guest": "macOS",
        "installState": "draft",
        "resources": {
          "cpuCount": 4,
          "memoryBytes": 4294967296,
          "diskBytes": 8589934592
        },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """.utf8
    )

    let manifest = try JSONDecoder().decode(
      VirtualMachineManifest.self,
      from: data
    )

    #expect(manifest.linuxConfiguration == nil)
    #expect(manifest.guest == .macOS)
  }

  @Test
  func linuxPreparationStateRoundTripsThroughManifestCoding() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 16 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Linux",
      guest: .linux,
      resources: resources
    )
    let configuration = LinuxVirtualMachineConfiguration(
      efiVariableStorePath: "LinuxPlatform/NVRAM",
      machineIdentifierPath: "LinuxPlatform/MachineIdentifier",
      installationMediaPath: "LinuxPlatform/Installation.iso",
      macAddress: "02:00:00:00:00:01"
    )

    manifest.markReadyToInstallLinux(configuration: configuration)
    let decoded = try JSONDecoder().decode(
      VirtualMachineManifest.self,
      from: JSONEncoder().encode(manifest)
    )

    #expect(decoded == manifest)
    #expect(decoded.installState == .readyToInstall)
    #expect(decoded.linuxConfiguration == configuration)
  }
}
