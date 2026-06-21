import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine audio model")
@MainActor
struct MacVirtualMachineAudioModelTests {
  @Test
  func loadPublishesPersistedConfigurationAndAuthorization() async {
    let machineID = UUID()
    let service = AudioModelService(
      snapshot: MacVirtualMachineAudioSnapshot(
        configuration: MacVirtualMachineAudioConfiguration(
          revision: 4,
          isMicrophoneEnabled: true
        ),
        microphoneAuthorization: .authorized
      )
    )
    let model = MacVirtualMachineAudioModel(
      machineID: machineID,
      service: service
    )

    await model.load()

    #expect(model.isMicrophoneEnabled)
    #expect(model.microphoneAuthorization == .authorized)
    #expect(model.errorMessage == nil)
    #expect(await service.snapshotCount == 1)

    await model.load()
    #expect(await service.snapshotCount == 1)
  }

  @Test
  func successfulMutationPublishesTheReturnedSnapshot() async {
    let machineID = UUID()
    let service = AudioModelService(
      snapshot: MacVirtualMachineAudioSnapshot(
        configuration: .disconnected,
        microphoneAuthorization: .notDetermined
      )
    )
    let model = MacVirtualMachineAudioModel(
      machineID: machineID,
      service: service
    )

    let changed = await model.setMicrophoneEnabled(true)

    #expect(changed)
    #expect(model.isMicrophoneEnabled)
    #expect(model.microphoneAuthorization == .authorized)
    #expect(await service.setCount == 1)
  }

  @Test
  func failedMutationKeepsThePriorSettingAndSurfacesTheError() async {
    let machineID = UUID()
    let service = AudioModelService(
      snapshot: MacVirtualMachineAudioSnapshot(
        configuration: .disconnected,
        microphoneAuthorization: .denied
      ),
      mutationError: MacVirtualMachineAudioError.microphoneAccessDenied
    )
    let model = MacVirtualMachineAudioModel(
      machineID: machineID,
      initialAuthorization: .denied,
      service: service
    )

    let changed = await model.setMicrophoneEnabled(true)

    #expect(!changed)
    #expect(!model.isMicrophoneEnabled)
    #expect(model.microphoneAuthorization == .denied)
    #expect(model.errorMessage?.contains("Microphone access is denied") == true)

    model.clearError()
    #expect(model.errorMessage == nil)
  }
}

private actor AudioModelService: MacVirtualMachineAudioManaging {
  private var current: MacVirtualMachineAudioSnapshot
  private let mutationError: MacVirtualMachineAudioError?
  private(set) var snapshotCount = 0
  private(set) var setCount = 0

  init(
    snapshot: MacVirtualMachineAudioSnapshot,
    mutationError: MacVirtualMachineAudioError? = nil
  ) {
    current = snapshot
    self.mutationError = mutationError
  }

  func snapshot(id: UUID) throws -> MacVirtualMachineAudioSnapshot {
    snapshotCount += 1
    return current
  }

  func setMicrophoneEnabled(
    _ isEnabled: Bool,
    for machineID: UUID
  ) throws -> MacVirtualMachineAudioSnapshot {
    setCount += 1
    if let mutationError {
      throw mutationError
    }
    current = MacVirtualMachineAudioSnapshot(
      configuration: try current.configuration.settingMicrophoneEnabled(
        isEnabled
      ),
      microphoneAuthorization: isEnabled ? .authorized : .notDetermined
    )
    return current
  }
}
