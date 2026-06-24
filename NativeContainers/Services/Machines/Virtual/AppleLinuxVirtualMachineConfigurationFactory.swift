import Foundation
@preconcurrency import Virtualization

struct AppleLinuxVirtualMachineRuntimeConfiguration {
  let configuration: VZVirtualMachineConfiguration
  let saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport
  let sharedDirectoryAccess: LinuxVirtualMachineSharedDirectoryAccess
}

@MainActor
struct AppleLinuxVirtualMachineConfigurationFactory {
  nonisolated static let defaultDisplayWidth = 1_280
  nonisolated static let defaultDisplayHeight = 800

  private let sharedDirectoryBookmarkService:
    any LinuxVirtualMachineSharedDirectoryBookmarkResolving
  private let sharedDirectoryDeviceFactory: AppleLinuxVirtualMachineSharedDirectoryDeviceFactory
  private let networkDeviceFactory: AppleVirtualMachineNetworkDeviceFactory
  private let diskImageService: any AppleVirtualMachineDiskImageServicing

  init(
    sharedDirectoryBookmarkService:
      any LinuxVirtualMachineSharedDirectoryBookmarkResolving =
      LinuxVirtualMachineSharedDirectoryBookmarkService(),
    sharedDirectoryDeviceFactory:
      AppleLinuxVirtualMachineSharedDirectoryDeviceFactory =
      AppleLinuxVirtualMachineSharedDirectoryDeviceFactory(),
    networkDeviceFactory: AppleVirtualMachineNetworkDeviceFactory =
      AppleVirtualMachineNetworkDeviceFactory(),
    diskImageService: any AppleVirtualMachineDiskImageServicing =
      AppleVirtualMachineDiskImageService()
  ) {
    self.sharedDirectoryBookmarkService = sharedDirectoryBookmarkService
    self.sharedDirectoryDeviceFactory = sharedDirectoryDeviceFactory
    self.networkDeviceFactory = networkDeviceFactory
    self.diskImageService = diskImageService
  }

