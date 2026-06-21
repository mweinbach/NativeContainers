import Foundation

protocol VirtualMachineInventoryLoading: Sendable {
  func list() async throws -> [VirtualMachineManifest]
}

protocol VirtualMachineDraftCreating: Sendable {
  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest
}

protocol MacVirtualMachinePreparing: Sendable {
  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest
}

protocol LinuxVirtualMachinePreparing: Sendable {
  func prepareLinuxVM(
    id: UUID,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest
}

protocol VirtualMachineDiscarding: Sendable {
  func discardVirtualMachine(id: UUID) async throws
}

protocol VirtualMachineLibraryProtocol:
  VirtualMachineInventoryLoading,
  VirtualMachineDraftCreating,
  MacVirtualMachinePreparing,
  LinuxVirtualMachinePreparing,
  VirtualMachineDiscarding
{}

extension MacVirtualMachinePreparing {
  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    throw VirtualMachineModelError.macPlatformPreparationUnavailable
  }
}

extension LinuxVirtualMachinePreparing {
  func prepareLinuxVM(
    id: UUID,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest {
    throw VirtualMachineModelError.linuxPlatformPreparationUnavailable
  }
}

extension VirtualMachineDiscarding {
  func discardVirtualMachine(id: UUID) async throws {
    throw VirtualMachineModelError.virtualMachineDiscardUnavailable
  }
}

protocol MacVirtualMachineInstallationStoring: Sendable {
  func stageMacOSInstallation(
    id: UUID,
    operationID: UUID
  ) async throws -> PreparedMacVirtualMachine
  func discardStagedMacOSInstallation(id: UUID, operationID: UUID) async throws
  func beginMacOSInstallation(id: UUID, operationID: UUID) async throws
  func completeMacOSInstallation(id: UUID, operationID: UUID) async throws
  func abortMacOSInstallation(
    id: UUID,
    operationID: UUID,
    kind: VirtualMachineInstallationFailureKind,
    message: String
  ) async throws
  func recoverInterruptedMacOSInstallations() async throws -> MacVirtualMachineRecoveryOutcome
}

actor VirtualMachineLibrary:
  VirtualMachineLibraryProtocol,
  VirtualMachineCloneStoring,
  VirtualMachineExportSourceLeasing,
  VirtualMachineImportStoring,
  VirtualMachineStorageInventoryLoading,
  VirtualMachineRestoreImageReferenceStoring,
  MacVirtualMachineInstallationStoring,
  MacVirtualMachineRuntimeLeasing,
  LinuxVirtualMachineRuntimeLeasing,
  LinuxVirtualMachineInstallationCompleting,
  MacVirtualMachineSharedDirectoryPersisting,
  LinuxVirtualMachineSharedDirectoryPersisting,
  MacVirtualMachineAudioConfigurationPersisting,
  MacVirtualMachineNetworkConfigurationPersisting,
  VirtualMachineDiskImageReplacementStoring
{
  static let bundleExtension = "nativevm"
  static let manifestFilename = "manifest.json"
  static let installationStagingPrefix = ".Installation-"
  static let installationStagingSuffix = ".partial"
  static let installationInstalledDirectoryName = "Installed"
  static let installationDiskFilename = "Disk.img"
  static let installationAuxiliaryStorageFilename = "AuxiliaryStorage"
  static let operationLockFilename = ".operations.lock"
  static let runtimeLockFilename = ".runtime.lock"
  static let runtimeOwnerFilename = ".runtime-owner.json"
  static let deletionTombstonePrefix = ".Deletion-"
  static let deletionTombstoneSuffix = ".partial"
  static let cloneStagingPrefix = ".Clone-"
  static let cloneStagingSuffix = ".partial"
  static let importStagingPrefix = ".Import-"
  static let importStagingSuffix = ".partial"

  private struct ActiveClone {
    let transaction: VirtualMachineCloneTransaction
    let runtimeLock: AdvisoryFileLockLease
  }

  private struct ActiveImport {
    let transaction: VirtualMachineImportTransaction
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let bundleStore: VirtualMachineBundleStore
  private let bundleValidator: VirtualMachineBundleValidator
  private let launchID: UUID
  private let macPlatformArtifactPreparer: any MacPlatformArtifactPreparing
  private let linuxPlatformArtifactPreparer: any LinuxPlatformArtifactPreparing
  private let macVirtualMachineBundleResolver: any MacVirtualMachineBundleResolving
  private let linuxVirtualMachineBundleResolver: any LinuxVirtualMachineBundleResolving
  private let sharedDirectoryStore: any VirtualMachineSharedDirectoryConfigurationStoring
  private let sharedDirectoryNameValidator: any VirtualMachineSharedDirectoryNameValidating
  private var operationLockLease: AdvisoryFileLockLease?
  private var operationAccessTokens = Set<UUID>()
  private var installationOperationIDs = Set<UUID>()
  private var activeClones: [UUID: ActiveClone] = [:]
  private var activeImports: [UUID: ActiveImport] = [:]

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    launchID: UUID = UUID(),
    macPlatformArtifactPreparer: any MacPlatformArtifactPreparing = MacPlatformArtifactPreparer(),
    linuxPlatformArtifactPreparer: any LinuxPlatformArtifactPreparing =
      LinuxPlatformArtifactPreparer(),
    macMachineIdentifierValidator: any MacVirtualMachineIdentifierValidating =
      AppleMacVirtualMachineIdentifierGenerator(),
    sharedDirectoryStore: any VirtualMachineSharedDirectoryConfigurationStoring =
      FileVirtualMachineSharedDirectoryConfigurationStore(),
    sharedDirectoryNameValidator: any VirtualMachineSharedDirectoryNameValidating =
      AppleVirtualMachineSharedDirectoryNameValidator()
  ) {
    let resolvedRootURL =
      rootURL
      ?? VirtualMachineBundleStore.defaultRootURL(
        fileManager: fileManager
      )
    let bundleStore = VirtualMachineBundleStore(
      rootURL: resolvedRootURL,
      fileManager: fileManager
    )
    let bundleResolver = MacVirtualMachineBundleResolver(
      rootURL: resolvedRootURL,
      fileManager: fileManager
    )
    let linuxBundleResolver = LinuxVirtualMachineBundleResolver(
      rootURL: resolvedRootURL,
      fileManager: fileManager
    )
    self.fileManager = fileManager
    self.launchID = launchID
    self.rootURL = resolvedRootURL
    self.bundleStore = bundleStore
    self.macPlatformArtifactPreparer = macPlatformArtifactPreparer
    self.linuxPlatformArtifactPreparer = linuxPlatformArtifactPreparer
    self.macVirtualMachineBundleResolver = bundleResolver
    self.linuxVirtualMachineBundleResolver = linuxBundleResolver
    self.sharedDirectoryStore = sharedDirectoryStore
    self.sharedDirectoryNameValidator = sharedDirectoryNameValidator
    self.bundleValidator = VirtualMachineBundleValidator(
      bundleStore: bundleStore,
      fileManager: fileManager,
      resolver: bundleResolver,
      machineIdentifierValidator: macMachineIdentifierValidator,
      sharedDirectoryStore: sharedDirectoryStore,
      sharedDirectoryNameValidator: sharedDirectoryNameValidator
    )
  }

  func list() throws -> [VirtualMachineManifest] {
    try bundleStore.list()
  }

  func loadRestoreImageReferences() throws -> Set<URL> {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }
    return Set(
      try list().compactMap { $0.restoreImageURL?.standardizedFileURL }
    )
  }

