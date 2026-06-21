@preconcurrency import Virtualization

#if arch(arm64)
  @MainActor
  struct AppleMacVirtualMachineAudioDeviceFactory {
    func makeOutputDevice() -> VZVirtioSoundDeviceConfiguration {
      let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
      outputStream.sink = VZHostAudioOutputStreamSink()

      let device = VZVirtioSoundDeviceConfiguration()
      device.streams = [outputStream]
      return device
    }
  }
#endif
