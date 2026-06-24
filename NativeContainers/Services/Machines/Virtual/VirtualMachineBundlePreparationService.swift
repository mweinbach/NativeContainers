import Darwin
import Foundation
import Security

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
    try requireNoDiskImageMaintenanceArtifacts(in: sourceSnapshot)
    try validateGuestManifestState(request)
    try validateDiskSnapshotArtifacts(
      in: sourceSnapshot,
      manifest: request.sourceManifest
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
    try applyWindowsGuestAgentIdentityPolicy(request)
    try write(request.destinationManifest, to: request.destinationBundleURL)
    _ = try inspector.snapshot(of: request.destinationBundleURL)
    try Task.checkCancellation()
  }

  private func requireNoDiskImageMaintenanceArtifacts(
    in snapshot: VirtualMachineBundleSnapshot
  ) throws {
    guard
      !snapshot.entries.contains(where: {
        VirtualMachineDiskImageReplacementArtifacts.isControlArtifact(
          relativePath: $0.relativePath
        )
          || VirtualMachineDiskImageResizeArtifacts.isControlArtifact(
            relativePath: $0.relativePath
          )
      })
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "virtual disk maintenance is pending recovery"
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

    guard
      request.destinationManifest.effectiveDiskSnapshotConfiguration
        == request.sourceManifest.effectiveDiskSnapshotConfiguration
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "the copied manifest changed its disk snapshot history"
      )
    }

    switch request.sourceManifest.guest {
    case .macOS:
      guard request.sourceManifest.linuxDiskSnapshotConfiguration == nil,
        request.destinationManifest.linuxDiskSnapshotConfiguration == nil,
        request.sourceManifest.windowsDiskSnapshotConfiguration == nil,
        request.destinationManifest.windowsDiskSnapshotConfiguration == nil,
        request.sourceManifest.windowsConfiguration == nil,
        request.destinationManifest.windowsConfiguration == nil
      else {
        throw VirtualMachineBundleError.invalidBundle(
          "the macOS manifest contains state for another guest type"
        )
      }
    case .linux:
      for manifest in [request.sourceManifest, request.destinationManifest] {
        guard let configuration = manifest.linuxConfiguration,
          configuration.installationMediaPath == nil,
          manifest.windowsConfiguration == nil,
          manifest.windowsDiskSnapshotConfiguration == nil,
          hasNoMacOSOnlyState(manifest)
        else {
          throw VirtualMachineBundleError.invalidBundle(
            "the Linux manifest contains incomplete or guest-incompatible state"
          )
        }
      }
    case .windows:
      for manifest in [request.sourceManifest, request.destinationManifest] {
        guard let configuration = manifest.windowsConfiguration,
          configuration.installationMediaPath == nil,
          configuration.setupConfigurationMediaPath == nil,
          manifest.linuxConfiguration == nil,
          manifest.linuxDiskSnapshotConfiguration == nil,
          hasNoMacOSOnlyState(manifest)
        else {
          throw VirtualMachineBundleError.invalidBundle(
            "the Windows manifest contains incomplete or guest-incompatible state"
          )
        }
      }
    }

    switch request.portability {
    case .sameHost:
      guard
        request.destinationManifest.networkConfiguration
          == request.sourceManifest.networkConfiguration
      else {
        throw VirtualMachineBundleError.invalidBundle(
          "the same-host VM copy changed its network configuration"
        )
      }
    case .portable:
      guard request.destinationManifest.networkConfiguration == nil else {
        throw VirtualMachineBundleError.invalidBundle(
          "host-local VM network configuration remains in the portable manifest"
        )
      }
    }
  }

  private func hasNoMacOSOnlyState(_ manifest: VirtualMachineManifest) -> Bool {
    manifest.auxiliaryStoragePath == nil
      && manifest.hardwareModelPath == nil
      && manifest.machineIdentifierPath == nil
      && manifest.restoreImageURL == nil
      && manifest.audioConfiguration == nil
      && manifest.macOSGuestOperatingSystem == nil
      && manifest.macOSMinimumCPUCount == nil
      && manifest.macOSMinimumMemoryBytes == nil
      && manifest.macOSFirstBootState == nil
      && manifest.macOSDiskSnapshotConfiguration == nil
  }

  private func validateDiskSnapshotArtifacts(
    in snapshot: VirtualMachineBundleSnapshot,
    manifest: VirtualMachineManifest
  ) throws {
    let directory = VirtualMachineDiskSnapshotLayer.directoryName
    let snapshotEntries = snapshot.entries.filter {
      $0.relativePath == directory
        || $0.relativePath.hasPrefix("\(directory)/")
    }
    let expectedPaths = Set(
      manifest.effectiveDiskSnapshotConfiguration.layers.map(\.relativePath)
    )

    guard !expectedPaths.isEmpty else {
      guard snapshotEntries.isEmpty else {
        throw VirtualMachineBundleError.invalidBundle(
          "unreferenced disk snapshot data is present in the bundle"
        )
      }
      return
    }

    guard
      snapshotEntries.contains(where: {
        $0.relativePath == directory && $0.fileType == UInt16(S_IFDIR)
      })
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "the disk snapshot directory is missing or unsafe"
      )
    }
    let layerEntries = snapshotEntries.filter { $0.relativePath != directory }
    guard Set(layerEntries.map(\.relativePath)) == expectedPaths,
      layerEntries.allSatisfy({ $0.fileType == UInt16(S_IFREG) })
    else {
      throw VirtualMachineBundleError.invalidBundle(
        "the disk snapshot artifacts do not match the manifest"
      )
    }
  }

  private func validateNetworkIdentityPolicy(
    _ request: VirtualMachineBundlePreparationRequest
  ) throws {
    let sourceAddress: String?
    let destinationAddress: String?
    switch request.sourceManifest.guest {
    case .macOS:
      return
    case .linux:
      sourceAddress = request.sourceManifest.linuxConfiguration?.macAddress
      destinationAddress = request.destinationManifest.linuxConfiguration?.macAddress
    case .windows:
      sourceAddress = request.sourceManifest.windowsConfiguration?.macAddress
      destinationAddress = request.destinationManifest.windowsConfiguration?.macAddress
    }
    guard let sourceAddress, let destinationAddress,
      linuxIdentityGenerator.isValidMACAddress(sourceAddress),
      linuxIdentityGenerator.isValidMACAddress(destinationAddress)
    else {
      throw VirtualMachineBundleError.invalidMACAddress
    }

    switch request.identityPolicy {
    case .preserve:
      guard destinationAddress.caseInsensitiveCompare(sourceAddress) == .orderedSame
      else {
        throw VirtualMachineBundleError.invalidMACAddress
      }
    case .regenerate:
      guard destinationAddress.caseInsensitiveCompare(sourceAddress) != .orderedSame
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
    case .windows:
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
    case .windows:
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
      case .windows:
        manifest.windowsConfiguration?.machineIdentifierPath
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

  private func applyWindowsGuestAgentIdentityPolicy(
    _ request: VirtualMachineBundlePreparationRequest
  ) throws {
    guard request.sourceManifest.guest == .windows,
      let sourcePath = request.sourceManifest.windowsConfiguration?.guestAgentSecretPath,
      let destinationPath =
        request.destinationManifest.windowsConfiguration?.guestAgentSecretPath
    else {
      return
    }
    let sourceURL = try artifactResolver.resolve(
      sourcePath,
      named: "guestAgentSecretPath",
      in: request.sourceBundleURL,
      writable: false
    )
    let destinationURL = try artifactResolver.resolve(
      destinationPath,
      named: "guestAgentSecretPath",
      in: request.destinationBundleURL,
      writable: request.identityPolicy == .regenerate
    )
    let sourceSecret = try Data(contentsOf: sourceURL)
    guard sourceSecret.count == 32 else {
      throw VirtualMachineBundleError.invalidBundle(
        "the Windows guest-agent secret is invalid"
      )
    }

    switch request.identityPolicy {
    case .preserve:
      guard try Data(contentsOf: destinationURL) == sourceSecret else {
        throw VirtualMachineBundleError.invalidBundle(
          "the Windows guest-agent secret changed unexpectedly"
        )
      }
    case .regenerate:
      var secret = Data(count: 32)
      let status = secret.withUnsafeMutableBytes { bytes in
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
      }
      guard status == errSecSuccess, secret != sourceSecret else {
        throw VirtualMachineBundleError.invalidBundle(
          "a fresh Windows guest-agent secret could not be generated"
        )
      }
      try secret.write(to: destinationURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destinationURL.path
      )
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
