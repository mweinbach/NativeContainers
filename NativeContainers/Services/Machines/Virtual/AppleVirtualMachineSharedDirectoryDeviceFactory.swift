import Foundation
@preconcurrency import Virtualization

struct AppleVirtualMachineSharedDirectoryNameValidator:
  VirtualMachineSharedDirectoryNameValidating
{
  func canonicalName(from proposedName: String) throws -> String {
    let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let canonicalName = VZMultipleDirectoryShare.canonicalizedName(from: trimmed)
    else {
      throw VirtualMachineSharedDirectoryError.invalidName(
        proposedName,
        "Choose a name that the guest can use for a shared folder."
      )
    }
    do {
      try VZMultipleDirectoryShare.validateName(canonicalName)
    } catch {
      throw VirtualMachineSharedDirectoryError.invalidName(
        proposedName,
        error.localizedDescription
      )
    }
    return canonicalName
  }

  func validatePersistedName(_ name: String) throws {
    do {
      try VZMultipleDirectoryShare.validateName(name)
    } catch {
      throw VirtualMachineSharedDirectoryError.invalidName(
        name,
        error.localizedDescription
      )
    }
  }
}

@MainActor
struct AppleVirtualMachineSharedDirectoryDeviceFactory {
  func makeDevice(
    for directories: [ResolvedVirtualMachineSharedDirectory],
    tag: String
  ) throws -> VZVirtioFileSystemDeviceConfiguration? {
    guard !directories.isEmpty else { return nil }

    try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
    var normalizedNames = Set<String>()
    var shares: [String: VZSharedDirectory] = [:]
    for directory in directories {
      do {
        try VZMultipleDirectoryShare.validateName(directory.guestName)
      } catch {
        throw VirtualMachineSharedDirectoryError.invalidName(
          directory.guestName,
          error.localizedDescription
        )
      }
      let normalizedName = VirtualMachineSharedDirectoryNameNormalizer.normalized(
        directory.guestName
      )
      guard normalizedNames.insert(normalizedName).inserted else {
        throw VirtualMachineSharedDirectoryError.duplicateName(
          directory.guestName
        )
      }
      shares[directory.guestName] = VZSharedDirectory(
        url: directory.sourceURL,
        readOnly: directory.readOnly
      )
    }

    let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
    device.share = VZMultipleDirectoryShare(directories: shares)
    return device
  }
}

@MainActor
struct AppleMacVirtualMachineSharedDirectoryDeviceFactory {
  private let factory = AppleVirtualMachineSharedDirectoryDeviceFactory()

  func makeDevice(
    for directories: [ResolvedMacVirtualMachineSharedDirectory]
  ) throws -> VZVirtioFileSystemDeviceConfiguration? {
    try factory.makeDevice(
      for: directories,
      tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
    )
  }
}

@MainActor
struct AppleLinuxVirtualMachineSharedDirectoryDeviceFactory {
  static let mountTag = "nativecontainers"

  private let factory = AppleVirtualMachineSharedDirectoryDeviceFactory()

  func makeDevice(
    for directories: [ResolvedLinuxVirtualMachineSharedDirectory]
  ) throws -> VZVirtioFileSystemDeviceConfiguration? {
    try factory.makeDevice(for: directories, tag: Self.mountTag)
  }
}

typealias AppleMacVirtualMachineSharedDirectoryNameValidator =
  AppleVirtualMachineSharedDirectoryNameValidator
typealias AppleLinuxVirtualMachineSharedDirectoryNameValidator =
  AppleVirtualMachineSharedDirectoryNameValidator
