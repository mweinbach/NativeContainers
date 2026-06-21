import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineAudioModel {
  let machineID: UUID

  private(set) var isMicrophoneEnabled: Bool
  private(set) var microphoneAuthorization: MacVirtualMachineMicrophoneAuthorizationStatus
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any MacVirtualMachineAudioManaging
  @ObservationIgnored private var hasLoaded = false

  init(
    machineID: UUID,
    initialConfiguration: MacVirtualMachineAudioConfiguration = .disconnected,
    initialAuthorization: MacVirtualMachineMicrophoneAuthorizationStatus = .notDetermined,
    service: any MacVirtualMachineAudioManaging
  ) {
    self.machineID = machineID
    isMicrophoneEnabled = initialConfiguration.isMicrophoneEnabled
    microphoneAuthorization = initialAuthorization
    self.service = service
  }

  func load() async {
    guard !hasLoaded, !isLoading, !isWorking else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      apply(try await service.snapshot(id: machineID))
      hasLoaded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func setMicrophoneEnabled(_ isEnabled: Bool) async -> Bool {
    guard !isLoading, !isWorking, isEnabled != isMicrophoneEnabled else {
      return false
    }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }

    do {
      apply(
        try await service.setMicrophoneEnabled(
          isEnabled,
          for: machineID
        )
      )
      hasLoaded = true
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func apply(_ snapshot: MacVirtualMachineAudioSnapshot) {
    isMicrophoneEnabled = snapshot.configuration.isMicrophoneEnabled
    microphoneAuthorization = snapshot.microphoneAuthorization
  }
}
