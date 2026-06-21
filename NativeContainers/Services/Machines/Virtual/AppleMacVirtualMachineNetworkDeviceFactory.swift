import Foundation
@preconcurrency import Virtualization

#if arch(arm64)
  @MainActor
  struct AppleMacVirtualMachineNetworkDeviceFactory {
    private let vmnetNetworks: AppleMacVirtualMachineVmnetNetworkPool

    init(
      vmnetNetworks: AppleMacVirtualMachineVmnetNetworkPool =
        AppleMacVirtualMachineVmnetNetworkPool()
    ) {
      self.vmnetNetworks = vmnetNetworks
    }

    func makeDevice(
      configuration: MacVirtualMachineNetworkConfiguration,
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
        throw MacVirtualMachineNetworkError.invalidMACAddress(macAddress)
      }

      let device = VZVirtioNetworkDeviceConfiguration()
      device.attachment = attachment
      device.macAddress = macAddress
      return device
    }
  }
#endif
