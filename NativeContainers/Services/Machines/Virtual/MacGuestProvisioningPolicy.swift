import Foundation

struct MacGuestProvisioningPolicy: Sendable {
  let hostSupportsProvisioning: Bool

  init(hostSupportsProvisioning: Bool = Self.currentHostSupportsProvisioning) {
    self.hostSupportsProvisioning = hostSupportsProvisioning
  }

  func isEligible(manifest: VirtualMachineManifest) -> Bool {
    (try? validate(manifest: manifest, resumesSavedState: false)) != nil
  }

  func validate(
    manifest: VirtualMachineManifest,
    resumesSavedState: Bool
  ) throws {
    guard hostSupportsProvisioning else {
      throw MacGuestProvisioningError.hostUnsupported
    }
    guard let operatingSystem = manifest.macOSGuestOperatingSystem else {
      throw MacGuestProvisioningError.guestVersionUnknown
    }
    guard operatingSystem.supportsGuestProvisioning else {
      throw MacGuestProvisioningError.guestUnsupported(
        operatingSystem.versionDescription
      )
    }
    guard manifest.macOSFirstBootState == .pending else {
      throw MacGuestProvisioningError.firstBootUnavailable
    }
    guard !resumesSavedState else {
      throw MacGuestProvisioningError.savedStateConflict
    }
  }

  private static var currentHostSupportsProvisioning: Bool {
    if #available(macOS 27.0, *) {
      true
    } else {
      false
    }
  }
}
