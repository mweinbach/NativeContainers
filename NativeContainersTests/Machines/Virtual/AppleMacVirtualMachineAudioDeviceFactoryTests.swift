import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

#if arch(arm64)
  @Suite("Mac virtual machine audio devices")
  @MainActor
  struct AppleMacVirtualMachineAudioDeviceFactoryTests {
    @Test
    func disconnectedMicrophoneCreatesOnlyTheHostOutputStream() throws {
      let device = AppleMacVirtualMachineAudioDeviceFactory().makeDevice(
        configuration: .disconnected
      )

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

    @Test
    func enabledMicrophoneCreatesAHostInputStream() throws {
      let device = AppleMacVirtualMachineAudioDeviceFactory().makeDevice(
        configuration: MacVirtualMachineAudioConfiguration(
          revision: 1,
          isMicrophoneEnabled: true
        )
      )

      #expect(device.streams.count == 2)
      let input = try #require(
        device.streams.last as? VZVirtioSoundDeviceInputStreamConfiguration
      )
      #expect(input.source is VZHostAudioInputStreamSource)
    }
  }
#endif
