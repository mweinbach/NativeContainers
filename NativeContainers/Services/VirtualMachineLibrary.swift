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

protocol VirtualMachineLibraryProtocol:
  VirtualMachineInventoryLoading,
  VirtualMachineDraftCreating,
  MacVirtualMachinePreparing
{}

extension MacVirtualMachinePreparing {
  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    throw VirtualMachineModelError.macPlatformPreparationUnavailable
  }
}

protocol MacVirtualMachineInstallationStoring: Sendable {
  func resolvePreparedMacVM(id: UUID) async throws -> PreparedMacVirtualMachine
  func beginMacOSInstallation(id: UUID, operationID: UUID) async throws
  func completeMacOSInstallation(id: UUID, operationID: UUID) async throws
  func failMacOSInstallation(
    id: UUID,
    operationID: UUID,
    kind: VirtualMachineInstallationFailureKind,
    message: String
  ) async throws
  func recoverInterruptedMacOSInstallations() async throws
}

actor VirtualMachineLibrary: VirtualMachineLibraryProtocol, MacVirtualMachineInstallationStoring {
  static let bundleExtension = "nativevm"
  static let manifestFilename = "manifest.json"

  private let rootURL: URL
  private let fileManager: FileManager
  private let macPlatformArtifactPreparer: any MacPlatformArtifactPreparing
  private let macVirtualMachineBundleResolver: any MacVirtualMachineBundleResolving

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    macPlatformArtifactPreparer: any MacPlatformArtifactPreparing = MacPlatformArtifactPreparer()
  ) {
    self.fileManager = fileManager
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    self.macPlatformArtifactPreparer = macPlatformArtifactPreparer
    self.macVirtualMachineBundleResolver = MacVirtualMachineBundleResolver(
      rootURL: self.rootURL,
      fileManager: fileManager
    )
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

      return try readManifest(in: bundleURL)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    try ensureRootExists()
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

  func resolvePreparedMacVM(id: UUID) throws -> PreparedMacVirtualMachine {
    try ensureRootExists()
    let bundleURL = bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let manifest = try readManifest(in: bundleURL)
    guard manifest.installState == .readyToInstall else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    return try macVirtualMachineBundleResolver.resolve(manifest)
  }

  func beginMacOSInstallation(id: UUID, operationID: UUID) throws {
    var manifest = try installationManifest(id: id)
    guard manifest.installState == .readyToInstall, manifest.installationOperationID == nil else {
      throw VirtualMachineModelError.invalidInstallState(manifest.installState)
    }
    manifest.markInstallationStarted(operationID: operationID)
    try write(manifest, to: manifestURL(for: id))
  }

  func completeMacOSInstallation(id: UUID, operationID: UUID) throws {
    var manifest = try installationManifest(id: id)
    guard manifest.installState == .installing,
      manifest.installationOperationID == operationID
    else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    manifest.markInstallationCompleted()
    try write(manifest, to: manifestURL(for: id))
  }

  func failMacOSInstallation(
    id: UUID,
    operationID: UUID,
    kind: VirtualMachineInstallationFailureKind,
    message: String
  ) throws {
    var manifest = try installationManifest(id: id)
    guard manifest.installState == .installing,
      manifest.installationOperationID == operationID
    else {
      throw MacVirtualMachineInstallationError.staleOperation(id)
    }
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    manifest.markInstallationFailed(
      kind: kind,
      message: normalizedMessage.isEmpty
        ? "macOS installation did not complete." : normalizedMessage
    )
    try write(manifest, to: manifestURL(for: id))
  }

  func recoverInterruptedMacOSInstallations() throws {
    for var manifest in try list() where manifest.installState == .installing {
      manifest.markInstallationFailed(
        kind: .interrupted,
        message: "The app exited before macOS installation completed."
      )
      try write(manifest, to: manifestURL(for: manifest.id))
    }
  }

  private func installationManifest(id: UUID) throws -> VirtualMachineManifest {
    let bundleURL = bundleURL(for: id)
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let manifest = try readManifest(in: bundleURL)
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(id)
    }
    return manifest
  }

  private func manifestURL(for id: UUID) -> URL {
    bundleURL(for: id).appending(path: Self.manifestFilename)
  }

  private func ensureRootExists() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
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
