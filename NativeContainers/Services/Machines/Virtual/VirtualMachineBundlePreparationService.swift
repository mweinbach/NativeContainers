import Darwin
import Foundation

protocol VirtualMachineBundlePreparing: Sendable {
  func prepare(_ request: VirtualMachineBundlePreparationRequest) async throws
}

protocol VirtualMachineBundleInspecting: Sendable {
  func snapshot(of bundleURL: URL) throws -> VirtualMachineBundleSnapshot
}

protocol VirtualMachineBundleSanitizing: Sendable {
  func sanitize(
    bundleURL: URL,
    portability: VirtualMachineBundlePortability
  ) throws
}

struct VirtualMachineBundleSnapshot: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    let relativePath: String
    let fileType: UInt16
    let byteCount: Int64
    let device: UInt64
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
  }

  let entries: [Entry]
}

struct VirtualMachineBundlePreparationService:
  VirtualMachineBundlePreparing,
  @unchecked Sendable
{
  private let transfer: any VirtualMachineBundleTransferring
  private let inspector: any VirtualMachineBundleInspecting
  private let sanitizer: any VirtualMachineBundleSanitizing
  private let machineIdentifierGenerator: any MacVirtualMachineIdentifierGenerating
  private let linuxIdentityGenerator: any LinuxVirtualMachineIdentityGenerating
  private let artifactResolver: VirtualMachineBundleArtifactResolver
  private let fileManager: FileManager

  init(
    transfer: any VirtualMachineBundleTransferring = CopyfileVirtualMachineBundleTransfer(),
    inspector: any VirtualMachineBundleInspecting = FileVirtualMachineBundleInspector(),
    sanitizer: any VirtualMachineBundleSanitizing = FileVirtualMachineBundleSanitizer(),
    machineIdentifierGenerator: any MacVirtualMachineIdentifierGenerating =
      AppleMacVirtualMachineIdentifierGenerator(),
    linuxIdentityGenerator: any LinuxVirtualMachineIdentityGenerating =
      AppleLinuxVirtualMachineIdentityGenerator(),
    fileManager: FileManager = .default
  ) {
    self.transfer = transfer
    self.inspector = inspector
    self.sanitizer = sanitizer
    self.machineIdentifierGenerator = machineIdentifierGenerator
    self.linuxIdentityGenerator = linuxIdentityGenerator
    self.artifactResolver = VirtualMachineBundleArtifactResolver(fileManager: fileManager)
    self.fileManager = fileManager
  }

  func prepare(_ request: VirtualMachineBundlePreparationRequest) async throws {
    try Task.checkCancellation()
    let sourceSnapshot = try inspector.snapshot(of: request.sourceBundleURL)
    try requireNoDiskImageReplacementArtifacts(in: sourceSnapshot)
    try validateGuestManifestState(request)
    try requireNoGuestIncompatibleArtifacts(
      in: sourceSnapshot,
      guest: request.sourceManifest.guest
    )
    try await transfer.copyBundle(
      from: request.sourceBundleURL,
      to: request.destinationBundleURL
    )
    try Task.checkCancellation()

    let currentSnapshot = try inspector.snapshot(of: request.sourceBundleURL)
    guard currentSnapshot == sourceSnapshot else {
      throw VirtualMachineBundleError.sourceChanged
    }

    _ = try inspector.snapshot(of: request.destinationBundleURL)
    try sanitizer.sanitize(
      bundleURL: request.destinationBundleURL,
      portability: request.portability
    )
    try applyIdentityPolicy(request)
    try write(request.destinationManifest, to: request.destinationBundleURL)
    _ = try inspector.snapshot(of: request.destinationBundleURL)
    try Task.checkCancellation()
  }

  private func requireNoDiskImageReplacementArtifacts(
    in snapshot: VirtualMachineBundleSnapshot
  ) throws {
    guard
      !snapshot.entries.contains(where: {
        VirtualMachineDiskImageReplacementArtifacts.isControlArtifact(
          relativePath: $0.relativePath
        )
      })
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "disk-image replacement data is pending recovery"
      )
    }
  }

  private func applyIdentityPolicy(
    _ request: VirtualMachineBundlePreparationRequest
  ) throws {
    guard request.sourceManifest.guest == request.destinationManifest.guest else {
      throw VirtualMachineBundleError.invalidBundle(
        "the source and destination guest types do not match"
      )
    }
    try validateNetworkIdentityPolicy(request)

    let sourceIdentifierURL = try machineIdentifierURL(
      manifest: request.sourceManifest,
      bundleURL: request.sourceBundleURL,
      writable: false
    )
    let destinationIdentifierURL = try machineIdentifierURL(
      manifest: request.destinationManifest,
      bundleURL: request.destinationBundleURL,
      writable: request.identityPolicy == .regenerate
    )
    let sourceIdentifier = try Data(contentsOf: sourceIdentifierURL)

    switch request.identityPolicy {
    case .preserve:
      let destinationIdentifier = try Data(contentsOf: destinationIdentifierURL)
      guard destinationIdentifier == sourceIdentifier,
        isValidIdentifierData(destinationIdentifier, guest: request.destinationManifest.guest)
      else {
        throw VirtualMachineBundleError.invalidMachineIdentifier
      }
    case .regenerate:
      let identifier = try makeIdentifierData(guest: request.destinationManifest.guest)
      guard identifier != sourceIdentifier,
        isValidIdentifierData(identifier, guest: request.destinationManifest.guest)
      else {
        throw VirtualMachineBundleError.duplicateMachineIdentifier
      }
      try identifier.write(to: destinationIdentifierURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destinationIdentifierURL.path
      )
      let persisted = try Data(contentsOf: destinationIdentifierURL)
      guard persisted == identifier,
        isValidIdentifierData(persisted, guest: request.destinationManifest.guest)
      else {
        throw VirtualMachineBundleError.invalidMachineIdentifier
      }
    }
  }

  private func validateGuestManifestState(
    _ request: VirtualMachineBundlePreparationRequest
  ) throws {
    for manifest in [request.sourceManifest, request.destinationManifest] {
      do {
        try VirtualMachineComputeState.validatePersistedRequirements(
          in: manifest
        )
      } catch {
        throw VirtualMachineBundleError.invalidBundle(
          error.localizedDescription
        )
      }
    }

    guard request.sourceManifest.guest == .linux else { return }
    for manifest in [request.sourceManifest, request.destinationManifest] {
      guard let configuration = manifest.linuxConfiguration,
        configuration.installationMediaPath == nil,
        manifest.auxiliaryStoragePath == nil,
        manifest.hardwareModelPath == nil,
        manifest.machineIdentifierPath == nil,
        manifest.restoreImageURL == nil,
        manifest.audioConfiguration == nil,
        manifest.macOSGuestOperatingSystem == nil,
        manifest.macOSMinimumCPUCount == nil,
        manifest.macOSMinimumMemoryBytes == nil,
        manifest.macOSFirstBootState == nil,
        !manifest.effectiveMacOSDiskSnapshotConfiguration.hasSnapshots
      else {
        throw VirtualMachineBundleError.invalidBundle(
          "the Linux manifest contains incomplete or guest-incompatible state"
        )
      }
    }

    switch request.portability {
    case .sameHost:
      guard
        request.destinationManifest.networkConfiguration
          == request.sourceManifest.networkConfiguration
      else {
        throw VirtualMachineBundleError.invalidBundle(
          "the same-host Linux copy changed its network configuration"
        )
      }
    case .portable:
      guard request.destinationManifest.networkConfiguration == nil else {
        throw VirtualMachineBundleError.invalidBundle(
          "host-local Linux network configuration remains in the portable manifest"
        )
      }
    }
  }

  private func requireNoGuestIncompatibleArtifacts(
    in snapshot: VirtualMachineBundleSnapshot,
    guest: VirtualMachineGuest
  ) throws {
    guard guest == .linux else { return }
    let snapshotDirectory = MacVirtualMachineDiskSnapshotLayer.directoryName
    guard
      !snapshot.entries.contains(where: {
        $0.relativePath == snapshotDirectory
          || $0.relativePath.hasPrefix("\(snapshotDirectory)/")
      })
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "macOS disk snapshot data is present in the Linux bundle"
      )
    }
  }

  private func validateNetworkIdentityPolicy(
    _ request: VirtualMachineBundlePreparationRequest
  ) throws {
    guard request.sourceManifest.guest == .linux else { return }
    guard let source = request.sourceManifest.linuxConfiguration,
      let destination = request.destinationManifest.linuxConfiguration,
      linuxIdentityGenerator.isValidMACAddress(source.macAddress),
      linuxIdentityGenerator.isValidMACAddress(destination.macAddress)
    else {
      throw VirtualMachineBundleError.invalidMACAddress
    }

    switch request.identityPolicy {
    case .preserve:
      guard destination.macAddress.caseInsensitiveCompare(source.macAddress) == .orderedSame
      else {
        throw VirtualMachineBundleError.invalidMACAddress
      }
    case .regenerate:
      guard destination.macAddress.caseInsensitiveCompare(source.macAddress) != .orderedSame
      else {
        throw VirtualMachineBundleError.duplicateMACAddress
      }
    }
  }

  private func makeIdentifierData(guest: VirtualMachineGuest) throws -> Data {
    switch guest {
    case .macOS:
      try machineIdentifierGenerator.makeIdentifierData()
    case .linux:
      linuxIdentityGenerator.makeIdentifierData()
    }
  }

  private func isValidIdentifierData(
    _ data: Data,
    guest: VirtualMachineGuest
  ) -> Bool {
    switch guest {
    case .macOS:
      machineIdentifierGenerator.isValidIdentifierData(data)
    case .linux:
      linuxIdentityGenerator.isValidIdentifierData(data)
    }
  }

  private func machineIdentifierURL(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    writable: Bool
  ) throws -> URL {
    let path =
      switch manifest.guest {
      case .macOS:
        manifest.machineIdentifierPath
      case .linux:
        manifest.linuxConfiguration?.machineIdentifierPath
      }
    guard let path else {
      throw VirtualMachineBundleError.invalidBundle(
        "the manifest has no machine identifier path"
      )
    }
    do {
      return try artifactResolver.resolve(
        path,
        named: "machineIdentifierPath",
        in: bundleURL,
        writable: writable
      )
    } catch {
      throw VirtualMachineBundleError.invalidBundle(error.localizedDescription)
    }
  }

  private func write(
    _ manifest: VirtualMachineManifest,
    to bundleURL: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename),
      options: .atomic
    )
  }
}

