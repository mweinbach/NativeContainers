import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

#if arch(arm64)
  @Suite("Mac virtual machine audio devices")
  @MainActor
  struct AppleMacVirtualMachineAudioDeviceFactoryTests {
    @Test
    func createsOneVirtioHostOutputStreamWithoutMicrophoneInput() throws {
      let device = AppleMacVirtualMachineAudioDeviceFactory().makeOutputDevice()

      #expect(device.streams.count == 1)
      let output = try #require(
        device.streams.first as? VZVirtioSoundDeviceOutputStreamConfiguration
      )
      #expect(output.sink is VZHostAudioOutputStreamSink)
      #expect(
        !device.streams.contains {
          $0 is VZVirtioSoundDeviceInputStreamConfiguration
        }
      )
    }
  }
#endif
