import Foundation
@preconcurrency import Virtualization

protocol MacRestoreImageDiscovering: Sendable {
  func latestSupported() async throws -> MacRestoreImageInfo
}

struct MacRestoreImageService: MacRestoreImageDiscovering {
  func latestSupported() async throws -> MacRestoreImageInfo {
    #if arch(arm64)
      let image = try await VZMacOSRestoreImage.latestSupported
      guard let requirements = image.mostFeaturefulSupportedConfiguration else {
        throw MacRestoreImageError.noSupportedConfiguration
      }

      return MacRestoreImageInfo(
        url: image.url,
        buildVersion: image.buildVersion,
        majorVersion: image.operatingSystemVersion.majorVersion,
        minorVersion: image.operatingSystemVersion.minorVersion,
        patchVersion: image.operatingSystemVersion.patchVersion,
        minimumCPUCount: requirements.minimumSupportedCPUCount,
        minimumMemoryBytes: requirements.minimumSupportedMemorySize,
        isSupported: image.isSupported
      )
    #else
      throw MacRestoreImageError.requiresAppleSilicon
    #endif
  }
}

enum MacRestoreImageError: LocalizedError {
  case noSupportedConfiguration
  case requiresAppleSilicon

  var errorDescription: String? {
    switch self {
    case .noSupportedConfiguration:
      "The latest macOS restore image has no configuration supported by this Mac."
    case .requiresAppleSilicon:
      "macOS virtual machines require a Mac with Apple silicon."
    }
  }
}
