import Darwin
import Foundation
@preconcurrency import Virtualization

struct LinuxBoxManagedCreationRequest: Equatable, Sendable {
  static let defaultCPUCount = 4
  static let defaultMemoryBytes: UInt64 = 8 * VirtualMachineResources.bytesPerGiB
  static let defaultDiskBytes: UInt64 = 32 * VirtualMachineResources.bytesPerGiB

  let name: String
  let profile: LinuxBoxProfile
  let resources: VirtualMachineResources

  init(
    name: String,
    cpuCount: Int = Self.defaultCPUCount,
    memoryBytes: UInt64 = Self.defaultMemoryBytes,
    diskBytes: UInt64 = Self.defaultDiskBytes,
    profile: LinuxBoxProfile = .standard
  ) throws {
    self.name = name
    self.profile = profile
    resources = try VirtualMachineResources(
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      diskBytes: diskBytes
    )
  }
}

struct LinuxBoxManagedCreationResult: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
}

protocol LinuxBoxManagedCreationFailureInjecting: Sendable {
  func fail(after phase: LinuxBoxManagedCreationPhase) throws
}

struct NoLinuxBoxManagedCreationFailure: LinuxBoxManagedCreationFailureInjecting {
  func fail(after phase: LinuxBoxManagedCreationPhase) throws {}
}

enum LinuxBoxManagedCreationPhase: String, CaseIterable, Sendable {
  case staged
  case diskCopied
  case diskGrown
  case identityCreated
  case manifestWritten
  case resolverValidated
  case synchronized
  case committed
}

