import Foundation

struct VirtualMachineBundleValidator {
  private struct PlatformIdentity {
    let guest: VirtualMachineGuest
    let machineIdentifier: Data
    let macAddress: String?
  }

  private let bundleStore: VirtualMachineBundleStore
  private let fileManager: FileManager
  private let resolver: any MacVirtualMachineBundleResolving
  private let machineIdentifierValidator: any MacVirtualMachineIdentifierValidating
  private let linuxIdentityValidator: any LinuxVirtualMachineIdentityValidating
  private let artifactResolver: VirtualMachineBundleArtifactResolver
  private let sharedDirectoryStore: any VirtualMachineSharedDirectoryConfigurationStoring
  private let sharedDirectoryNameValidator: any VirtualMachineSharedDirectoryNameValidating

  init(
    bundleStore: VirtualMachineBundleStore,
    fileManager: FileManager,
    resolver: any MacVirtualMachineBundleResolving,
    machineIdentifierValidator: any MacVirtualMachineIdentifierValidating,
    linuxIdentityValidator: any LinuxVirtualMachineIdentityValidating =
      AppleLinuxVirtualMachineIdentityGenerator(),
    sharedDirectoryStore: any VirtualMachineSharedDirectoryConfigurationStoring,
    sharedDirectoryNameValidator: any VirtualMachineSharedDirectoryNameValidating
  ) {
    self.bundleStore = bundleStore
    self.fileManager = fileManager
    self.resolver = resolver
    self.machineIdentifierValidator = machineIdentifierValidator
    self.linuxIdentityValidator = linuxIdentityValidator
    self.artifactResolver = VirtualMachineBundleArtifactResolver(fileManager: fileManager)
    self.sharedDirectoryStore = sharedDirectoryStore
    self.sharedDirectoryNameValidator = sharedDirectoryNameValidator
  }

