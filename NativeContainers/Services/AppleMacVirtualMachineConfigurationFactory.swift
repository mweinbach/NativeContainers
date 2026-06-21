import Foundation
@preconcurrency import Virtualization

#if arch(arm64)
  @MainActor
  struct AppleMacVirtualMachineConfigurationFactory {
    func makeConfiguration(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VZVirtualMachineConfiguration {
      let resources = machine.manifest.resources
      guard resources.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        resources.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount
      else {
        throw MacVirtualMachineInstallationError.unsupportedCPUCount(resources.cpuCount)
      }
      guard resources.memoryBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        resources.memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize,
        resources.memoryBytes.isMultiple(of: 1_048_576)
      else {
        throw MacVirtualMachineInstallationError.unsupportedMemorySize(resources.memoryBytes)
      }

      let diskSize = try diskSize(at: machine.diskImageURL)
      guard diskSize == resources.diskBytes, diskSize.isMultiple(of: 512) else {
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
          widthInPixels: 1_920,
          heightInPixels: 1_200,
          pixelsPerInch: 144
        )
      ]

      let network = VZVirtioNetworkDeviceConfiguration()
      network.attachment = VZNATNetworkDeviceAttachment()

      let configuration = VZVirtualMachineConfiguration()
      configuration.platform = platform
      configuration.bootLoader = VZMacOSBootLoader()
      configuration.cpuCount = resources.cpuCount
      configuration.memorySize = resources.memoryBytes
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

    private func diskSize(at url: URL) throws -> UInt64 {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let number = attributes[.size] as? NSNumber else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(0)
      }
      return number.uint64Value
    }
  }
#endif