struct FileVirtualMachineBundleInspector:
  VirtualMachineBundleInspecting,
  @unchecked Sendable
{
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func snapshot(of bundleURL: URL) throws -> VirtualMachineBundleSnapshot {
    var entries: [VirtualMachineBundleSnapshot.Entry] = []
    let root = bundleURL.standardizedFileURL
    try appendEntry(at: root, relativePath: ".", entries: &entries)
    return VirtualMachineBundleSnapshot(
      entries: entries.sorted { $0.relativePath < $1.relativePath }
    )
  }

  private func appendEntry(
    at url: URL,
    relativePath: String,
    entries: inout [VirtualMachineBundleSnapshot.Entry]
  ) throws {
    if Task.isCancelled {
      throw CancellationError()
    }

    var metadata = stat()
    guard Darwin.lstat(url.nativeContainersPOSIXPath, &metadata) == 0 else {
      throw VirtualMachineBundleError.invalidBundle(
        "\(relativePath) cannot be inspected safely"
      )
    }
    let type = metadata.st_mode & mode_t(S_IFMT)
    guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
      throw VirtualMachineBundleError.invalidBundle(
        "\(relativePath) is a link or special file"
      )
    }
    if type == mode_t(S_IFREG), metadata.st_nlink != 1 {
      throw VirtualMachineBundleError.invalidBundle(
        "\(relativePath) is hard linked"
      )
    }

    entries.append(
      VirtualMachineBundleSnapshot.Entry(
        relativePath: relativePath,
        fileType: UInt16(type),
        byteCount: metadata.st_size,
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
      )
    )

    guard type == mode_t(S_IFDIR) else { return }
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: []
      )
    } catch {
      throw VirtualMachineBundleError.invalidBundle(
        "\(relativePath) cannot be enumerated"
      )
    }
    for child in children {
      let childPath =
        relativePath == "."
        ? child.lastPathComponent
        : "\(relativePath)/\(child.lastPathComponent)"
      try appendEntry(at: child, relativePath: childPath, entries: &entries)
    }
  }
}

struct FileVirtualMachineBundleSanitizer:
  VirtualMachineBundleSanitizing,
  @unchecked Sendable
{
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func sanitize(
    bundleURL: URL,
    portability: VirtualMachineBundlePortability
  ) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries
    where isTransient(entry.lastPathComponent)
      || (portability == .portable
        && entry.lastPathComponent
          == FileVirtualMachineSharedDirectoryConfigurationStore.filename)
    {
      try fileManager.removeItem(at: entry)
    }
  }

  private func isTransient(_ name: String) -> Bool {
    name == VirtualMachineLibrary.runtimeLockFilename
      || name == VirtualMachineLibrary.runtimeOwnerFilename
      || name == MacVirtualMachineSavedStateStore.directoryName
      || name.hasPrefix(VirtualMachineLibrary.installationStagingPrefix)
      || name.hasPrefix(MacVirtualMachineSavedStateStore.stagingPrefix)
  }
}
