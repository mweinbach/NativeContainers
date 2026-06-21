import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

#if arch(arm64)
  @Suite("Mac virtual machine network devices", .serialized)
  @MainActor
  struct AppleMacVirtualMachineNetworkDeviceFactoryTests {
    @Test
    func automaticModeCreatesNATAttachment() throws {
      let device = try AppleMacVirtualMachineNetworkDeviceFactory().makeDevice(
        configuration: .nat,
        macAddress: "02:00:00:00:00:01"
      )

      #expect(device.attachment is VZNATNetworkDeviceAttachment)
      #expect(device.macAddress.string == "02:00:00:00:00:01")
    }

    @Test
    func sharedModeReusesTheAppOwnedLogicalNetwork() throws {
      let pool = AppleMacVirtualMachineVmnetNetworkPool()
      let factory = AppleMacVirtualMachineNetworkDeviceFactory(
        vmnetNetworks: pool
      )

      let first = try factory.makeDevice(
        configuration: MacVirtualMachineNetworkConfiguration(
          attachment: .shared
        ),
        macAddress: "02:00:00:00:00:02"
      )
      let second = try factory.makeDevice(
        configuration: MacVirtualMachineNetworkConfiguration(
          attachment: .shared
        ),
        macAddress: "02:00:00:00:00:03"
      )
      let firstAttachment = try #require(
        first.attachment as? VZVmnetNetworkDeviceAttachment
      )
      let secondAttachment = try #require(
        second.attachment as? VZVmnetNetworkDeviceAttachment
      )

      #expect(firstAttachment.network == secondAttachment.network)
    }

    @Test
    func hostOnlyModeCreatesAnIsolatedVmnetAttachment() throws {
      let device = try AppleMacVirtualMachineNetworkDeviceFactory().makeDevice(
        configuration: MacVirtualMachineNetworkConfiguration(
          attachment: .hostOnly
        ),
        macAddress: "02:00:00:00:00:04"
      )

      #expect(device.attachment is VZVmnetNetworkDeviceAttachment)
    }

    @Test
    func invalidMACAddressIsRejected() {
      #expect(
        throws: MacVirtualMachineNetworkError.invalidMACAddress("invalid")
      ) {
        _ = try AppleMacVirtualMachineNetworkDeviceFactory().makeDevice(
          configuration: .nat,
          macAddress: "invalid"
        )
      }
    }
  }
#endif
