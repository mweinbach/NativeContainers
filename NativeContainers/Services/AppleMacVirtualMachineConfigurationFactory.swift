import Foundation
@preconcurrency import Virtualization

#if arch(arm64)
  struct AppleMacVirtualMachineRuntimeConfiguration {
    let configuration: VZVirtualMachineConfiguration
    let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
  }

  @MainActor
  struct AppleMacVirtualMachineConfigurationFactory {
    private let descriptorService: any MacVirtualMachineConfigurationDescribing

    init(
      descriptorService: any MacVirtualMachineConfigurationDescribing =
        MacVirtualMachineConfigurationDescriptorService()
    ) {
      self.descriptorService = descriptorService
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

      let diskSize = try diskSize(at: machine.diskImageURL)
      guard diskSize == descriptor.diskBytes, diskSize.isMultiple(of: 512) else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(diskSize)
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

      let diskAttachment = try VZDiskImageStorageDeviceAttachment(
        url: machine.diskImageURL,
        readOnly: false,
        cachingMode: .automatic,
        synchronizationMode: .full
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

      let network = VZVirtioNetworkDeviceConfiguration()
      network.attachment = VZNATNetworkDeviceAttachment()
      guard let macAddress = VZMACAddress(string: descriptor.macAddress) else {
        throw MacVirtualMachineInstallationError.invalidConfiguration(
          "the deterministic network address is invalid"
        )
      }
      network.macAddress = macAddress

      let configuration = VZVirtualMachineConfiguration()
      configuration.platform = platform
      configuration.bootLoader = VZMacOSBootLoader()
      configuration.cpuCount = descriptor.cpuCount
      configuration.memorySize = descriptor.memoryBytes
      configuration.storageDevices = [disk]
      configuration.graphicsDevices = [graphics]
      configuration.networkDevices = [network]
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
      let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
      do {
        try configuration.validateSaveRestoreSupport()
        saveRestoreSupport = .supported
      } catch {
        saveRestoreSupport = .unsupported(error.localizedDescription)
      }
      return AppleMacVirtualMachineRuntimeConfiguration(
        configuration: configuration,
        saveRestoreSupport: saveRestoreSupport
      )
    }

    private func diskSize(at url: URL) throws -> UInt64 {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let number = attributes[.size] as? NSNumber else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(0)
      }
      return number.uint64Value
    }
  }
#endif
