import Foundation
@preconcurrency import Virtualization

struct MacPlatformArtifactURLs: Sendable {
  static let directoryName = "MacPlatform"
  static let auxiliaryStorageFilename = "AuxiliaryStorage"
  static let hardwareModelFilename = "HardwareModel.bin"
  static let machineIdentifierFilename = "MachineIdentifier.bin"

  let directory: URL

  var auxiliaryStorage: URL {
    directory.appending(path: Self.auxiliaryStorageFilename)
  }

  var hardwareModel: URL {
    directory.appending(path: Self.hardwareModelFilename)
  }

  var machineIdentifier: URL {
    directory.appending(path: Self.machineIdentifierFilename)
  }

  var all: [URL] {
    [auxiliaryStorage, hardwareModel, machineIdentifier]
  }

  static var auxiliaryStorageManifestPath: String {
    "\(directoryName)/\(auxiliaryStorageFilename)"
  }

  static var hardwareModelManifestPath: String {
    "\(directoryName)/\(hardwareModelFilename)"
  }

  static var machineIdentifierManifestPath: String {
    "\(directoryName)/\(machineIdentifierFilename)"
  }
}

protocol MacPlatformArtifactPreparing: Sendable {
  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws -> MacPlatformPreparationResult
}

struct MacPlatformArtifactPreparer: MacPlatformArtifactPreparing {
  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws -> MacPlatformPreparationResult {
    #if arch(arm64)
      let restoreImage = try await VZMacOSRestoreImage.image(from: restoreImageURL)
      guard restoreImage.isSupported else {
        throw MacPlatformArtifactError.unsupportedRestoreImage
      }
      guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
        throw MacPlatformArtifactError.noSupportedConfiguration
      }
      guard resources.cpuCount >= requirements.minimumSupportedCPUCount else {
        throw MacPlatformArtifactError.insufficientCPUCount(
          requested: resources.cpuCount,
          minimum: requirements.minimumSupportedCPUCount
        )
      }
      guard resources.memoryBytes >= requirements.minimumSupportedMemorySize else {
        throw MacPlatformArtifactError.insufficientMemory(
          requested: resources.memoryBytes,
          minimum: requirements.minimumSupportedMemorySize
        )
      }

      let hardwareModel = requirements.hardwareModel
      let machineIdentifier = VZMacMachineIdentifier()

      try hardwareModel.dataRepresentation.write(
        to: destination.hardwareModel,
        options: [.atomic]
      )
      try machineIdentifier.dataRepresentation.write(
        to: destination.machineIdentifier,
        options: [.atomic]
      )
      _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: destination.auxiliaryStorage,
        hardwareModel: hardwareModel,
        options: []
      )
      return MacPlatformPreparationResult(
        operatingSystem: MacGuestOperatingSystemIdentity(
          buildVersion: restoreImage.buildVersion,
          operatingSystemVersion: restoreImage.operatingSystemVersion
        )
      )
    #else
      throw MacPlatformArtifactError.requiresAppleSilicon
    #endif
  }
}

enum MacPlatformArtifactError: LocalizedError, Equatable {
  case unsupportedRestoreImage
  case noSupportedConfiguration
  case insufficientCPUCount(requested: Int, minimum: Int)
  case insufficientMemory(requested: UInt64, minimum: UInt64)
  case missingArtifact(String)
  case requiresAppleSilicon

  var errorDescription: String? {
    switch self {
    case .unsupportedRestoreImage:
      "This Mac does not support the selected macOS restore image."
    case .noSupportedConfiguration:
      "The selected macOS restore image has no configuration supported by this Mac."
    case .insufficientCPUCount(let requested, let minimum):
      "The restore image requires at least \(minimum) CPUs; this virtual machine requests \(requested)."
    case .insufficientMemory(let requested, let minimum):
      "The restore image requires at least \(minimum) bytes of memory; this virtual machine requests \(requested)."
    case .missingArtifact(let filename):
      "Platform preparation did not create \(filename)."
    case .requiresAppleSilicon:
      "macOS virtual machines require a Mac with Apple silicon."
    }
  }
}
