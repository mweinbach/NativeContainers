import Foundation

struct MacVirtualMachineAudioConfiguration: Codable, Equatable, Sendable {
  static let disconnected = MacVirtualMachineAudioConfiguration()

  let revision: UInt64
  let isMicrophoneEnabled: Bool

  init(
    revision: UInt64 = 0,
    isMicrophoneEnabled: Bool = false
  ) {
    self.revision = revision
    self.isMicrophoneEnabled = isMicrophoneEnabled
  }

  func settingMicrophoneEnabled(
    _ isEnabled: Bool
  ) throws -> MacVirtualMachineAudioConfiguration {
    guard isEnabled != isMicrophoneEnabled else { return self }
    guard revision < UInt64.max else {
      throw MacVirtualMachineAudioError.configurationRevisionOverflow
    }
    return MacVirtualMachineAudioConfiguration(
      revision: revision + 1,
      isMicrophoneEnabled: isEnabled
    )
  }
}

enum MacVirtualMachineMicrophoneAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case denied
  case restricted
  case authorized
}

struct MacVirtualMachineAudioSnapshot: Equatable, Sendable {
  let configuration: MacVirtualMachineAudioConfiguration
  let microphoneAuthorization: MacVirtualMachineMicrophoneAuthorizationStatus
}

enum MacVirtualMachineAudioError: LocalizedError, Equatable, Sendable {
  case unavailable
  case configurationRevisionOverflow
  case savedStateBlocksChanges(UUID)
  case microphoneAccessDenied
  case microphoneAccessRestricted

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Audio configuration is unavailable on this host."
    case .configurationRevisionOverflow:
      "The audio configuration changed too many times to update safely."
    case .savedStateBlocksChanges(let identifier):
      "Discard the saved state for virtual machine \(identifier.uuidString) before changing audio devices."
    case .microphoneAccessDenied:
      "Microphone access is denied. Grant NativeContainers access in System Settings, then try again."
    case .microphoneAccessRestricted:
      "Microphone access is restricted by this Mac and cannot be enabled for the guest."
    }
  }
}