struct LinuxBoxManagedCreationService: @unchecked Sendable {
  private let rootURL: URL
  private let fileManager: FileManager
  private let bundleStore: VirtualMachineBundleStore
  private let resolver: LinuxVirtualMachineBundleResolver
  private let cache: any LinuxBoxImagePreparing
  private let identityGenerator: any LinuxVirtualMachineIdentityGenerating
  private let failureInjector: any LinuxBoxManagedCreationFailureInjecting

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    cache: any LinuxBoxImagePreparing,
    identityGenerator: any LinuxVirtualMachineIdentityGenerating = AppleLinuxVirtualMachineIdentityGenerator(),
    failureInjector: any LinuxBoxManagedCreationFailureInjecting = NoLinuxBoxManagedCreationFailure()
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    bundleStore = VirtualMachineBundleStore(rootURL: rootURL, fileManager: fileManager)
    resolver = LinuxVirtualMachineBundleResolver(rootURL: rootURL, fileManager: fileManager)
    self.cache = cache
    self.identityGenerator = identityGenerator
    self.failureInjector = failureInjector
  }

  func create(
    request: LinuxBoxManagedCreationRequest,
    image: LinuxBoxImageRecord,
    operationID: UUID = UUID()
  ) async throws -> LinuxBoxManagedCreationResult {
    guard image.logicalSizeBytes == 0
      || request.resources.diskBytes >= image.logicalSizeBytes
    else { throw LinuxBoxManagedCreationError.diskBelowTemplate }
    let cached = try await cache.prepare(image: image)
    let id = UUID()
    let finalURL = bundleStore.bundleURL(for: id)
    let stagingURL = bundleStore.managedCreationStagingDirectory(operationID: operationID)
    guard !fileManager.fileExists(atPath: stagingURL.path),
      !fileManager.fileExists(atPath: finalURL.path)
    else { throw LinuxBoxManagedCreationError.destinationExists }

    do {
      try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingURL.path)
      try failureInjector.fail(after: .staged)
      let diskURL = stagingURL.appending(path: "Disk.img")
      try copyTemplate(cached.templateURL, to: diskURL)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diskURL.path)
      try failureInjector.fail(after: .diskCopied)
      let disk = try FileHandle(forWritingTo: diskURL)
      try disk.truncate(atOffset: request.resources.diskBytes)
      try disk.synchronize()
      try disk.close()
      try failureInjector.fail(after: .diskGrown)

      let platformDirectory = stagingURL.appending(path: LinuxPlatformArtifactURLs.directoryName, directoryHint: .isDirectory)
      try fileManager.createDirectory(at: platformDirectory, withIntermediateDirectories: false)
      let machineIdentifier = identityGenerator.makeIdentifierData()
      let machineURL = platformDirectory.appending(path: LinuxPlatformArtifactURLs.machineIdentifierFilename)
      try machineIdentifier.write(to: machineURL, options: [.atomic])
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: machineURL.path)
      let nvramURL = platformDirectory.appending(path: LinuxPlatformArtifactURLs.efiVariableStoreFilename)
      _ = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nvramURL.path)
      let macAddress = identityGenerator.makeMACAddress()
      try failureInjector.fail(after: .identityCreated)

      var manifest = try VirtualMachineManifest(
        id: id,
        schemaVersion: VirtualMachineManifest.currentSchemaVersion,
        name: request.name,
        guest: .linux,
        installState: .stopped,
        resources: request.resources,
        diskImagePath: "Disk.img"
      )
      manifest.networkConfiguration = .nat
      manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
        efiVariableStorePath: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
        machineIdentifierPath: LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
        installationMediaPath: nil,
        macAddress: macAddress,
        sharesClipboard: false,
        linuxBoxDescriptor: try LinuxBoxDescriptor(
          imageID: image.imageID,
          imageBuildRevision: image.imageBuildRevision,
          rawImageSHA512: image.rawSHA512,
          profile: request.profile,
          guestAgentProtocolVersion: image.guestAgentProtocolVersion
        )
      )
      try manifest.validateSchema()
      try bundleStore.write(manifest, to: stagingURL.appending(path: VirtualMachineLibrary.manifestFilename))
      try failureInjector.fail(after: .manifestWritten)
      _ = try resolver.resolve(manifest, in: stagingURL)
      guard identityGenerator.isValidIdentifierData(machineIdentifier),
        identityGenerator.isValidMACAddress(macAddress)
      else { throw LinuxBoxManagedCreationError.invalidIdentity }
      try failureInjector.fail(after: .resolverValidated)
      try synchronizeTree(stagingURL)
      try synchronizeParent(rootURL)
      try failureInjector.fail(after: .synchronized)
      try Task.checkCancellation()
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      try? synchronizeParent(rootURL)
      try? failureInjector.fail(after: .committed)
      return LinuxBoxManagedCreationResult(manifest: manifest, bundleURL: finalURL)
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  private func copyTemplate(_ source: URL, to destination: URL) throws {
    let cloned = copyfile(
      source.path(percentEncoded: false),
      destination.path(percentEncoded: false),
      nil,
      copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL)
    ) == 0
    if cloned { return }
    let input = try FileHandle(forReadingFrom: source)
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      try? input.close()
      throw LinuxBoxManagedCreationError.diskCopyFailed
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? input.close(); try? output.close() }
    var offset: UInt64 = 0
    while let chunk = try input.read(upToCount: 1 * 1_024 * 1_024), !chunk.isEmpty {
      if chunk.contains(where: { $0 != 0 }) {
        try output.seek(toOffset: offset)
        try output.write(contentsOf: chunk)
      }
      offset += UInt64(chunk.count)
    }
    try output.truncate(atOffset: offset)
    try output.synchronize()
  }

  private func synchronizeTree(_ directory: URL) throws {
    let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    for entry in entries {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true { try synchronizeTree(entry) }
      else {
        let descriptor = Darwin.open(entry.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
          throw LinuxBoxManagedCreationError.syncFailed
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
          throw LinuxBoxManagedCreationError.syncFailed
        }
      }
    }
    try synchronizeParent(directory)
  }

  private func synchronizeParent(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw LinuxBoxManagedCreationError.syncFailed
    }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw LinuxBoxManagedCreationError.syncFailed
    }
  }
}

enum LinuxBoxManagedCreationError: LocalizedError, Equatable, Sendable {
  case unavailable, diskBelowTemplate, destinationExists, diskCopyFailed, invalidIdentity, syncFailed
  var errorDescription: String? {
    switch self {
    case .unavailable: "Managed Linux box creation is unavailable."
    case .diskBelowTemplate: "The managed Linux box disk is smaller than the prepared template."
    case .destinationExists: "The managed Linux box creation destination already exists."
    case .diskCopyFailed: "The managed Linux box template could not be copied."
    case .invalidIdentity: "The managed Linux box platform identity is invalid."
    case .syncFailed: "The managed Linux box staging transaction could not be synchronized."
    }
  }
}
