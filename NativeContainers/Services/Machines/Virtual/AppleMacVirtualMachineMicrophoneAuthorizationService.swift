@preconcurrency import AVFoundation

protocol MacVirtualMachineMicrophoneAuthorizing: Sendable {
  func status() async -> MacVirtualMachineMicrophoneAuthorizationStatus
  func requestAccess() async -> MacVirtualMachineMicrophoneAuthorizationStatus
}

struct AppleMacVirtualMachineMicrophoneAuthorizationService:
  MacVirtualMachineMicrophoneAuthorizing
{
  func status() async -> MacVirtualMachineMicrophoneAuthorizationStatus {
    Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
  }

  func requestAccess() async -> MacVirtualMachineMicrophoneAuthorizationStatus {
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
    guard granted else { return await status() }
    return .authorized
  }

  private static func map(
    _ status: AVAuthorizationStatus
  ) -> MacVirtualMachineMicrophoneAuthorizationStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorized:
      .authorized
    @unknown default:
      .restricted
    }
  }
}