  func validateCloneBundle(_ transaction: VirtualMachineCloneTransaction) throws {
    do {
      let cloneIdentity = try validateStagedBundle(
        manifest: transaction.clone,
        bundleURL: transaction.stagingBundleURL,
        allowsSharedDirectories: true
      )
      let sourceIdentity = try platformIdentity(
        manifest: transaction.source,
        bundleURL: transaction.sourceBundleURL,
        requiresValidIdentity: false
      )
      guard cloneIdentity.machineIdentifier != sourceIdentity.machineIdentifier,
        try !machineIdentifierExists(cloneIdentity)
      else {
        throw VirtualMachineBundleError.duplicateMachineIdentifier
      }
      if let cloneMACAddress = cloneIdentity.macAddress {
        guard
          cloneMACAddress.caseInsensitiveCompare(sourceIdentity.macAddress ?? "")
            != .orderedSame,
          try !linuxMACAddressExists(cloneMACAddress)
        else {
          throw VirtualMachineBundleError.duplicateMACAddress
        }
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
      let identity = try validateStagedBundle(
        manifest: transaction.imported,
        bundleURL: transaction.stagingBundleURL,
        allowsSharedDirectories: false
      )
      let hasMACAddressCollision =
        if let macAddress = identity.macAddress {
          try linuxMACAddressExists(macAddress)
        } else {
          false
        }
      guard try !machineIdentifierExists(identity), !hasMACAddressCollision else {
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
  ) throws -> VirtualMachineSharedDirectoryConfiguration {
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
  ) throws -> PlatformIdentity {
    try bundleStore.requireDirectory(bundleURL)
    let manifest = try bundleStore.readManifest(in: bundleURL)
    guard manifest == expectedManifest,
      manifest.installState == .stopped,
      manifest.installationOperationID == nil,
      manifest.installationFailure == nil
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "the staged manifest does not match the transfer transaction"
      )
    }

    _ = try artifactResolver.resolve(
      manifest.diskImagePath,
      named: "diskImagePath",
      in: bundleURL,
      writable: true
    )
    let identity = try platformIdentity(manifest: manifest, bundleURL: bundleURL)
    try validateStagedPlatformArtifacts(
      manifest: manifest,
      bundleURL: bundleURL,
      isPortable: !allowsSharedDirectories
    )

    if allowsSharedDirectories {
      _ = try sharedDirectoryConfiguration(in: bundleURL)
    } else {
      let sharedDirectoriesURL = bundleURL.appending(
        path: FileVirtualMachineSharedDirectoryConfigurationStore.filename
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
    return identity
  }

  private func validateStagedPlatformArtifacts(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    isPortable: Bool
  ) throws {
    try VirtualMachineComputeState.validatePersistedRequirements(in: manifest)

    switch manifest.guest {
    case .macOS:
      try validateDiskSnapshotArtifacts(
        manifest.effectiveMacOSDiskSnapshotConfiguration,
        in: bundleURL
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
        _ = try artifactResolver.resolve(
          path,
          named: name,
          in: bundleURL,
          writable: writable
        )
      }
    case .linux:
      guard let configuration = manifest.linuxConfiguration,
        configuration.installationMediaPath == nil,
        manifest.auxiliaryStoragePath == nil,
        manifest.hardwareModelPath == nil,
        manifest.machineIdentifierPath == nil,
        manifest.restoreImageURL == nil,
        manifest.audioConfiguration == nil,
        !isPortable || manifest.networkConfiguration == nil,
        manifest.macOSGuestOperatingSystem == nil,
        manifest.macOSMinimumCPUCount == nil,
        manifest.macOSMinimumMemoryBytes == nil,
        manifest.macOSFirstBootState == nil,
        !manifest.effectiveMacOSDiskSnapshotConfiguration.hasSnapshots
      else {
        throw VirtualMachineBundleError.invalidBundle(
          "the staged Linux manifest contains incomplete or guest-incompatible state"
        )
      }
      _ = try artifactResolver.resolve(
        configuration.efiVariableStorePath,
        named: "efiVariableStorePath",
        in: bundleURL,
        writable: true
      )
      let snapshotDirectory = bundleURL.appending(
        path: MacVirtualMachineDiskSnapshotLayer.directoryName,
        directoryHint: .isDirectory
      )
      guard !fileManager.fileExists(atPath: snapshotDirectory.path) else {
        throw VirtualMachineBundleError.invalidBundle(
          "macOS disk snapshot data remains in the staged Linux bundle"
        )
      }
    }
  }

  private func platformIdentity(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    requiresValidIdentity: Bool = true
  ) throws -> PlatformIdentity {
    let path: String
    let macAddress: String?
    switch manifest.guest {
    case .macOS:
      guard let machineIdentifierPath = manifest.machineIdentifierPath else {
        throw VirtualMachineBundleError.invalidBundle(
          "the manifest has no machine identifier path"
        )
      }
      path = machineIdentifierPath
      macAddress = nil
    case .linux:
      guard let configuration = manifest.linuxConfiguration else {
        throw VirtualMachineBundleError.invalidBundle(
          "the manifest has no Linux platform configuration"
        )
      }
      path = configuration.machineIdentifierPath
      macAddress = configuration.macAddress
    }

    let identifierURL = try artifactResolver.resolve(
      path,
      named: "machineIdentifierPath",
      in: bundleURL,
      writable: false
    )
    let identifierData = try Data(contentsOf: identifierURL)
    if requiresValidIdentity {
      switch manifest.guest {
      case .macOS:
        guard machineIdentifierValidator.isValidIdentifierData(identifierData) else {
          throw VirtualMachineBundleError.invalidMachineIdentifier
        }
      case .linux:
        guard linuxIdentityValidator.isValidIdentifierData(identifierData) else {
          throw VirtualMachineBundleError.invalidMachineIdentifier
        }
        guard let macAddress,
          linuxIdentityValidator.isValidMACAddress(macAddress)
        else {
          throw VirtualMachineBundleError.invalidMACAddress
        }
      }
    }
    return PlatformIdentity(
      guest: manifest.guest,
      machineIdentifier: identifierData,
      macAddress: macAddress
    )
  }

  private func validateDiskSnapshotArtifacts(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration,
    in bundleURL: URL
  ) throws {
    let directoryURL = bundleURL.appending(
      path: MacVirtualMachineDiskSnapshotLayer.directoryName,
      directoryHint: .isDirectory
    )
    guard configuration.hasSnapshots else {
      guard !fileManager.fileExists(atPath: directoryURL.path) else {
        throw VirtualMachineBundleError.invalidBundle(
          "unreferenced disk snapshot data remains in the staged bundle"
        )
      }
      return
    }

    for (index, layer) in configuration.layers.enumerated() {
      _ = try resolver.resolveArtifact(
        layer.relativePath,
        named: "macOSDiskSnapshotConfiguration.layers[\(index)]",
        in: bundleURL,
        writable: index == configuration.layers.indices.last
      )
    }
    let entries = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    let expectedNames = Set(
      configuration.layers.map {
        URL(filePath: $0.relativePath).lastPathComponent
      }
    )
    guard Set(entries.map(\.lastPathComponent)) == expectedNames else {
      throw VirtualMachineBundleError.invalidBundle(
        "unreferenced disk snapshot data remains in the staged bundle"
      )
    }
  }

  private func machineIdentifierExists(_ candidate: PlatformIdentity) throws -> Bool {
    for manifest in try bundleStore.list() {
      guard manifest.guest == candidate.guest,
        hasPersistedPlatformIdentity(manifest)
      else {
        continue
      }
      let existing = try platformIdentity(
        manifest: manifest,
        bundleURL: bundleStore.bundleURL(for: manifest.id),
        requiresValidIdentity: false
      )
      if existing.machineIdentifier == candidate.machineIdentifier {
        return true
      }
    }
    return false
  }

  private func linuxMACAddressExists(_ candidate: String) throws -> Bool {
    try bundleStore.list().contains {
      guard $0.guest == .linux,
        let existing = $0.linuxConfiguration?.macAddress
      else {
        return false
      }
      return existing.caseInsensitiveCompare(candidate) == .orderedSame
    }
  }

  private func hasPersistedPlatformIdentity(_ manifest: VirtualMachineManifest) -> Bool {
    switch manifest.guest {
    case .macOS:
      manifest.machineIdentifierPath != nil
    case .linux:
      manifest.linuxConfiguration != nil
    }
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
