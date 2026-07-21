import Foundation
import Testing

@testable import NativeContainers

struct LinuxBoxTopologyContractTests {
  @Test
  func residentialTopologyPublishesOnlyNATAndAgentSocket() throws {
    let machine = try makeMachine()
    let descriptor = try LinuxVirtualMachineConfigurationDescriptorService()
      .descriptor(for: machine)

    #expect(descriptor.topologyVersion == 3)
    #expect(descriptor.networkDevice == "Virtio")
    #expect(descriptor.networkAttachment == "NAT")
    #expect(descriptor.consoleDevices.isEmpty)
    #expect(descriptor.socketDevices == ["VirtioSocket/4050"])
    #expect(descriptor.directorySharingDevice == nil)
    #expect(descriptor.linuxBoxDescriptor?.imageID == "nativecontainers-debian-13-arm64-v1")
  }

  @Test(arguments: [VirtualMachineNetworkAttachment.shared, .hostOnly])
  func managedTopologyRejectsNonNATNetworking(
    attachment: VirtualMachineNetworkAttachment
  ) throws {
    var machine = try makeMachine()
    machine = try replacingManifest(machine) { manifest in
      manifest.networkConfiguration = VirtualMachineNetworkConfiguration(
        revision: 1,
        attachment: attachment
      )
    }
    #expect(throws: LinuxVirtualMachineError.self) {
      _ = try LinuxVirtualMachineConfigurationDescriptorService().descriptor(for: machine)
    }
  }

  @Test
  func managedTopologyRejectsClipboardInstallationMediaAndShares() throws {
    var clipboard = try makeMachine()
    clipboard = try replacingManifest(clipboard) { manifest in
      let current = try #require(manifest.linuxConfiguration)
      manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
        efiVariableStorePath: current.efiVariableStorePath,
        machineIdentifierPath: current.machineIdentifierPath,
        installationMediaPath: nil,
        macAddress: current.macAddress,
        sharesClipboard: true,
        linuxBoxDescriptor: current.linuxBoxDescriptor
      )
    }
    #expect(throws: LinuxVirtualMachineError.self) {
      _ = try LinuxVirtualMachineConfigurationDescriptorService().descriptor(for: clipboard)
    }

    var media = try makeMachine()
    media = try replacingManifest(media) { manifest in
      let current = try #require(manifest.linuxConfiguration)
      manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
        efiVariableStorePath: current.efiVariableStorePath,
        machineIdentifierPath: current.machineIdentifierPath,
        installationMediaPath: "Installer.iso",
        macAddress: current.macAddress,
        sharesClipboard: false,
        linuxBoxDescriptor: current.linuxBoxDescriptor
      )
    }
    #expect(throws: LinuxVirtualMachineError.self) {
      _ = try LinuxVirtualMachineConfigurationDescriptorService().descriptor(for: media)
    }

    let shared = VirtualMachineSharedDirectory(
      id: UUID(),
      guestName: "host",
      bookmarkData: Data([1]),
      lastKnownPath: "/tmp/host",
      sourceIdentity: VirtualMachineSharedDirectorySourceIdentity(device: 1, inode: 2),
      readOnly: true
    )
    let sharedMachine = try makeMachine(
      sharedDirectories: VirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [shared]
      )
    )
    #expect(throws: LinuxVirtualMachineError.self) {
      _ = try LinuxVirtualMachineConfigurationDescriptorService().descriptor(for: sharedMachine)
    }
  }

  @Test
  func standardManagedTopologyKeepsOrdinaryLinuxConfiguration() throws {
    let shared = VirtualMachineSharedDirectory(
      id: UUID(),
      guestName: "host",
      bookmarkData: Data([1]),
      lastKnownPath: "/tmp/host",
      sourceIdentity: VirtualMachineSharedDirectorySourceIdentity(device: 1, inode: 2),
      readOnly: true
    )
    var machine = try makeMachine(
      profile: .standard,
      sharedDirectories: VirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [shared]
      )
    )
    machine = try replacingManifest(machine) { manifest in
      let current = try #require(manifest.linuxConfiguration)
      manifest.networkConfiguration = VirtualMachineNetworkConfiguration(
        revision: 1,
        attachment: .hostOnly
      )
      manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
        efiVariableStorePath: current.efiVariableStorePath,
        machineIdentifierPath: current.machineIdentifierPath,
        installationMediaPath: "Installer.iso",
        macAddress: current.macAddress,
        sharesClipboard: true,
        linuxBoxDescriptor: current.linuxBoxDescriptor
      )
    }
    let descriptor = try LinuxVirtualMachineConfigurationDescriptorService()
      .descriptor(for: machine)
    #expect(machine.manifest.isManagedLinuxBox)
    #expect(!machine.manifest.isHardenedLinuxBox)
    #expect(descriptor.networkAttachment == "VmnetHostOnly")
    #expect(descriptor.sharesClipboard)
    #expect(descriptor.installationMediaPath == "Installer.iso")
    #expect(descriptor.directorySharingDevice != nil)
    #expect(descriptor.socketDevices == ["VirtioSocket/4050"])
  }

  @Test
  func ordinaryLinuxTopologyRemainsEditableAndSocketFree() throws {
    var manifest = try makeManifest(descriptor: nil)
    manifest.networkConfiguration = VirtualMachineNetworkConfiguration(
      revision: 1,
      attachment: .hostOnly
    )
    let machine = resolved(manifest: manifest)
    let descriptor = try LinuxVirtualMachineConfigurationDescriptorService()
      .descriptor(for: machine)

    #expect(!manifest.isManagedLinuxBox)
    #expect(descriptor.networkAttachment == "VmnetHostOnly")
    #expect(descriptor.consoleDevices == ["VirtioConsole/SPICEAgent"])
    #expect(descriptor.socketDevices.isEmpty)
  }

  private func makeMachine(
    profile: LinuxBoxProfile = .residential,
    sharedDirectories: LinuxVirtualMachineSharedDirectoryConfiguration = .empty
  ) throws -> ResolvedLinuxVirtualMachine {
    resolved(
      manifest: try makeManifest(
        descriptor: try makeDescriptor(profile: profile)
      ),
      sharedDirectories: sharedDirectories
    )
  }

  private func makeManifest(
    descriptor: LinuxBoxDescriptor?
  ) throws -> VirtualMachineManifest {
    var manifest = try VirtualMachineManifest(
      name: "Linux Box",
      guest: .linux,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 32 * VirtualMachineResources.bytesPerGiB
      )
    )
    manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
      efiVariableStorePath: "Platform/EFI.nvram",
      machineIdentifierPath: "Platform/MachineIdentifier.bin",
      installationMediaPath: nil,
      macAddress: "02:00:00:00:00:01",
      sharesClipboard: descriptor == nil,
      linuxBoxDescriptor: descriptor
    )
    return manifest
  }

  private func makeDescriptor(
    profile: LinuxBoxProfile = .standard
  ) throws -> LinuxBoxDescriptor {
    try LinuxBoxDescriptor(
      imageID: "nativecontainers-debian-13-arm64-v1",
      imageBuildRevision: "20260718.1",
      rawImageSHA512: String(repeating: "a", count: 128),
      profile: profile
    )
  }

  private func resolved(
    manifest: VirtualMachineManifest,
    sharedDirectories: LinuxVirtualMachineSharedDirectoryConfiguration = .empty
  ) -> ResolvedLinuxVirtualMachine {
    ResolvedLinuxVirtualMachine(
      manifest: manifest,
      bundleURL: URL(filePath: "/tmp/box.nativevm"),
      diskImageURL: URL(filePath: "/tmp/box.nativevm/Disk.img"),
      efiVariableStoreURL: URL(filePath: "/tmp/box.nativevm/Platform/EFI.nvram"),
      machineIdentifierURL: URL(
        filePath: "/tmp/box.nativevm/Platform/MachineIdentifier.bin"
      ),
      installationMediaURL: manifest.linuxConfiguration?.installationMediaPath.map {
        URL(filePath: "/tmp/box.nativevm/\($0)")
      },
      sharedDirectories: sharedDirectories
    )
  }

  private func replacingManifest(
    _ machine: ResolvedLinuxVirtualMachine,
    update: (inout VirtualMachineManifest) throws -> Void
  ) throws -> ResolvedLinuxVirtualMachine {
    var manifest = machine.manifest
    try update(&manifest)
    return resolved(manifest: manifest, sharedDirectories: machine.sharedDirectories)
  }
}
