import Foundation

struct VirtualMachineBundleValidator {
  private let bundleStore: VirtualMachineBundleStore
  private let fileManager: FileManager
  private let resolver: any MacVirtualMachineBundleResolving
  private let machineIdentifierValidator: any MacVirtualMachineIdentifierValidating
  private let sharedDirectoryStore: any MacVirtualMachineSharedDirectoryConfigurationStoring
  private let sharedDirectoryNameValidator: any MacVirtualMachineSharedDirectoryNameValidating

  init(
    bundleStore: VirtualMachineBundleStore,
    fileManager: FileManager,
    resolver: any MacVirtualMachineBundleResolving,
    machineIdentifierValidator: any MacVirtualMachineIdentifierValidating,
    sharedDirectoryStore: any MacVirtualMachineSharedDirectoryConfigurationStoring,
    sharedDirectoryNameValidator: any MacVirtualMachineSharedDirectoryNameValidating
  ) {
    self.bundleStore = bundleStore
    self.fileManager = fileManager
    self.resolver = resolver
    self.machineIdentifierValidator = machineIdentifierValidator
    self.sharedDirectoryStore = sharedDirectoryStore
    self.sharedDirectoryNameValidator = sharedDirectoryNameValidator
  }

  func validateCloneBundle(_ transaction: VirtualMachineCloneTransaction) throws {
    do {
      let cloneIdentifierData = try validateStagedBundle(
        manifest: transaction.clone,
        bundleURL: transaction.stagingBundleURL,
        allowsSharedDirectories: true
      )
      guard let sourceIdentifierPath = transaction.source.machineIdentifierPath else {
        throw VirtualMachineBundleError.invalidBundle(
          "the source manifest has no machine identifier path"
        )
      }
      let sourceIdentifierURL = try resolver.resolveArtifact(
        sourceIdentifierPath,
        named: "sourceMachineIdentifierPath",
        in: transaction.sourceBundleURL,
        writable: false
      )
      let sourceIdentifierData = try Data(contentsOf: sourceIdentifierURL)
      guard cloneIdentifierData != sourceIdentifierData,
        try !machineIdentifierExists(cloneIdentifierData)
      else {
        throw VirtualMachineBundleError.duplicateMachineIdentifier
      }
    } catch let error as VirtualMachineCloneError {
      throw error
    } catch {
      throw VirtualMachineCloneError.invalidBundle(error.localizedDescription)
    }
  }

  func validateImportedBundle(
    _ transaction: VirtualMachineImportTransaction
  ) throws {
    do {
      let identifierData = try validateStagedBundle(
        manifest: transaction.imported,
        bundleURL: transaction.stagingBundleURL,
        allowsSharedDirectories: false
      )
      guard try !machineIdentifierExists(identifierData) else {
        throw VirtualMachineTransferError.platformIdentityCollision
      }
    } catch let error as VirtualMachineTransferError {
      throw error
    } catch {
      throw VirtualMachineTransferError.invalidPackage(error.localizedDescription)
    }
  }

  func sharedDirectoryConfiguration(
    in bundleURL: URL
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let configuration = try sharedDirectoryStore.load(from: bundleURL)
    for directory in configuration.directories {
      try sharedDirectoryNameValidator.validatePersistedName(
        directory.guestName
      )
    }
    return configuration
  }

  private func validateStagedBundle(
    manifest expectedManifest: VirtualMachineManifest,
    bundleURL: URL,
    allowsSharedDirectories: Bool
  ) throws -> Data {
    try bundleStore.requireDirectory(bundleURL)
    let manifest = try bundleStore.readManifest(in: bundleURL)
    guard manifest == expectedManifest,
      manifest.guest == .macOS,
      manifest.installState == .stopped,
      manifest.installationOperationID == nil,
      manifest.installationFailure == nil
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "the staged manifest does not match the transfer transaction"
      )
    }

    _ = try resolver.resolveArtifact(
      manifest.diskImagePath,
      named: "diskImagePath",
      in: bundleURL,
      writable: true
    )
    for (path, name, writable) in [
      (manifest.auxiliaryStoragePath, "auxiliaryStoragePath", true),
      (manifest.hardwareModelPath, "hardwareModelPath", false),
      (manifest.machineIdentifierPath, "machineIdentifierPath", false),
    ] {
      guard let path else {
        throw VirtualMachineBundleError.invalidBundle(
          "the staged manifest is missing \(name)"
        )
      }
      _ = try resolver.resolveArtifact(
        path,
        named: name,
        in: bundleURL,
        writable: writable
      )
    }
    guard let machineIdentifierPath = manifest.machineIdentifierPath else {
      throw VirtualMachineBundleError.invalidBundle(
        "the staged manifest has no machine identifier path"
      )
    }
    let identifierURL = try resolver.resolveArtifact(
      machineIdentifierPath,
      named: "machineIdentifierPath",
      in: bundleURL,
      writable: false
    )
    let identifierData = try Data(contentsOf: identifierURL)
    guard machineIdentifierValidator.isValidIdentifierData(identifierData) else {
      throw VirtualMachineBundleError.invalidMachineIdentifier
    }

    if allowsSharedDirectories {
      _ = try sharedDirectoryConfiguration(in: bundleURL)
    } else {
      let sharedDirectoriesURL = bundleURL.appending(
        path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
      )
      guard !fileManager.fileExists(atPath: sharedDirectoriesURL.path) else {
        throw VirtualMachineBundleError.invalidBundle(
          "host shared-folder capabilities remain in the portable package"
        )
      }
    }

    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    guard !entries.contains(where: { isTransientBundleEntry($0.lastPathComponent) }) else {
      throw VirtualMachineBundleError.invalidBundle(
        "runtime, installation, or saved-state transaction data remains in the staged bundle"
      )
    }
    return identifierData
  }

  private func machineIdentifierExists(_ candidate: Data) throws -> Bool {
    for manifest in try bundleStore.list() {
      guard let path = manifest.machineIdentifierPath else { continue }
      let identifierURL = try resolver.resolveArtifact(
        path,
        named: "machineIdentifierPath",
        in: bundleStore.bundleURL(for: manifest.id),
        writable: false
      )
      if try Data(contentsOf: identifierURL) == candidate {
        return true
      }
    }
    return false
  }

  private func isTransientBundleEntry(_ name: String) -> Bool {
    name == VirtualMachineLibrary.runtimeLockFilename
      || name == VirtualMachineLibrary.runtimeOwnerFilename
      || name == MacVirtualMachineSavedStateStore.directoryName
      || name == VirtualMachineDiskImageReplacementArtifacts.journalFilename
      || name.hasPrefix(VirtualMachineLibrary.installationStagingPrefix)
      || name.hasPrefix(MacVirtualMachineSavedStateStore.stagingPrefix)
  }
}
