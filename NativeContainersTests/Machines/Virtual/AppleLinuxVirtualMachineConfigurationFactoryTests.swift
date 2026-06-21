import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

@MainActor
struct AppleLinuxVirtualMachineConfigurationFactoryTests {
  @Test
  func buildsValidatedEFILinuxConfigurationWithGUIAndClipboardDevices() async throws {
    let fixture = try LinuxConfigurationFixture()
    defer { fixture.remove() }
    let prepared = try await fixture.prepare()
    let machine = try LinuxVirtualMachineBundleResolver(
      rootURL: fixture.root
    ).resolve(prepared)

    let configuration = try AppleLinuxVirtualMachineConfigurationFactory()
      .makeConfiguration(for: machine)

    let platform = try #require(
      configuration.platform as? VZGenericPlatformConfiguration
    )
    #expect(
      platform.machineIdentifier.dataRepresentation
        == (try Data(contentsOf: machine.machineIdentifierURL))
    )
    let bootLoader = try #require(configuration.bootLoader as? VZEFIBootLoader)
    #expect(bootLoader.variableStore?.url == machine.efiVariableStoreURL)
    #expect(configuration.cpuCount == prepared.resources.cpuCount)
    #expect(configuration.memorySize == prepared.resources.memoryBytes)

    #expect(configuration.usbControllers.count == 1)
    let controller = try #require(
      configuration.usbControllers[0] as? VZXHCIControllerConfiguration
    )
    let installer = try #require(
      controller.usbDevices.first as? VZUSBMassStorageDeviceConfiguration
    )
    let installerAttachment = try #require(
      installer.attachment as? VZDiskImageStorageDeviceAttachment
    )
    #expect(installerAttachment.url == machine.installationMediaURL)
    #expect(installerAttachment.isReadOnly)

    #expect(configuration.storageDevices.count == 1)
    let disk = try #require(
      configuration.storageDevices[0] as? VZVirtioBlockDeviceConfiguration
    )
    let diskAttachment = try #require(
      disk.attachment as? VZDiskImageStorageDeviceAttachment
    )
    #expect(diskAttachment.url == machine.diskImageURL)
    #expect(!diskAttachment.isReadOnly)

    let graphics = try #require(
      configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration
    )
    #expect(graphics.scanouts.count == 1)
    #expect(
      graphics.scanouts[0].widthInPixels
        == AppleLinuxVirtualMachineConfigurationFactory.defaultDisplayWidth
    )
    #expect(
      graphics.scanouts[0].heightInPixels
        == AppleLinuxVirtualMachineConfigurationFactory.defaultDisplayHeight
    )

    let network = try #require(
      configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
    )
    #expect(network.attachment is VZNATNetworkDeviceAttachment)
    #expect(network.macAddress.string == prepared.linuxConfiguration?.macAddress)

    #expect(configuration.audioDevices.first is VZVirtioSoundDeviceConfiguration)
    #expect(configuration.keyboards.first is VZUSBKeyboardConfiguration)
    #expect(
      configuration.pointingDevices.first
        is VZUSBScreenCoordinatePointingDeviceConfiguration
    )
    #expect(configuration.entropyDevices.first is VZVirtioEntropyDeviceConfiguration)
    #expect(
      configuration.memoryBalloonDevices.first
        is VZVirtioTraditionalMemoryBalloonDeviceConfiguration
    )

    let console = try #require(
      configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration
    )
    let port = try #require(console.ports[0])
    #expect(port.name == VZSpiceAgentPortAttachment.spiceAgentPortName)
    let spiceAttachment = try #require(
      port.attachment as? VZSpiceAgentPortAttachment
    )
    #expect(spiceAttachment.sharesClipboard)
  }

  @Test
  func omitsSpiceConsoleWhenClipboardSharingIsDisabled() async throws {
    let fixture = try LinuxConfigurationFixture()
    defer { fixture.remove() }
    var prepared = try await fixture.prepare()
    prepared.linuxConfiguration?.sharesClipboard = false
    let machine = try LinuxVirtualMachineBundleResolver(
      rootURL: fixture.root
    ).resolve(prepared)

    let configuration = try AppleLinuxVirtualMachineConfigurationFactory()
      .makeConfiguration(for: machine)

    #expect(configuration.consoleDevices.isEmpty)
  }

  @Test
  func runtimeConfigurationAttachesResolvedVirtioFSShare() async throws {
    let fixture = try LinuxConfigurationFixture()
    defer { fixture.remove() }
    let prepared = try await fixture.prepare()
    let machine = try LinuxVirtualMachineBundleResolver(
      rootURL: fixture.root
    ).resolve(prepared)
    let source = fixture.root.appending(
      path: "Shared",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: false
    )
    let directory = ResolvedLinuxVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: "Projects",
      sourceURL: source,
      sourceIdentity: .init(device: 1, inode: 2),
      readOnly: false
    )
    let factory = AppleLinuxVirtualMachineConfigurationFactory(
      sharedDirectoryBookmarkService: LinuxConfigurationSharedDirectoryResolver(
        directories: [directory]
      )
    )

    let runtime = try factory.makeRuntimeConfiguration(for: machine)
    defer { runtime.sharedDirectoryAccess.release() }
    let device = try #require(
      runtime.configuration.directorySharingDevices.first
        as? VZVirtioFileSystemDeviceConfiguration
    )
    let share = try #require(device.share as? VZMultipleDirectoryShare)

    #expect(
      device.tag == AppleLinuxVirtualMachineSharedDirectoryDeviceFactory.mountTag
    )
    #expect(Set(share.directories.keys) == ["Projects"])
    #expect(share.directories["Projects"]?.url == source)
  }

  @Test
  func resolverRejectsLinuxArtifactPathTraversal() async throws {
    let fixture = try LinuxConfigurationFixture()
    defer { fixture.remove() }
    var prepared = try await fixture.prepare()
    let current = try #require(prepared.linuxConfiguration)
    prepared.linuxConfiguration = LinuxVirtualMachineConfiguration(
      efiVariableStorePath: "../Outside",
      machineIdentifierPath: current.machineIdentifierPath,
      installationMediaPath: current.installationMediaPath,
      macAddress: current.macAddress
    )

    #expect(
      throws: LinuxVirtualMachineError.invalidArtifact("efiVariableStorePath")
    ) {
      try LinuxVirtualMachineBundleResolver(rootURL: fixture.root).resolve(prepared)
    }
  }
}

