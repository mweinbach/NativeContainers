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
    guard let linuxConfiguration = machine.manifest.linuxConfiguration else {
      throw LinuxVirtualMachineError.missingManifestValue("linuxConfiguration")
    }

    let machineIdentifierData = try Data(contentsOf: machine.machineIdentifierURL)
    guard
      let machineIdentifier = VZGenericMachineIdentifier(
        dataRepresentation: machineIdentifierData
      )
    else {
      throw LinuxVirtualMachineError.invalidMachineIdentifier
    }
    guard let macAddress = VZMACAddress(string: linuxConfiguration.macAddress) else {
      throw LinuxVirtualMachineError.invalidMACAddress(linuxConfiguration.macAddress)
    }

    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = machineIdentifier

    let bootLoader = VZEFIBootLoader()
    bootLoader.variableStore = VZEFIVariableStore(url: machine.efiVariableStoreURL)

    let diskAttachment = try diskImageService.makeWritableAttachment(
      for: machine
    )
    let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
    var usbControllers: [VZUSBControllerConfiguration] = []
    if let installationMediaURL = machine.installationMediaURL {
      let installationAttachment = try VZDiskImageStorageDeviceAttachment(
        url: installationMediaURL,
        readOnly: true
      )
      let controller = VZXHCIControllerConfiguration()
      controller.usbDevices = [
        VZUSBMassStorageDeviceConfiguration(attachment: installationAttachment)
      ]
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
    if linuxConfiguration.sharesClipboard {
      configuration.consoleDevices = [makeSpiceConsole()]
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
