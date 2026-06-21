import Foundation
@preconcurrency import Virtualization

struct AppleMacVirtualMachineSharedDirectoryNameValidator:
  MacVirtualMachineSharedDirectoryNameValidating
{
  func canonicalName(from proposedName: String) throws -> String {
    let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let canonicalName = VZMultipleDirectoryShare.canonicalizedName(from: trimmed)
    else {
      throw MacVirtualMachineSharedDirectoryError.invalidName(
        proposedName,
        "Choose a name that macOS can use as a shared-folder volume."
      )
    }
    do {
      try VZMultipleDirectoryShare.validateName(canonicalName)
    } catch {
      throw MacVirtualMachineSharedDirectoryError.invalidName(
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
      throw MacVirtualMachineSharedDirectoryError.invalidName(
        name,
        error.localizedDescription
      )
    }
  }
}

#if arch(arm64)
  @MainActor
  struct AppleMacVirtualMachineSharedDirectoryDeviceFactory {
    func makeDevice(
      for directories: [ResolvedMacVirtualMachineSharedDirectory]
    ) throws -> VZVirtioFileSystemDeviceConfiguration? {
      guard !directories.isEmpty else { return nil }

      let tag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
      try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)

      var normalizedNames = Set<String>()
      var shares: [String: VZSharedDirectory] = [:]
      for directory in directories {
        do {
          try VZMultipleDirectoryShare.validateName(directory.guestName)
        } catch {
          throw MacVirtualMachineSharedDirectoryError.invalidName(
            directory.guestName,
            error.localizedDescription
          )
        }
        let normalizedName = MacVirtualMachineSharedDirectoryNameNormalizer.normalized(
          directory.guestName
        )
        guard normalizedNames.insert(normalizedName).inserted else {
          throw MacVirtualMachineSharedDirectoryError.duplicateName(
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
#endif
