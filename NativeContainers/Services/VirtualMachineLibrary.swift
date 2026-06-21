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

protocol VirtualMachineDiscarding: Sendable {
  func discardVirtualMachine(id: UUID) async throws
}

protocol VirtualMachineLibraryProtocol:
  VirtualMachineInventoryLoading,
  VirtualMachineDraftCreating,
  MacVirtualMachinePreparing,
  VirtualMachineDiscarding
{}

extension MacVirtualMachinePreparing {
  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    throw VirtualMachineModelError.macPlatformPreparationUnavailable
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
  MacVirtualMachineInstallationStoring,
  MacVirtualMachineRuntimeLeasing,
  MacVirtualMachineSharedDirectoryPersisting
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

  private let rootURL: URL
  private let fileManager: FileManager
  private let launchID: UUID
  private let macPlatformArtifactPreparer: any MacPlatformArtifactPreparing
  private let macVirtualMachineBundleResolver: any MacVirtualMachineBundleResolving
  private let sharedDirectoryStore: any MacVirtualMachineSharedDirectoryConfigurationStoring
  private let sharedDirectoryNameValidator: any MacVirtualMachineSharedDirectoryNameValidating
  private var operationLockLease: AdvisoryFileLockLease?
  private var operationAccessTokens = Set<UUID>()
  private var installationOperationIDs = Set<UUID>()

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    launchID: UUID = UUID(),
    macPlatformArtifactPreparer: any MacPlatformArtifactPreparing = MacPlatformArtifactPreparer(),
    sharedDirectoryStore: any MacVirtualMachineSharedDirectoryConfigurationStoring =
      FileMacVirtualMachineSharedDirectoryConfigurationStore(),
    sharedDirectoryNameValidator: any MacVirtualMachineSharedDirectoryNameValidating =
      AppleMacVirtualMachineSharedDirectoryNameValidator()
  ) {
    self.fileManager = fileManager
    self.launchID = launchID
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    self.macPlatformArtifactPreparer = macPlatformArtifactPreparer
    self.macVirtualMachineBundleResolver = MacVirtualMachineBundleResolver(
      rootURL: self.rootURL,
      fileManager: fileManager
    )
    self.sharedDirectoryStore = sharedDirectoryStore
    self.sharedDirectoryNameValidator = sharedDirectoryNameValidator
  }

  func list() throws -> [VirtualMachineManifest] {
    try ensureRootExists()

    let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
    let entries = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    )

    return try entries.compactMap { bundleURL in
      guard bundleURL.pathExtension == Self.bundleExtension else { return nil }
      let values = try bundleURL.resourceValues(forKeys: resourceKeys)
      guard values.isDirectory == true, values.isHidden != true else { return nil }

      let manifest = try readManifest(in: bundleURL)
      let bundleName = bundleURL.deletingPathExtension().lastPathComponent
      guard bundleName.caseInsensitiveCompare(manifest.id.uuidString) == .orderedSame else {
        throw VirtualMachineModelError.bundleIdentifierMismatch(
          expected: manifest.id,
          bundleName: bundleURL.lastPathComponent
        )
      }
      return manifest
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func macOSSharedDirectoryConfiguration(
    id: UUID
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let manifest = try installationManifest(id: id)
    let bundleURL = bundleURL(for: manifest.id)
    try requireDirectory(bundleURL)
    return try validatedSharedDirectoryConfiguration(in: bundleURL)
  }

  func addMacOSSharedDirectory(
    _ directory: MacVirtualMachineSharedDirectory,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    var current = try validatedSharedDirectoryConfiguration(in: bundleURL)

    try sharedDirectoryNameValidator.validatePersistedName(directory.guestName)
    let normalizedName = MacVirtualMachineSharedDirectoryNameNormalizer.normalized(
      directory.guestName
    )
    guard
      !current.directories.contains(where: {
        MacVirtualMachineSharedDirectoryNameNormalizer.normalized($0.guestName)
          == normalizedName
      })
    else {
      throw MacVirtualMachineSharedDirectoryError.duplicateName(
        directory.guestName
      )
    }
    guard !current.directories.contains(where: { $0.id == directory.id }) else {
      throw MacVirtualMachineSharedDirectoryError.invalidStore(
        "the shared-folder identifier already exists"
      )
    }
    guard current.revision < UInt64.max else {
      throw MacVirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }

    current = MacVirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories + [directory]
    )
    try sharedDirectoryStore.save(current, to: bundleURL)
    return current
  }

  func removeMacOSSharedDirectory(
    id: UUID,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    let bundleURL = try requireConfigurationMutationLease(lease)
    let current = try validatedSharedDirectoryConfiguration(in: bundleURL)
    guard current.directories.contains(where: { $0.id == id }) else {
      throw MacVirtualMachineSharedDirectoryError.sharedDirectoryNotFound(id)
    }
    guard current.revision < UInt64.max else {
      throw MacVirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }

    let updated = MacVirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories.filter { $0.id != id }
    )
    try sharedDirectoryStore.save(updated, to: bundleURL)
    return updated
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    try ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try VirtualMachineManifest(name: name, guest: guest, resources: resources)
    let finalURL = bundleURL(for: manifest.id)
    guard !fileManager.fileExists(atPath: finalURL.path) else {
      throw VirtualMachineModelError.duplicateIdentifier(manifest.id)
    }

    let stagingURL = rootURL.appending(
      path: ".\(manifest.id.uuidString).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )

    do {
      try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
      try createSparseDisk(
        at: stagingURL.appending(path: manifest.diskImagePath),
        size: resources.diskBytes
      )
      try write(manifest, to: stagingURL.appending(path: Self.manifestFilename))
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      return manifest
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    try ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let bundleURL = bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }

    var manifest = try readManifest(in: bundleURL)
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
      try validatePreparedArtifacts(stagingArtifacts)

      try fileManager.moveItem(at: stagingDirectory, to: finalArtifactDirectory)
      promotedArtifacts = true

      manifest.markReadyToInstallMacOS(
        restoreImageURL: restoreImageURL,
        auxiliaryStoragePath: MacPlatformArtifactURLs.auxiliaryStorageManifestPath,
        hardwareModelPath: MacPlatformArtifactURLs.hardwareModelManifestPath,
        machineIdentifierPath: MacPlatformArtifactURLs.machineIdentifierManifestPath
      )
      try write(manifest, to: bundleURL.appending(path: Self.manifestFilename))
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
    try ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try manifest(id: id)
    guard manifest.installState != .installing else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleURL(for: id)
    try requireDirectory(bundleURL)
    guard
      let runtimeLock = try AdvisoryFileLock.acquire(
        at: bundleURL.appending(path: Self.runtimeLockFilename)
      )
    else {
      throw MacVirtualMachineRuntimeError.ownedElsewhere(id)
    }
    defer { runtimeLock.release() }
    let tombstoneURL = rootURL.appending(
      path:
        "\(Self.deletionTombstonePrefix)\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())\(Self.deletionTombstoneSuffix)",
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: bundleURL, to: tombstoneURL)
    try fileManager.removeItem(at: tombstoneURL)
  }

  func acquireMacOSRuntime(id: UUID) throws -> MacVirtualMachineRuntimeLease {
    try ensureRootExists()
    let accessToken = UUID()
    try acquireOperationAccess(token: accessToken)
    defer { releaseOperationAccess(token: accessToken) }

    let manifest = try installationManifest(id: id)
    guard manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleURL(for: manifest.id)
    try requireDirectory(bundleURL)
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
        sharedDirectories: try validatedSharedDirectoryConfiguration(
          in: resolvedMachine.bundleURL
        )
      )
      let target = MacVirtualMachineRuntimeTarget(machineID: id, generation: UUID())
      let ownerURL = machine.bundleURL.appending(path: Self.runtimeOwnerFilename)
      let owner = MacVirtualMachineRuntimeOwnerRecord(
        machineID: id,
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

  func stageMacOSInstallation(
    id: UUID,
    operationID: UUID
  ) throws -> PreparedMacVirtualMachine {
    try ensureRootExists()
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
    let stagingDirectory = installationStagingDirectory(id: id, operationID: operationID)
    let installedDirectory = installationInstalledDirectory(id: id)
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
      try createSparseDisk(at: stagedDisk, size: manifest.resources.diskBytes)
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
    let stagingDirectory = installationStagingDirectory(id: id, operationID: operationID)
    guard fileManager.fileExists(atPath: stagingDirectory.path) else { return }
    try requireDirectory(stagingDirectory)
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
    let stagingDirectory = installationStagingDirectory(id: id, operationID: operationID)
    try requireDirectory(stagingDirectory)
    manifest.markInstallationStarted(operationID: operationID)
    try write(manifest, to: manifestURL(for: id))
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

    let stagingDirectory = installationStagingDirectory(id: id, operationID: operationID)
    let installedDirectory = installationInstalledDirectory(id: id)
    try requireDirectory(stagingDirectory)
    guard !fileManager.fileExists(atPath: installedDirectory.path) else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "installed artifact directory already exists"
      )
    }

    let currentBundleURL = bundleURL(for: id)
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
      try write(manifest, to: manifestURL(for: id))
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
    let installedDirectory = installationInstalledDirectory(id: id)
    if fileManager.fileExists(atPath: installedDirectory.path) {
      try requireDirectory(installedDirectory)
      try fileManager.removeItem(at: installedDirectory)
    }
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    manifest.markInstallationAborted(
      kind: kind,
      message: normalizedMessage.isEmpty
        ? "macOS installation did not complete." : normalizedMessage
    )
    try write(manifest, to: manifestURL(for: id))
  }

  func recoverInterruptedMacOSInstallations() throws -> MacVirtualMachineRecoveryOutcome {
    guard operationAccessTokens.isEmpty else { return .deferredToAnotherProcess }
    try ensureRootExists()
    let recoveryToken = UUID()
    guard try acquireRecoveryAccess(token: recoveryToken) else {
      return .deferredToAnotherProcess
    }
    defer { releaseOperationAccess(token: recoveryToken) }

    try removeDeletionTombstones()
    for var manifest in try list() {
      try removeOrphanedInstallationStagingDirectories(id: manifest.id)
      let installedDirectory = installationInstalledDirectory(id: manifest.id)

      if manifest.installState == .installing {
        if fileManager.fileExists(atPath: installedDirectory.path) {
          try requireDirectory(installedDirectory)
          try fileManager.removeItem(at: installedDirectory)
        }
        manifest.markInstallationAborted(
          kind: .interrupted,
          message:
            "The app exited before macOS installation completed. The pristine prepared media was restored."
        )
        try write(manifest, to: manifestURL(for: manifest.id))
      } else if !manifest.diskImagePath.hasPrefix(
        "\(Self.installationInstalledDirectoryName)/"
      ), fileManager.fileExists(atPath: installedDirectory.path) {
        try requireDirectory(installedDirectory)
        try fileManager.removeItem(at: installedDirectory)
      }
    }
    return .recovered
  }

  private func installationManifest(id: UUID) throws -> VirtualMachineManifest {
    let manifest = try manifest(id: id)
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(id)
    }
    return manifest
  }

  private func requireConfigurationMutationLease(
    _ lease: MacVirtualMachineRuntimeLease
  ) throws -> URL {
    let manifest = try installationManifest(id: lease.target.machineID)
    guard manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    let bundleURL = bundleURL(for: manifest.id).standardizedFileURL
    guard bundleURL == lease.machine.bundleURL.standardizedFileURL,
      lease.machine.manifest.id == manifest.id
    else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    try requireDirectory(bundleURL)
    return bundleURL
  }

  private func validatedSharedDirectoryConfiguration(
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

  private func manifest(id: UUID) throws -> VirtualMachineManifest {
    let bundleURL = bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let manifest = try readManifest(in: bundleURL)
    guard manifest.id == id else {
      throw VirtualMachineModelError.bundleIdentifierMismatch(
        expected: manifest.id,
        bundleName: bundleURL.lastPathComponent
      )
    }
    return manifest
  }

  private func manifestURL(for id: UUID) -> URL {
    bundleURL(for: id).appending(path: Self.manifestFilename)
  }

  private func removeOrphanedInstallationStagingDirectories(id: UUID) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL(for: id),
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(Self.installationStagingPrefix),
        name.hasSuffix(Self.installationStagingSuffix)
      else {
        continue
      }
      try requireDirectory(entry)
      try fileManager.removeItem(at: entry)
    }
  }

  private func removeDeletionTombstones() throws {
    let entries = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(Self.deletionTombstonePrefix),
        name.hasSuffix(Self.deletionTombstoneSuffix)
      else {
        continue
      }
      try requireDirectory(entry)
      try fileManager.removeItem(at: entry)
    }
  }

  private func installationStagingDirectory(id: UUID, operationID: UUID) -> URL {
    bundleURL(for: id).appending(
      path:
        "\(Self.installationStagingPrefix)\(operationID.uuidString.lowercased())\(Self.installationStagingSuffix)",
      directoryHint: .isDirectory
    )
  }

  private func installationInstalledDirectory(id: UUID) -> URL {
    bundleURL(for: id).appending(
      path: Self.installationInstalledDirectoryName,
      directoryHint: .isDirectory
    )
  }

  private func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "installation workspace is missing or symbolic"
      )
    }
  }

  private func ensureRootExists() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
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

  private func bundleURL(for id: UUID) -> URL {
    rootURL
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(Self.bundleExtension)
  }

  private func readManifest(in bundleURL: URL) throws -> VirtualMachineManifest {
    let data = try Data(contentsOf: bundleURL.appending(path: Self.manifestFilename))
    let manifest = try Self.decoder.decode(VirtualMachineManifest.self, from: data)
    guard manifest.schemaVersion == VirtualMachineManifest.currentSchemaVersion else {
      throw VirtualMachineModelError.unsupportedSchema(manifest.schemaVersion)
    }
    return manifest
  }

  private func validatePreparedArtifacts(_ artifacts: MacPlatformArtifactURLs) throws {
    for artifact in artifacts.all {
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: artifact.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw MacPlatformArtifactError.missingArtifact(artifact.lastPathComponent)
      }
    }
  }

  private func createSparseDisk(at url: URL, size: UInt64) throws {
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: size)
  }

  private func write(_ manifest: VirtualMachineManifest, to url: URL) throws {
    let data = try Self.encoder.encode(manifest)
    try data.write(to: url, options: [.atomic])
  }

  private static func defaultRootURL(fileManager: FileManager) -> URL {
    let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return
      supportURL
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Virtual Machines", directoryHint: .isDirectory)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()
}