  @discardableResult
  func migrateRestoreImageReferences(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> Int {
    let sourceURL = sourceURL.standardizedFileURL
    let destinationURL = destinationURL.standardizedFileURL
    guard sourceURL.isFileURL,
      destinationURL.isFileURL,
      sourceURL != destinationURL
    else {
      throw VirtualMachineModelError.invalidRestoreImageReference(sourceURL)
    }

    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let matchingManifests = try list().filter {
      $0.restoreImageURL?.standardizedFileURL.path == sourceURL.path
    }
    guard !matchingManifests.contains(where: { $0.installState == .draft }) else {
      throw VirtualMachineModelError.invalidRestoreImageReference(sourceURL)
    }

    var updateCount = 0
    for var manifest in matchingManifests {
      if manifest.installState == .stopped {
        manifest.restoreImageURL = nil
      } else {
        manifest.restoreImageURL = destinationURL
      }
      try bundleStore.write(manifest, to: bundleStore.manifestURL(for: manifest.id))
      updateCount += 1
    }
    return updateCount
  }

  func loadVirtualMachineStorageInventory() throws
    -> VirtualMachineStorageInventory
  {
    try bundleStore.ensureRootExists()
    return VirtualMachineStorageInventory(
      rootURL: rootURL,
      targets: try list().map {
        VirtualMachineStorageTarget(
          manifest: $0,
          bundleURL: bundleStore.bundleURL(for: $0.id)
        )
      }
    )
  }

  func macOSAudioConfiguration(
    id: UUID
  ) throws -> MacVirtualMachineAudioConfiguration {
    try installationManifest(id: id).effectiveAudioConfiguration
  }

  func setMacOSMicrophoneEnabled(
    _ isEnabled: Bool,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineAudioConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    var manifest = try installationManifest(id: lease.target.machineID)
    let current = manifest.effectiveAudioConfiguration

    guard current == lease.machine.manifest.effectiveAudioConfiguration else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }

    let updated = try current.settingMicrophoneEnabled(isEnabled)
    guard updated != current else { return current }

    manifest.audioConfiguration = updated
    manifest.updatedAt = Date()
    try bundleStore.write(
      manifest,
      to: bundleURL.appending(path: Self.manifestFilename)
    )
    return updated
  }

  func macOSNetworkConfiguration(
    id: UUID
  ) throws -> MacVirtualMachineNetworkConfiguration {
    try installationManifest(id: id).effectiveNetworkConfiguration
  }

  func setMacOSNetworkAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineNetworkConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    var manifest = try installationManifest(id: lease.target.machineID)
    let current = manifest.effectiveNetworkConfiguration

