import Foundation
@preconcurrency import Virtualization

#if arch(arm64)
  struct AppleMacVirtualMachineRuntimeConfiguration {
    let configuration: VZVirtualMachineConfiguration
    let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
    let sharedDirectoryAccess: MacVirtualMachineSharedDirectoryAccess
  }

  @MainActor
  struct AppleMacVirtualMachineConfigurationFactory {
    private let descriptorService: any MacVirtualMachineConfigurationDescribing
    private let sharedDirectoryBookmarkService:
      any MacVirtualMachineSharedDirectoryBookmarkResolving
    private let sharedDirectoryDeviceFactory: AppleMacVirtualMachineSharedDirectoryDeviceFactory
    private let networkDeviceFactory: AppleMacVirtualMachineNetworkDeviceFactory
    private let audioDeviceFactory: AppleMacVirtualMachineAudioDeviceFactory
    private let diskImageService: any AppleVirtualMachineDiskImageServicing

    init(
      descriptorService: any MacVirtualMachineConfigurationDescribing =
        MacVirtualMachineConfigurationDescriptorService(),
      sharedDirectoryBookmarkService:
        any MacVirtualMachineSharedDirectoryBookmarkResolving =
        MacVirtualMachineSharedDirectoryBookmarkService(),
      sharedDirectoryDeviceFactory: AppleMacVirtualMachineSharedDirectoryDeviceFactory =
        AppleMacVirtualMachineSharedDirectoryDeviceFactory(),
      networkDeviceFactory: AppleMacVirtualMachineNetworkDeviceFactory =
        AppleMacVirtualMachineNetworkDeviceFactory(),
      audioDeviceFactory: AppleMacVirtualMachineAudioDeviceFactory =
        AppleMacVirtualMachineAudioDeviceFactory(),
      diskImageService: any AppleVirtualMachineDiskImageServicing =
        AppleVirtualMachineDiskImageService()
    ) {
      self.descriptorService = descriptorService
      self.sharedDirectoryBookmarkService = sharedDirectoryBookmarkService
      self.sharedDirectoryDeviceFactory = sharedDirectoryDeviceFactory
      self.networkDeviceFactory = networkDeviceFactory
      self.audioDeviceFactory = audioDeviceFactory
      self.diskImageService = diskImageService
    }

    func makeConfiguration(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VZVirtualMachineConfiguration {
      let descriptor = try descriptorService.descriptor(for: machine)
      guard descriptor.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        descriptor.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount
      else {
        throw MacVirtualMachineInstallationError.unsupportedCPUCount(descriptor.cpuCount)
      }
      guard descriptor.memoryBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        descriptor.memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize,
        descriptor.memoryBytes.isMultiple(of: 1_048_576)
      else {
        throw MacVirtualMachineInstallationError.unsupportedMemorySize(
          descriptor.memoryBytes
        )
      }

      let diskImage = try diskImageService.descriptor(for: machine)
      guard diskImage.logicalBytes == descriptor.diskBytes,
        diskImage.logicalBytes.isMultiple(of: 512)
      else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(
          diskImage.logicalBytes
        )
      }

      let hardwareModelData = try Data(contentsOf: machine.hardwareModelURL)
      guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
        throw MacVirtualMachineInstallationError.invalidHardwareModel
      }
      let machineIdentifierData = try Data(contentsOf: machine.machineIdentifierURL)
      guard
        let machineIdentifier = VZMacMachineIdentifier(
          dataRepresentation: machineIdentifierData
        )
      else {
        throw MacVirtualMachineInstallationError.invalidMachineIdentifier
      }

      let platform = VZMacPlatformConfiguration()
      platform.hardwareModel = hardwareModel
      platform.machineIdentifier = machineIdentifier
      platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: machine.auxiliaryStorageURL)

      let diskAttachment = try diskImageService.makeWritableAttachment(
        for: machine
      )
      let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

      let graphics = VZMacGraphicsDeviceConfiguration()
      graphics.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: descriptor.displayWidth,
          heightInPixels: descriptor.displayHeight,
          pixelsPerInch: descriptor.displayPixelsPerInch
        )
      ]

      let network = try networkDeviceFactory.makeDevice(
        configuration: machine.manifest.effectiveNetworkConfiguration,
        macAddress: descriptor.macAddress
      )

      let configuration = VZVirtualMachineConfiguration()
      configuration.platform = platform
      configuration.bootLoader = VZMacOSBootLoader()
      configuration.cpuCount = descriptor.cpuCount
      configuration.memorySize = descriptor.memoryBytes
      configuration.storageDevices = [disk]
      configuration.graphicsDevices = [graphics]
      configuration.networkDevices = [network]
      configuration.audioDevices = [
        audioDeviceFactory.makeDevice(
          configuration: machine.manifest.effectiveAudioConfiguration
        )
      ]
      configuration.keyboards = [
        VZMacKeyboardConfiguration(),
        VZUSBKeyboardConfiguration(),
      ]
      configuration.pointingDevices = [
        VZMacTrackpadConfiguration(),
        VZUSBScreenCoordinatePointingDeviceConfiguration(),
      ]
      configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
      configuration.memoryBalloonDevices = [
        VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
      ]

      do {
        try configuration.validate()
      } catch {
        throw MacVirtualMachineInstallationError.invalidConfiguration(
          error.localizedDescription
        )
      }
      return configuration
    }

    func makeRuntimeConfiguration(
      for machine: ResolvedMacVirtualMachine
    ) throws -> AppleMacVirtualMachineRuntimeConfiguration {
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
      } catch {
        sharedDirectoryAccess.release()
        throw error
      }
      let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
      if machine.manifest.effectiveNetworkConfiguration.attachment.usesCustomVmnetNetwork {
        saveRestoreSupport = .unsupported(
          "Suspend is unavailable while this VM uses a shared or host-only network."
        )
      } else {
        do {
          try configuration.validateSaveRestoreSupport()
          saveRestoreSupport = .supported
        } catch {
          saveRestoreSupport = .unsupported(error.localizedDescription)
        }
      }
      return AppleMacVirtualMachineRuntimeConfiguration(
        configuration: configuration,
        saveRestoreSupport: saveRestoreSupport,
        sharedDirectoryAccess: sharedDirectoryAccess
      )
    }

  }
#endif
