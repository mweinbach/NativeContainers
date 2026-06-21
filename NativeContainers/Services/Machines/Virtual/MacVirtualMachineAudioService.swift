import Foundation

protocol MacVirtualMachineAudioConfigurationPersisting: Sendable {
  func macOSAudioConfiguration(
    id: UUID
  ) async throws -> MacVirtualMachineAudioConfiguration

  func setMacOSMicrophoneEnabled(
    _ isEnabled: Bool,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineAudioConfiguration
}

protocol MacVirtualMachineAudioManaging: Sendable {
  func snapshot(id: UUID) async throws -> MacVirtualMachineAudioSnapshot

  func setMicrophoneEnabled(
    _ isEnabled: Bool,
    for machineID: UUID
  ) async throws -> MacVirtualMachineAudioSnapshot
}

struct UnavailableMacVirtualMachineAudioService:
  MacVirtualMachineAudioManaging
{
  func snapshot(id: UUID) async throws -> MacVirtualMachineAudioSnapshot {
    throw MacVirtualMachineAudioError.unavailable
  }

  func setMicrophoneEnabled(
    _ isEnabled: Bool,
    for machineID: UUID
  ) async throws -> MacVirtualMachineAudioSnapshot {
    throw MacVirtualMachineAudioError.unavailable
  }
}

actor MacVirtualMachineAudioService: MacVirtualMachineAudioManaging {
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineAudioConfigurationPersisting
  private let savedStateService: any MacVirtualMachineSavedStateInspecting
  private let microphoneAuthorization: any MacVirtualMachineMicrophoneAuthorizing

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineAudioConfigurationPersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting,
    microphoneAuthorization: any MacVirtualMachineMicrophoneAuthorizing =
      AppleMacVirtualMachineMicrophoneAuthorizationService()
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
    self.microphoneAuthorization = microphoneAuthorization
  }

  func snapshot(id: UUID) async throws -> MacVirtualMachineAudioSnapshot {
    async let configuration = persistence.macOSAudioConfiguration(id: id)
    async let authorization = microphoneAuthorization.status()
    return try await MacVirtualMachineAudioSnapshot(
      configuration: configuration,
      microphoneAuthorization: authorization
    )
  }

  func setMicrophoneEnabled(
    _ isEnabled: Bool,
    for machineID: UUID
  ) async throws -> MacVirtualMachineAudioSnapshot {
    let authorization = try await requireAuthorization(ifEnabling: isEnabled)
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    let configuration = try await persistence.setMacOSMicrophoneEnabled(
      isEnabled,
      for: lease
    )
    return MacVirtualMachineAudioSnapshot(
      configuration: configuration,
      microphoneAuthorization: authorization
    )
  }

  private func requireAuthorization(
    ifEnabling isEnabled: Bool
  ) async throws -> MacVirtualMachineMicrophoneAuthorizationStatus {
    var status = await microphoneAuthorization.status()
    if isEnabled, status == .notDetermined {
      status = await microphoneAuthorization.requestAccess()
    }
    guard isEnabled else { return status }

    switch status {
    case .authorized:
      return status
    case .denied, .notDetermined:
      throw MacVirtualMachineAudioError.microphoneAccessDenied
    case .restricted:
      throw MacVirtualMachineAudioError.microphoneAccessRestricted
    }
  }

  private func requireNoSavedState(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    let status = try await savedStateService.inspect(for: lease)
    guard status == .none else {
      throw MacVirtualMachineAudioError.savedStateBlocksChanges(
        lease.target.machineID
      )
    }
  }
}
