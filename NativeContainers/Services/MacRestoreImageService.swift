import Foundation
@preconcurrency import Virtualization

protocol MacRestoreImageDiscovering: Sendable {
  func latestSupported() async throws -> MacRestoreImageInfo
}

struct MacRestoreImageService: MacRestoreImageDiscovering {
  func latestSupported() async throws -> MacRestoreImageInfo {
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
  }
}

enum MacRestoreImageError: LocalizedError {
  case noSupportedConfiguration

  var errorDescription: String? {
    "The latest macOS restore image has no configuration supported by this Mac."
  }
}
