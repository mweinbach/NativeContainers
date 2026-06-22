import Foundation
@preconcurrency import Virtualization

#if arch(arm64)
  @MainActor
  struct AppleVirtualMachineNetworkDeviceFactory {
    private let vmnetNetworks: AppleVirtualMachineVmnetNetworkPool

    init(
      vmnetNetworks: AppleVirtualMachineVmnetNetworkPool =
        AppleVirtualMachineVmnetNetworkPool()
    ) {
      self.vmnetNetworks = vmnetNetworks
    }

    func makeDevice(
      configuration: VirtualMachineNetworkConfiguration,
      macAddress: String
    ) throws -> VZVirtioNetworkDeviceConfiguration {
      let attachment: VZNetworkDeviceAttachment
      switch configuration.attachment {
      case .nat:
        attachment = VZNATNetworkDeviceAttachment()
      case .shared, .hostOnly:
        attachment = VZVmnetNetworkDeviceAttachment(
          network: try vmnetNetworks.network(for: configuration.attachment)
        )
      }

      guard let macAddress = VZMACAddress(string: macAddress) else {
        throw VirtualMachineNetworkError.invalidMACAddress(macAddress)
      }

      let device = VZVirtioNetworkDeviceConfiguration()
      device.attachment = attachment
      device.macAddress = macAddress
      return device
    }
  }

  typealias AppleMacVirtualMachineNetworkDeviceFactory =
    AppleVirtualMachineNetworkDeviceFactory
#endif
