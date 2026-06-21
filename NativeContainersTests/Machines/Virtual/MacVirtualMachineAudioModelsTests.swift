import Testing

@testable import NativeContainers

struct MacVirtualMachineAudioModelsTests {
  @Test
  func configurationRevisionChangesOnlyWithTheHardwareSetting() throws {
    let initial = MacVirtualMachineAudioConfiguration.disconnected
    let unchanged = try initial.settingMicrophoneEnabled(false)
    let enabled = try initial.settingMicrophoneEnabled(true)

    #expect(unchanged == initial)
    #expect(enabled.revision == 1)
    #expect(enabled.isMicrophoneEnabled)
    #expect(
      throws: MacVirtualMachineAudioError.configurationRevisionOverflow
    ) {
      _ = try MacVirtualMachineAudioConfiguration(
        revision: .max,
        isMicrophoneEnabled: false
      ).settingMicrophoneEnabled(true)
    }
  }
}