    guard current == lease.machine.manifest.effectiveNetworkConfiguration else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }

    let updated = try current.settingAttachment(attachment)
    guard updated != current else { return current }

    manifest.networkConfiguration = updated
    manifest.updatedAt = Date()
    try bundleStore.write(
      manifest,
      to: bundleURL.appending(path: Self.manifestFilename)
    )
    return updated
  }

  func macOSSharedDirectoryConfiguration(
    id: UUID
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let manifest = try installationManifest(id: id)
    return try sharedDirectoryConfiguration(for: manifest)
  }

  func linuxSharedDirectoryConfiguration(
    id: UUID
  ) throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    let manifest = try linuxRuntimeManifest(id: id)
    return try sharedDirectoryConfiguration(for: manifest)
  }

  func addMacOSSharedDirectory(
    _ directory: MacVirtualMachineSharedDirectory,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    let current = try bundleValidator.sharedDirectoryConfiguration(in: bundleURL)
    let updated = try addingSharedDirectory(directory, to: current)
    try sharedDirectoryStore.save(updated, to: bundleURL)
    return updated
  }

  func addLinuxSharedDirectory(
    _ directory: LinuxVirtualMachineSharedDirectory,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    let current = try bundleValidator.sharedDirectoryConfiguration(in: bundleURL)
    let updated = try addingSharedDirectory(directory, to: current)
    try sharedDirectoryStore.save(updated, to: bundleURL)
    return updated
  }

  func removeMacOSSharedDirectory(
    id: UUID,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    let current = try bundleValidator.sharedDirectoryConfiguration(in: bundleURL)
    let updated = try removingSharedDirectory(id: id, from: current)
    try sharedDirectoryStore.save(updated, to: bundleURL)
    return updated
  }

  func removeLinuxSharedDirectory(
    id: UUID,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    let current = try bundleValidator.sharedDirectoryConfiguration(in: bundleURL)
    let updated = try removingSharedDirectory(id: id, from: current)
    try sharedDirectoryStore.save(updated, to: bundleURL)
    return updated
  }

  private func sharedDirectoryConfiguration(
    for manifest: VirtualMachineManifest
  ) throws -> VirtualMachineSharedDirectoryConfiguration {
    let bundleURL = bundleStore.bundleURL(for: manifest.id)
    try bundleStore.requireDirectory(bundleURL)
    return try bundleValidator.sharedDirectoryConfiguration(in: bundleURL)
  }

  private func addingSharedDirectory(
    _ directory: VirtualMachineSharedDirectory,
    to current: VirtualMachineSharedDirectoryConfiguration
  ) throws -> VirtualMachineSharedDirectoryConfiguration {
    try sharedDirectoryNameValidator.validatePersistedName(directory.guestName)
    let normalizedName = VirtualMachineSharedDirectoryNameNormalizer.normalized(
      directory.guestName
    )
    guard
      !current.directories.contains(where: {
        VirtualMachineSharedDirectoryNameNormalizer.normalized($0.guestName)
          == normalizedName
      })
    else {
      throw VirtualMachineSharedDirectoryError.duplicateName(directory.guestName)
    }
    guard !current.directories.contains(where: { $0.id == directory.id }) else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the shared-folder identifier already exists"
      )
    }
    guard current.revision < UInt64.max else {
      throw VirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }

    return VirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories + [directory]
    )
  }

  private func removingSharedDirectory(
    id: UUID,
    from current: VirtualMachineSharedDirectoryConfiguration
  ) throws -> VirtualMachineSharedDirectoryConfiguration {
    guard current.directories.contains(where: { $0.id == id }) else {
      throw VirtualMachineSharedDirectoryError.sharedDirectoryNotFound(id)
    }
    guard current.revision < UInt64.max else {
      throw VirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }

    return VirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories.filter { $0.id != id }
    )
  }

  func commitDiskImageReplacement(
    _ commit: VirtualMachineDiskImageReplacementCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    var manifest = try installationManifest(id: lease.target.machineID)

    guard manifest.diskImagePath == commit.sourcePath,
      manifest.effectiveDiskImageFormat == commit.sourceFormat,
      lease.machine.manifest.diskImagePath == commit.sourcePath,
      lease.machine.manifest.effectiveDiskImageFormat == commit.sourceFormat,
      commit.sourcePath != commit.destinationPath
    else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }

    let sourceURL = try macVirtualMachineBundleResolver.resolveArtifact(
      commit.sourcePath,
      named: "diskImagePath",
      in: bundleURL,
      writable: true
    )
    let destinationURL = try macVirtualMachineBundleResolver.resolveArtifact(
      commit.destinationPath,
      named: "migrationDestinationPath",
      in: bundleURL,
      writable: true
    )
    guard sourceURL.standardizedFileURL == lease.machine.diskImageURL.standardizedFileURL else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }

    let artifactInspector = FileVirtualMachineStorageArtifactInspector()
    guard
      try artifactInspector.inspect(at: sourceURL)
        .refersToSameStableFile(as: commit.sourceIdentity),
      try artifactInspector.inspect(at: destinationURL)
        .refersToSameStableFile(as: commit.destinationIdentity)
    else {
      throw VirtualMachineDiskImageReplacementError.staleSource
    }

    manifest.markDiskImageReplaced(
      to: commit.destinationPath,
      format: commit.destinationFormat
    )
    try bundleStore.write(manifest, to: bundleStore.manifestURL(for: manifest.id))
    return manifest
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try VirtualMachineManifest(name: name, guest: guest, resources: resources)
    let finalURL = bundleStore.bundleURL(for: manifest.id)
    guard !fileManager.fileExists(atPath: finalURL.path) else {
      throw VirtualMachineModelError.duplicateIdentifier(manifest.id)
    }

    let stagingURL = rootURL.appending(
      path: ".\(manifest.id.uuidString).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )

    do {
      try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
      try bundleStore.createSparseDisk(
        at: stagingURL.appending(path: manifest.diskImagePath),
        size: resources.diskBytes
      )
      try bundleStore.write(
        manifest,
        to: stagingURL.appending(path: Self.manifestFilename)
      )
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      return manifest
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let bundleURL = bundleStore.bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }

    var manifest = try bundleStore.readManifest(in: bundleURL)
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(id)
    }
    guard manifest.installState == .draft else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }

    let finalArtifactDirectory = bundleURL.appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    let manifestContainsArtifacts =
      manifest.auxiliaryStoragePath != nil
      || manifest.hardwareModelPath != nil
      || manifest.machineIdentifierPath != nil
    guard !manifestContainsArtifacts,
      !fileManager.fileExists(atPath: finalArtifactDirectory.path)
    else {
      throw VirtualMachineModelError.platformArtifactsAlreadyExist(id)
    }

    let stagingDirectory = bundleURL.appending(
      path: ".\(MacPlatformArtifactURLs.directoryName).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let stagingArtifacts = MacPlatformArtifactURLs(directory: stagingDirectory)
    var promotedArtifacts = false

    do {
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false
      )
      try await macPlatformArtifactPreparer.prepare(
        restoreImageURL: restoreImageURL,
        resources: manifest.resources,
        destination: stagingArtifacts
      )
      try bundleStore.validatePreparedArtifacts(stagingArtifacts)

      try fileManager.moveItem(at: stagingDirectory, to: finalArtifactDirectory)
      promotedArtifacts = true

      manifest.markReadyToInstallMacOS(
        restoreImageURL: restoreImageURL,
        auxiliaryStoragePath: MacPlatformArtifactURLs.auxiliaryStorageManifestPath,
        hardwareModelPath: MacPlatformArtifactURLs.hardwareModelManifestPath,
        machineIdentifierPath: MacPlatformArtifactURLs.machineIdentifierManifestPath
      )
      try bundleStore.write(
        manifest,
        to: bundleURL.appending(path: Self.manifestFilename)
      )
      return manifest
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      if promotedArtifacts {
        try? fileManager.removeItem(at: finalArtifactDirectory)
      }
      throw error
    }
  }

  func prepareLinuxVM(
    id: UUID,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let bundleURL = bundleStore.bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }

    var manifest = try bundleStore.readManifest(in: bundleURL)
    guard manifest.guest == .linux else {
      throw VirtualMachineModelError.requiresLinuxGuest(id)
    }
    guard manifest.installState == .draft else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }

    let finalArtifactDirectory = bundleURL.appending(
      path: LinuxPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    guard manifest.linuxConfiguration == nil,
      !fileManager.fileExists(atPath: finalArtifactDirectory.path)
    else {
      throw VirtualMachineModelError.linuxPlatformArtifactsAlreadyExist(id)
    }

    let stagingDirectory = bundleURL.appending(
      path: ".\(LinuxPlatformArtifactURLs.directoryName).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let stagingArtifacts = LinuxPlatformArtifactURLs(directory: stagingDirectory)
    var promotedArtifacts = false

    do {
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false
      )
      let preparation = try await linuxPlatformArtifactPreparer.prepare(
        installationMediaURL: installationMediaURL,
        destination: stagingArtifacts
      )
      try bundleStore.validatePreparedArtifacts(stagingArtifacts)

      try fileManager.moveItem(at: stagingDirectory, to: finalArtifactDirectory)
      promotedArtifacts = true

      manifest.markReadyToInstallLinux(
        configuration: LinuxVirtualMachineConfiguration(
          efiVariableStorePath: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
          machineIdentifierPath: LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
          installationMediaPath: LinuxPlatformArtifactURLs.installationMediaManifestPath,
          macAddress: preparation.macAddress
        )
      )
      try bundleStore.write(
        manifest,
        to: bundleURL.appending(path: Self.manifestFilename)
      )
      return manifest
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      if promotedArtifacts {
        try? fileManager.removeItem(at: finalArtifactDirectory)
      }
      throw error
    }
  }

  func discardVirtualMachine(id: UUID) async throws {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try bundleStore.manifest(id: id)
    guard manifest.installState != .installing else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: id)
    try bundleStore.requireDirectory(bundleURL)
    guard
      let runtimeLock = try AdvisoryFileLock.acquire(
        at: bundleURL.appending(path: Self.runtimeLockFilename)
      )
    else {
      throw MacVirtualMachineRuntimeError.ownedElsewhere(id)
    }
    defer { runtimeLock.release() }
    try requireNoDiskImageReplacementJournal(in: bundleURL, machineID: id)
    let tombstoneURL = rootURL.appending(
      path:
        "\(Self.deletionTombstonePrefix)\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())\(Self.deletionTombstoneSuffix)",
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: bundleURL, to: tombstoneURL)
    try fileManager.removeItem(at: tombstoneURL)
  }

  func beginClone(id: UUID, name: String) throws -> VirtualMachineCloneTransaction {
    try bundleStore.ensureRootExists()
    let operationID = UUID()
    try acquireOperationAccess(token: operationID)
    var runtimeLock: AdvisoryFileLockLease?
    var didBegin = false
    defer {
      if !didBegin {
        runtimeLock?.release()
        releaseOperationAccess(token: operationID)
      }
    }

    let source = try installationManifest(id: id)
    guard source.installState == .stopped else {
      throw VirtualMachineCloneError.invalidSourceState(source.installState)
    }
    let sourceBundleURL = bundleStore.bundleURL(for: id)
    try bundleStore.requireDirectory(sourceBundleURL)
    guard
      let acquiredRuntimeLock = try AdvisoryFileLock.acquire(
        at: sourceBundleURL.appending(path: Self.runtimeLockFilename)
      )
    else {
      throw MacVirtualMachineRuntimeError.ownedElsewhere(id)
    }
    runtimeLock = acquiredRuntimeLock
    _ = try macVirtualMachineBundleResolver.resolveRuntime(source)

    let clone = try VirtualMachineManifest(cloning: source, name: name)
    let finalBundleURL = bundleStore.bundleURL(for: clone.id)
    guard !fileManager.fileExists(atPath: finalBundleURL.path) else {
      throw VirtualMachineModelError.duplicateIdentifier(clone.id)
    }
    let stagingBundleURL = rootURL.appending(
      path:
        "\(Self.cloneStagingPrefix)\(clone.id.uuidString.lowercased())-\(operationID.uuidString.lowercased())\(Self.cloneStagingSuffix)",
      directoryHint: .isDirectory
    )
    guard !fileManager.fileExists(atPath: stagingBundleURL.path) else {
      throw VirtualMachineCloneError.invalidBundle("a clone staging bundle already exists")
    }

    let transaction = VirtualMachineCloneTransaction(
      operationID: operationID,
      source: source,
      clone: clone,
      sourceBundleURL: sourceBundleURL,
      stagingBundleURL: stagingBundleURL,
      finalBundleURL: finalBundleURL
    )
    activeClones[operationID] = ActiveClone(
      transaction: transaction,
      runtimeLock: acquiredRuntimeLock
    )
    didBegin = true
    return transaction
  }

  func commitClone(
    _ transaction: VirtualMachineCloneTransaction
  ) throws -> VirtualMachineManifest {
    _ = try activeClone(transaction)
    try bundleValidator.validateCloneBundle(transaction)
    guard !fileManager.fileExists(atPath: transaction.finalBundleURL.path) else {
      throw VirtualMachineModelError.duplicateIdentifier(transaction.clone.id)
    }
    try fileManager.moveItem(
      at: transaction.stagingBundleURL,
      to: transaction.finalBundleURL
    )
    finishClone(operationID: transaction.operationID)
    return transaction.clone
  }

  func abortClone(_ transaction: VirtualMachineCloneTransaction) throws {
    _ = try activeClone(transaction)
    defer { finishClone(operationID: transaction.operationID) }
    guard fileManager.fileExists(atPath: transaction.stagingBundleURL.path) else { return }
    try bundleStore.requireDirectory(transaction.stagingBundleURL)
    try fileManager.removeItem(at: transaction.stagingBundleURL)
  }

  func acquireExportSource(id: UUID) throws -> VirtualMachineExportSourceLease {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try installationManifest(id: id)
    guard manifest.installState == .stopped else {
      throw VirtualMachineTransferError.invalidSourceState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: id)
    try bundleStore.requireDirectory(bundleURL)
    guard
      let runtimeLock = try AdvisoryFileLock.acquire(
        at: bundleURL.appending(path: Self.runtimeLockFilename)
      )
    else {
      throw MacVirtualMachineRuntimeError.ownedElsewhere(id)
    }

    do {
      _ = try macVirtualMachineBundleResolver.resolveRuntime(manifest)
      return VirtualMachineExportSourceLease(
        manifest: manifest,
        bundleURL: bundleURL
      ) {
        runtimeLock.release()
      }
    } catch {
      runtimeLock.release()
      throw error
    }
  }

  func beginImport(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) throws -> VirtualMachineImportTransaction {
    try bundleStore.ensureRootExists()
    let operationID = UUID()
    try acquireOperationAccess(token: operationID)
    var didBegin = false
    defer {
      if !didBegin {
        releaseOperationAccess(token: operationID)
      }
    }

    let sourceBundleURL = sourceURL.standardizedFileURL
    guard sourceBundleURL.isFileURL,
      sourceBundleURL.pathExtension.caseInsensitiveCompare(Self.bundleExtension)
        == .orderedSame
    else {
      throw VirtualMachineTransferError.invalidPackage(
        "the selected item is not a .\(Self.bundleExtension) package"
      )
    }
    guard !bundleStore.isSameOrDescendant(sourceBundleURL, of: rootURL) else {
      throw VirtualMachineTransferError.invalidPackage(
        "packages already inside the active library cannot be imported"
      )
    }
    try bundleStore.requireDirectory(sourceBundleURL)

    let source: VirtualMachineManifest
    do {
      source = try bundleStore.readManifest(in: sourceBundleURL)
    } catch {
      throw VirtualMachineTransferError.invalidPackage(error.localizedDescription)
    }
    guard source.guest == .macOS else {
      throw VirtualMachineTransferError.invalidPackage(
        "only macOS virtual machine packages are supported"
      )
    }
    guard source.installState == .stopped else {
      throw VirtualMachineTransferError.invalidSourceState(source.installState)
    }

    let imported = try source.imported(using: mode)
    let finalBundleURL = bundleStore.bundleURL(for: imported.id)
    guard !fileManager.fileExists(atPath: finalBundleURL.path) else {
      throw VirtualMachineTransferError.identityCollision(imported.id)
    }
    let stagingBundleURL = rootURL.appending(
      path:
        "\(Self.importStagingPrefix)\(imported.id.uuidString.lowercased())-\(operationID.uuidString.lowercased())\(Self.importStagingSuffix)",
      directoryHint: .isDirectory
    )
    guard !fileManager.fileExists(atPath: stagingBundleURL.path) else {
      throw VirtualMachineTransferError.invalidPackage(
        "an import staging package already exists"
      )
    }

    let transaction = VirtualMachineImportTransaction(
      operationID: operationID,
      source: source,
      imported: imported,
      sourceBundleURL: sourceBundleURL,
      stagingBundleURL: stagingBundleURL,
      finalBundleURL: finalBundleURL,
      mode: mode
    )
    activeImports[operationID] = ActiveImport(transaction: transaction)
    didBegin = true
    return transaction
  }

  func commitImport(
    _ transaction: VirtualMachineImportTransaction
  ) throws -> VirtualMachineManifest {
    _ = try activeImport(transaction)
    try bundleValidator.validateImportedBundle(transaction)
    guard !fileManager.fileExists(atPath: transaction.finalBundleURL.path) else {
      throw VirtualMachineTransferError.identityCollision(transaction.imported.id)
    }
    try fileManager.moveItem(
      at: transaction.stagingBundleURL,
      to: transaction.finalBundleURL
    )
    finishImport(operationID: transaction.operationID)
    return transaction.imported
  }

  func abortImport(_ transaction: VirtualMachineImportTransaction) throws {
    _ = try activeImport(transaction)
    defer { finishImport(operationID: transaction.operationID) }
    guard fileManager.fileExists(atPath: transaction.stagingBundleURL.path) else { return }
    try bundleStore.requireDirectory(transaction.stagingBundleURL)
    try fileManager.removeItem(at: transaction.stagingBundleURL)
  }

  func acquireMacOSRuntime(id: UUID) throws -> MacVirtualMachineRuntimeLease {
    try acquireMacOSRuntime(id: id, allowsDiskImageReplacementJournal: false)
  }

  func acquireDiskImageReplacementRuntime(
    id: UUID
  ) throws -> MacVirtualMachineRuntimeLease {
    try acquireMacOSRuntime(id: id, allowsDiskImageReplacementJournal: true)
  }

  private func acquireMacOSRuntime(
    id: UUID,
    allowsDiskImageReplacementJournal: Bool
  ) throws -> MacVirtualMachineRuntimeLease {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try installationManifest(id: id)
    guard manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: manifest.id)
    try bundleStore.requireDirectory(bundleURL)
    if !allowsDiskImageReplacementJournal {
      try requireNoDiskImageReplacementJournal(
        in: bundleURL,
        machineID: id
      )
    }
    let lockURL = bundleURL.appending(path: Self.runtimeLockFilename)
    guard let runtimeLock = try AdvisoryFileLock.acquire(at: lockURL) else {
      throw MacVirtualMachineRuntimeError.ownedElsewhere(id)
    }

    do {
      let resolvedMachine = try macVirtualMachineBundleResolver.resolveRuntime(manifest)
      let machine = ResolvedMacVirtualMachine(
        manifest: resolvedMachine.manifest,
        bundleURL: resolvedMachine.bundleURL,
        diskImageURL: resolvedMachine.diskImageURL,
        auxiliaryStorageURL: resolvedMachine.auxiliaryStorageURL,
        hardwareModelURL: resolvedMachine.hardwareModelURL,
        machineIdentifierURL: resolvedMachine.machineIdentifierURL,
        sharedDirectories: try bundleValidator.sharedDirectoryConfiguration(
          in: resolvedMachine.bundleURL
        )
      )
      let target = MacVirtualMachineRuntimeTarget(machineID: id, generation: UUID())
      let ownerURL = try writeRuntimeOwner(for: target, in: machine.bundleURL)

      let fileManager = fileManager
      return MacVirtualMachineRuntimeLease(machine: machine, target: target) {
        try? fileManager.removeItem(at: ownerURL)
        runtimeLock.release()
      }
    } catch {
      runtimeLock.release()
      throw error
    }
  }

  func acquireLinuxRuntime(id: UUID) throws -> LinuxVirtualMachineRuntimeLease {
    try bundleStore.ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try linuxRuntimeManifest(id: id)
    guard manifest.installState == .readyToInstall || manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: manifest.id)
    try bundleStore.requireDirectory(bundleURL)
    try requireNoLinuxDiskImageReplacementJournal(in: bundleURL, machineID: id)

    let lockURL = bundleURL.appending(path: Self.runtimeLockFilename)
    guard let runtimeLock = try AdvisoryFileLock.acquire(at: lockURL) else {
      throw LinuxVirtualMachineRuntimeError.ownedElsewhere(id)
    }

    do {
      let resolvedMachine = try linuxVirtualMachineBundleResolver.resolve(manifest)
      let machine = ResolvedLinuxVirtualMachine(
        manifest: resolvedMachine.manifest,
        bundleURL: resolvedMachine.bundleURL,
        diskImageURL: resolvedMachine.diskImageURL,
        efiVariableStoreURL: resolvedMachine.efiVariableStoreURL,
        machineIdentifierURL: resolvedMachine.machineIdentifierURL,
        installationMediaURL: resolvedMachine.installationMediaURL,
        sharedDirectories: try bundleValidator.sharedDirectoryConfiguration(
          in: resolvedMachine.bundleURL
        )
      )
      let target = LinuxVirtualMachineRuntimeTarget(machineID: id, generation: UUID())
      let ownerURL = try writeRuntimeOwner(for: target, in: machine.bundleURL)
      let fileManager = fileManager
      return LinuxVirtualMachineRuntimeLease(machine: machine, target: target) {
        try? fileManager.removeItem(at: ownerURL)
        runtimeLock.release()
      }
    } catch {
      runtimeLock.release()
      throw error
    }
  }

  func completeLinuxInstallation(
    lease: LinuxVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    let borrow = try lease.borrow()
    defer { borrow.release() }

    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    var manifest = try linuxRuntimeManifest(id: lease.target.machineID)
    guard manifest.id == lease.machine.manifest.id else {
      throw LinuxVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    if manifest.installState == .stopped,
      manifest.linuxConfiguration?.installationMediaPath == nil
    {
      return manifest
    }
    guard manifest.installState == .readyToInstall,
      manifest.linuxConfiguration?.installationMediaPath != nil
    else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }

    manifest.markLinuxInstallationCompleted()
    try bundleStore.write(
      manifest,
      to: bundleStore.manifestURL(for: manifest.id)
    )
    return manifest
  }

  private func writeRuntimeOwner(
    for target: VirtualMachineRuntimeTarget,
    in bundleURL: URL
  ) throws -> URL {
    let ownerURL = bundleURL.appending(path: Self.runtimeOwnerFilename)
    let owner = VirtualMachineRuntimeOwnerRecord(
      machineID: target.machineID,
      generation: target.generation,
      launchID: launchID,
      processID: ProcessInfo.processInfo.processIdentifier,
      acquiredAt: Date()
    )
    try Self.encoder.encode(owner).write(to: ownerURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: ownerURL.path
    )
    return ownerURL
  }

  private func requireNoLinuxDiskImageReplacementJournal(
    in bundleURL: URL,
    machineID: UUID
  ) throws {
    do {
      guard
        try FileVirtualMachineDiskImageReplacementJournalStore(
          fileManager: fileManager
        ).load(in: bundleURL) == nil
      else {
        throw LinuxVirtualMachineRuntimeError.diskReplacementPending(machineID)
      }
    } catch let error as LinuxVirtualMachineRuntimeError {
      throw error
    } catch {
      throw LinuxVirtualMachineRuntimeError.diskReplacementPending(machineID)
    }
  }

  private func requireNoDiskImageReplacementJournal(
    in bundleURL: URL,
    machineID: UUID
  ) throws {
    do {
      guard
        try FileVirtualMachineDiskImageReplacementJournalStore(
          fileManager: fileManager
        ).load(in: bundleURL) == nil
      else {
        throw MacVirtualMachineRuntimeError.diskReplacementPending(machineID)
      }
    } catch let error as MacVirtualMachineRuntimeError {
      throw error
    } catch {
      throw MacVirtualMachineRuntimeError.diskReplacementPending(machineID)
    }
  }

  func stageMacOSInstallation(
    id: UUID,
    operationID: UUID
  ) throws -> PreparedMacVirtualMachine {
    try bundleStore.ensureRootExists()
    try acquireOperationAccess(token: operationID)
    var staged = false
    defer {
      if !staged {
        releaseOperationAccess(token: operationID)
      }
    }

    let manifest = try installationManifest(id: id)
    guard manifest.installState == .readyToInstall, manifest.installationOperationID == nil else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let preparedMachine = try macVirtualMachineBundleResolver.resolve(manifest)
    let stagingDirectory = bundleStore.installationStagingDirectory(
      id: id,
      operationID: operationID
    )
    let installedDirectory = bundleStore.installationInstalledDirectory(id: id)
    guard !fileManager.fileExists(atPath: stagingDirectory.path),
      !fileManager.fileExists(atPath: installedDirectory.path)
    else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "installation workspace already exists"
      )
    }

    do {
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false
      )
      let stagedDisk = stagingDirectory.appending(path: Self.installationDiskFilename)
      try bundleStore.createSparseDisk(at: stagedDisk, size: manifest.resources.diskBytes)
      let stagedAuxiliaryStorage = stagingDirectory.appending(
        path: Self.installationAuxiliaryStorageFilename
      )
      try fileManager.copyItem(
        at: preparedMachine.auxiliaryStorageURL,
        to: stagedAuxiliaryStorage
      )
      let prepared = PreparedMacVirtualMachine(
        manifest: manifest,
        bundleURL: preparedMachine.bundleURL,
        restoreImageURL: preparedMachine.restoreImageURL,
        diskImageURL: stagedDisk,
        auxiliaryStorageURL: stagedAuxiliaryStorage,
        hardwareModelURL: preparedMachine.hardwareModelURL,
        machineIdentifierURL: preparedMachine.machineIdentifierURL
      )
      installationOperationIDs.insert(operationID)
      staged = true
      return prepared
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }
  }

  func discardStagedMacOSInstallation(id: UUID, operationID: UUID) throws {
    guard installationOperationIDs.contains(operationID) else { return }
    defer { finishInstallationOperation(operationID) }
    try removeStagedMacOSInstallation(id: id, operationID: operationID)
  }

  private func removeStagedMacOSInstallation(id: UUID, operationID: UUID) throws {
    let stagingDirectory = bundleStore.installationStagingDirectory(
      id: id,
      operationID: operationID
    )
    guard fileManager.fileExists(atPath: stagingDirectory.path) else { return }
    try bundleStore.requireDirectory(stagingDirectory)
    try fileManager.removeItem(at: stagingDirectory)
  }

  func beginMacOSInstallation(id: UUID, operationID: UUID) throws {
    guard installationOperationIDs.contains(operationID) else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    var manifest = try installationManifest(id: id)
    guard manifest.installState == .readyToInstall, manifest.installationOperationID == nil else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let stagingDirectory = bundleStore.installationStagingDirectory(
      id: id,
      operationID: operationID
    )
    try bundleStore.requireDirectory(stagingDirectory)
    manifest.markInstallationStarted(operationID: operationID)
    try bundleStore.write(manifest, to: bundleStore.manifestURL(for: id))
  }

  func completeMacOSInstallation(id: UUID, operationID: UUID) throws {
    guard installationOperationIDs.contains(operationID) else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    var manifest = try installationManifest(id: id)
    guard manifest.installState == .installing,
      manifest.installationOperationID == operationID
    else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }

    let stagingDirectory = bundleStore.installationStagingDirectory(
      id: id,
      operationID: operationID
    )
    let installedDirectory = bundleStore.installationInstalledDirectory(id: id)
    try bundleStore.requireDirectory(stagingDirectory)
    guard !fileManager.fileExists(atPath: installedDirectory.path) else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "installed artifact directory already exists"
      )
    }

    let currentBundleURL = bundleStore.bundleURL(for: id)
    let previousDiskURL = try macVirtualMachineBundleResolver.resolveArtifact(
      manifest.diskImagePath,
      named: "diskImagePath",
      in: currentBundleURL,
      writable: true
    )
    guard let previousAuxiliaryStoragePath = manifest.auxiliaryStoragePath else {
      throw MacVirtualMachineInstallationError.missingManifestValue(
        "auxiliaryStoragePath"
      )
    }
    let previousAuxiliaryStorageURL =
      try macVirtualMachineBundleResolver.resolveArtifact(
        previousAuxiliaryStoragePath,
        named: "auxiliaryStoragePath",
        in: currentBundleURL,
        writable: true
      )
    try fileManager.moveItem(at: stagingDirectory, to: installedDirectory)

    let installedDiskPath =
      "\(Self.installationInstalledDirectoryName)/\(Self.installationDiskFilename)"
    let installedAuxiliaryStoragePath =
      "\(Self.installationInstalledDirectoryName)/\(Self.installationAuxiliaryStorageFilename)"
    manifest.markInstallationCompleted(
      diskImagePath: installedDiskPath,
      auxiliaryStoragePath: installedAuxiliaryStoragePath
    )
    do {
      try bundleStore.write(manifest, to: bundleStore.manifestURL(for: id))
    } catch {
      try? fileManager.moveItem(at: installedDirectory, to: stagingDirectory)
      throw error
    }

    if previousDiskURL.standardizedFileURL
      != installedDirectory.appending(path: Self.installationDiskFilename).standardizedFileURL
    {
      try? fileManager.removeItem(at: previousDiskURL)
    }
    if previousAuxiliaryStorageURL.standardizedFileURL
      != installedDirectory.appending(
        path: Self.installationAuxiliaryStorageFilename
      ).standardizedFileURL
    {
      try? fileManager.removeItem(at: previousAuxiliaryStorageURL)
    }
    finishInstallationOperation(operationID)
  }

  func abortMacOSInstallation(
    id: UUID,
    operationID: UUID,
    kind: VirtualMachineInstallationFailureKind,
    message: String
  ) throws {
    guard installationOperationIDs.contains(operationID) else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    defer { finishInstallationOperation(operationID) }

    var manifest = try installationManifest(id: id)
    guard manifest.installState == .installing,
      manifest.installationOperationID == operationID
    else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    try removeStagedMacOSInstallation(id: id, operationID: operationID)
    let installedDirectory = bundleStore.installationInstalledDirectory(id: id)
    if fileManager.fileExists(atPath: installedDirectory.path) {
      try bundleStore.requireDirectory(installedDirectory)
      try fileManager.removeItem(at: installedDirectory)
    }
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    manifest.markInstallationAborted(
      kind: kind,
      message: normalizedMessage.isEmpty
        ? "macOS installation did not complete." : normalizedMessage
    )
    try bundleStore.write(manifest, to: bundleStore.manifestURL(for: id))
  }

  func recoverInterruptedMacOSInstallations() throws -> MacVirtualMachineRecoveryOutcome {
    guard operationAccessTokens.isEmpty else { return .deferredToAnotherProcess }
    try bundleStore.ensureRootExists()
    let recoveryToken = UUID()
    guard try acquireRecoveryAccess(token: recoveryToken) else {
      return .deferredToAnotherProcess
    }
    defer { releaseOperationAccess(token: recoveryToken) }

    try bundleStore.removeRecoveryArtifacts()
    for var manifest in try list() {
      try bundleStore.removeOrphanedInstallationStagingDirectories(id: manifest.id)
      let installedDirectory = bundleStore.installationInstalledDirectory(id: manifest.id)

      if manifest.installState == .installing {
        if fileManager.fileExists(atPath: installedDirectory.path) {
          try bundleStore.requireDirectory(installedDirectory)
          try fileManager.removeItem(at: installedDirectory)
        }
        manifest.markInstallationAborted(
          kind: .interrupted,
          message:
            "The app exited before macOS installation completed. The pristine prepared media was restored."
        )
        try bundleStore.write(
          manifest,
          to: bundleStore.manifestURL(for: manifest.id)
        )
      } else if !manifest.diskImagePath.hasPrefix(
        "\(Self.installationInstalledDirectoryName)/"
      ), fileManager.fileExists(atPath: installedDirectory.path) {
        try bundleStore.requireDirectory(installedDirectory)
        try fileManager.removeItem(at: installedDirectory)
      }
    }
    return .recovered
  }

  private func installationManifest(id: UUID) throws -> VirtualMachineManifest {
    let manifest = try bundleStore.manifest(id: id)
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(id)
    }
    return manifest
  }

  private func linuxRuntimeManifest(id: UUID) throws -> VirtualMachineManifest {
    let manifest = try bundleStore.manifest(id: id)
    guard manifest.guest == .linux else {
      throw VirtualMachineModelError.requiresLinuxGuest(id)
    }
    return manifest
  }

  private func activeClone(
    _ transaction: VirtualMachineCloneTransaction
  ) throws -> ActiveClone {
    guard let active = activeClones[transaction.operationID],
      active.transaction == transaction
    else {
      throw VirtualMachineCloneError.staleTransaction(transaction.source.id)
    }
    return active
  }

  private func activeImport(
    _ transaction: VirtualMachineImportTransaction
  ) throws -> ActiveImport {
    guard let active = activeImports[transaction.operationID],
      active.transaction == transaction
    else {
      throw VirtualMachineTransferError.staleTransaction(transaction.imported.id)
    }
    return active
  }

  private func requireConfigurationMutationLease(
    _ lease: MacVirtualMachineRuntimeLease
  ) throws -> URL {
    let manifest = try installationManifest(id: lease.target.machineID)
    guard manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: manifest.id).standardizedFileURL
    guard bundleURL == lease.machine.bundleURL.standardizedFileURL,
      lease.machine.manifest.id == manifest.id
    else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    try bundleStore.requireDirectory(bundleURL)
    return bundleURL
  }

  private func requireConfigurationMutationLease(
    _ lease: LinuxVirtualMachineRuntimeLease
  ) throws -> URL {
    let manifest = try linuxRuntimeManifest(id: lease.target.machineID)
    guard manifest.installState == .readyToInstall || manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleStore.bundleURL(for: manifest.id).standardizedFileURL
    guard bundleURL == lease.machine.bundleURL.standardizedFileURL,
      lease.machine.manifest.id == manifest.id
    else {
      throw LinuxVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    try bundleStore.requireDirectory(bundleURL)
    return bundleURL
  }

  private func acquireOperationAccess(token: UUID) throws {
    guard operationAccessTokens.isEmpty, operationLockLease == nil else {
      throw VirtualMachineModelError.libraryInUse
    }
    guard operationAccessTokens.insert(token).inserted else {
      throw VirtualMachineModelError.libraryInUse
    }

    do {
      guard
        let lease = try AdvisoryFileLock.acquire(
          at: rootURL.appending(path: Self.operationLockFilename)
        )
      else {
        operationAccessTokens.remove(token)
        throw VirtualMachineModelError.libraryInUse
      }
      operationLockLease = lease
    } catch {
      operationAccessTokens.remove(token)
      throw error
    }
  }

  private func acquireRecoveryAccess(token: UUID) throws -> Bool {
    guard operationAccessTokens.insert(token).inserted else { return false }
    do {
      guard
        let lease = try AdvisoryFileLock.acquire(
          at: rootURL.appending(path: Self.operationLockFilename)
        )
      else {
        operationAccessTokens.remove(token)
        return false
      }
      operationLockLease = lease
      return true
    } catch {
      operationAccessTokens.remove(token)
      throw error
    }
  }

  private func releaseOperationAccess(token: UUID) {
    guard operationAccessTokens.remove(token) != nil else { return }
    guard operationAccessTokens.isEmpty else { return }
    operationLockLease?.release()
    operationLockLease = nil
  }

  private func finishInstallationOperation(_ operationID: UUID) {
    installationOperationIDs.remove(operationID)
    releaseOperationAccess(token: operationID)
  }

  private func finishClone(operationID: UUID) {
    guard let active = activeClones.removeValue(forKey: operationID) else { return }
    active.runtimeLock.release()
    releaseOperationAccess(token: operationID)
  }

  private func finishImport(operationID: UUID) {
    guard activeImports.removeValue(forKey: operationID) != nil else { return }
    releaseOperationAccess(token: operationID)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}