private struct LinuxConfigurationSharedDirectoryResolver:
  LinuxVirtualMachineSharedDirectoryBookmarkResolving
{
  let directories: [ResolvedLinuxVirtualMachineSharedDirectory]

  func resolve(
    _ records: [LinuxVirtualMachineSharedDirectory]
  ) -> LinuxVirtualMachineSharedDirectoryAccess {
    LinuxVirtualMachineSharedDirectoryAccess(
      directories: directories,
      accessedURLs: []
    )
  }
}

private enum LinuxConfigurationFixtureError: Error {
  case isoCreationFailed
}

private struct LinuxConfigurationFixture {
  let root: URL
  let installationMedia: URL
  let resources: VirtualMachineResources

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LinuxConfigurationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    installationMedia = root.appending(path: "Installer.iso")
    let sourceDirectory = root.appending(
      path: "ISOContents",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: false
    )
    try Data("test ISO payload".utf8).write(
      to: sourceDirectory.appending(path: "payload")
    )
    let isoBuilder = Process()
    isoBuilder.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    isoBuilder.arguments = [
      "makehybrid",
      "-iso",
      "-o",
      installationMedia.path,
      sourceDirectory.path,
    ]
    isoBuilder.standardOutput = FileHandle.nullDevice
    isoBuilder.standardError = FileHandle.nullDevice
    try isoBuilder.run()
    isoBuilder.waitUntilExit()
    guard isoBuilder.terminationStatus == 0 else {
      throw LinuxConfigurationFixtureError.isoCreationFailed
    }
    resources = try VirtualMachineResources(
      cpuCount: 2,
      memoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
  }

  func prepare() async throws -> VirtualMachineManifest {
    let library = VirtualMachineLibrary(rootURL: root)
    let draft = try await library.createDraft(
      name: "Linux Configuration",
      guest: .linux,
      resources: resources
    )
    return try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: installationMedia
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