  func makeConfiguration(
    for machine: ResolvedLinuxVirtualMachine
  ) throws -> VZVirtualMachineConfiguration {
    let resources = machine.manifest.resources
    guard resources.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      resources.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount
    else {
      throw LinuxVirtualMachineError.unsupportedCPUCount(resources.cpuCount)
    }
    guard resources.memoryBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      resources.memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize,
      resources.memoryBytes.isMultiple(of: 1_048_576)
    else {
      throw LinuxVirtualMachineError.unsupportedMemorySize(resources.memoryBytes)
    }
    let macAddressString: String
    let sharesClipboard: Bool
    switch machine.manifest.guest {
    case .linux:
      guard let configuration = machine.manifest.linuxConfiguration else {
        throw LinuxVirtualMachineError.missingManifestValue("linuxConfiguration")
      }
      macAddressString = configuration.macAddress
      sharesClipboard = configuration.sharesClipboard
    case .windows:
      guard let configuration = machine.manifest.windowsConfiguration else {
        throw WindowsVirtualMachineError.missingManifestValue("windowsConfiguration")
      }
      guard configuration.securityMode.isCurrentlyBootable else {
        throw WindowsVirtualMachineError.secureBootBootUnavailable
      }
      macAddressString = configuration.macAddress
      sharesClipboard = configuration.sharesClipboard
    case .macOS:
      throw VirtualMachineModelError.requiresLinuxGuest(machine.manifest.id)
    }

    let machineIdentifierData = try Data(contentsOf: machine.machineIdentifierURL)
    guard
      let machineIdentifier = VZGenericMachineIdentifier(
        dataRepresentation: machineIdentifierData
      )
    else {
      throw LinuxVirtualMachineError.invalidMachineIdentifier
    }
    guard let macAddress = VZMACAddress(string: macAddressString) else {
      throw LinuxVirtualMachineError.invalidMACAddress(macAddressString)
    }

    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = machineIdentifier

    let bootLoader = VZEFIBootLoader()
    bootLoader.variableStore = VZEFIVariableStore(url: machine.efiVariableStoreURL)

    let diskAttachment = try diskImageService.makeWritableAttachment(
      for: machine
    )
    let disk: VZStorageDeviceConfiguration =
      if machine.manifest.guest == .windows {
        VZNVMExpressControllerDeviceConfiguration(attachment: diskAttachment)
      } else {
        VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
      }
    var usbControllers: [VZUSBControllerConfiguration] = []
    let removableMediaURLs: [URL]
    if machine.manifest.guest == .windows {
      // Virtualization exposes USB mass storage rather than an optical drive.
      // The setup image is the UEFI-bootable FAT32 mirror of the source ISO.
      removableMediaURLs = [
        machine.setupConfigurationMediaURL,
        machine.guestToolsMediaURL,
      ].compactMap { $0 }
    } else {
      removableMediaURLs = [machine.installationMediaURL].compactMap { $0 }
    }
    if !removableMediaURLs.isEmpty {
      let controller = VZXHCIControllerConfiguration()
      controller.usbDevices = try removableMediaURLs.map { url in
        let attachment = try VZDiskImageStorageDeviceAttachment(
          url: url,
          readOnly: true
        )
        return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
      }
      usbControllers = [controller]
    }

    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: Self.defaultDisplayWidth,
        heightInPixels: Self.defaultDisplayHeight
      )
    ]

    let network = try networkDeviceFactory.makeDevice(
      configuration: machine.manifest.effectiveNetworkConfiguration,
      macAddress: macAddress.string
    )

    let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
    outputStream.sink = VZHostAudioOutputStreamSink()
    let sound = VZVirtioSoundDeviceConfiguration()
    sound.streams = [outputStream]

    let configuration = VZVirtualMachineConfiguration()
    configuration.platform = platform
    configuration.bootLoader = bootLoader
    configuration.cpuCount = resources.cpuCount
    configuration.memorySize = resources.memoryBytes
    configuration.storageDevices = [disk]
    configuration.usbControllers = usbControllers
    configuration.graphicsDevices = [graphics]
    configuration.networkDevices = [network]
    configuration.audioDevices = [sound]
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = [
      VZUSBScreenCoordinatePointingDeviceConfiguration()
    ]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.memoryBalloonDevices = [
      VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
    ]
    if machine.manifest.guest == .linux, sharesClipboard {
      configuration.consoleDevices = [makeSpiceConsole()]
    }
    if machine.manifest.guest == .windows {
      configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    }

    do {
      try configuration.validate()
    } catch {
      throw LinuxVirtualMachineError.invalidConfiguration(
        error.localizedDescription
      )
    }
    return configuration
  }

  func makeRuntimeConfiguration(
    for machine: ResolvedLinuxVirtualMachine
  ) throws -> AppleLinuxVirtualMachineRuntimeConfiguration {
    let configuration = try makeConfiguration(for: machine)
    let sharedDirectoryAccess = try sharedDirectoryBookmarkService.resolve(
      machine.sharedDirectories.directories
    )
    do {
      if let directorySharingDevice = try sharedDirectoryDeviceFactory.makeDevice(
        for: sharedDirectoryAccess.directories
      ) {
        configuration.directorySharingDevices = [directorySharingDevice]
        try configuration.validate()
      }
      return AppleLinuxVirtualMachineRuntimeConfiguration(
        configuration: configuration,
        saveRestoreSupport: saveRestoreSupport(for: configuration),
        sharedDirectoryAccess: sharedDirectoryAccess
      )
    } catch {
      sharedDirectoryAccess.release()
      throw error
    }
  }

  private func saveRestoreSupport(
    for configuration: VZVirtualMachineConfiguration
  ) -> LinuxVirtualMachineSaveRestoreSupport {
    do {
      try configuration.validateSaveRestoreSupport()
      return .supported
    } catch {
      return .unsupported(error.localizedDescription)
    }
  }

  private func makeSpiceConsole() -> VZVirtioConsoleDeviceConfiguration {
    let attachment = VZSpiceAgentPortAttachment()
    attachment.sharesClipboard = true

    let port = VZVirtioConsolePortConfiguration()
    port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    port.attachment = attachment

    let console = VZVirtioConsoleDeviceConfiguration()
    console.ports[0] = port
    return console
  }
}
