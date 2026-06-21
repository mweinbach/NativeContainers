@preconcurrency import Virtualization

#if arch(arm64)
  @MainActor
  struct AppleMacVirtualMachineAudioDeviceFactory {
    func makeDevice(
      configuration: MacVirtualMachineAudioConfiguration
    ) -> VZVirtioSoundDeviceConfiguration {
      let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
      outputStream.sink = VZHostAudioOutputStreamSink()

      var streams: [VZVirtioSoundDeviceStreamConfiguration] = [outputStream]
      if configuration.isMicrophoneEnabled {
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        streams.append(inputStream)
      }

      let device = VZVirtioSoundDeviceConfiguration()
      device.streams = streams
      return device
    }
  }
#endif
