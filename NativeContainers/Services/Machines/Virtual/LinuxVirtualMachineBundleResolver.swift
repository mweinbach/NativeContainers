import Foundation

protocol LinuxVirtualMachineBundleResolving: Sendable {
  func resolve(_ manifest: VirtualMachineManifest) throws -> ResolvedLinuxVirtualMachine
  func resolveArtifact(
    _ path: String,
    named name: String,
    in bundleURL: URL,
    writable: Bool
  ) throws -> URL
}

struct LinuxVirtualMachineBundleResolver: LinuxVirtualMachineBundleResolving, Sendable {
  private let rootURL: URL
  private let artifactResolver: VirtualMachineBundleArtifactResolver
  private let windowsGuestToolsCache: WindowsGuestToolsCache

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    windowsGuestToolsCache: WindowsGuestToolsCache = WindowsGuestToolsCache()
  ) {
    self.rootURL = rootURL.standardizedFileURL
    artifactResolver = VirtualMachineBundleArtifactResolver(fileManager: fileManager)
    self.windowsGuestToolsCache = windowsGuestToolsCache
  }

  func resolve(_ manifest: VirtualMachineManifest) throws -> ResolvedLinuxVirtualMachine {
    guard manifest.guest == .linux || manifest.guest == .windows else {
      throw VirtualMachineModelError.requiresLinuxGuest(manifest.id)
    }
    guard manifest.macOSDiskSnapshotConfiguration == nil else {
      throw LinuxVirtualMachineError.invalidBundle(
        "macOS disk snapshot state is present"
      )
    }
    let efiVariableStorePath: String
    let machineIdentifierPath: String
    let installationMediaPath: String?
    let setupConfigurationMediaPath: String?
    let guestAgentSecretPath: String?
    switch manifest.guest {
    case .linux:
      guard let configuration = manifest.linuxConfiguration else {
        throw LinuxVirtualMachineError.missingManifestValue("linuxConfiguration")
      }
      efiVariableStorePath = configuration.efiVariableStorePath
      machineIdentifierPath = configuration.machineIdentifierPath
      installationMediaPath = configuration.installationMediaPath
      setupConfigurationMediaPath = nil
      guestAgentSecretPath = nil
    case .windows:
      guard let configuration = manifest.windowsConfiguration else {
        throw WindowsVirtualMachineError.missingManifestValue("windowsConfiguration")
      }
      efiVariableStorePath = configuration.efiVariableStorePath
      machineIdentifierPath = configuration.machineIdentifierPath
      installationMediaPath = configuration.installationMediaPath
      setupConfigurationMediaPath = configuration.setupConfigurationMediaPath
      guestAgentSecretPath = configuration.guestAgentSecretPath
    case .macOS:
      throw VirtualMachineModelError.requiresLinuxGuest(manifest.id)
    }

    let bundleURL =
      rootURL
      .appending(path: manifest.id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
      .standardizedFileURL
    try requireBundleDirectory(bundleURL)

    let diskImageURL = try resolveArtifact(
      manifest.diskImagePath,
      named: "diskImagePath",
      in: bundleURL,
      writable: true
    )
    let snapshotLayers = manifest.effectiveDiskSnapshotConfiguration.layers
    let diskSnapshotLayerURLs = try snapshotLayers.enumerated().map { index, layer in
      try resolveArtifact(
        layer.relativePath,
        named: "linuxDiskSnapshotConfiguration.layers[\(index)]",
        in: bundleURL,
        writable: index == snapshotLayers.indices.last
      )
    }
    let efiVariableStoreURL = try resolveArtifact(
      efiVariableStorePath,
      named: "efiVariableStorePath",
      in: bundleURL,
      writable: true
    )
    let machineIdentifierURL = try resolveArtifact(
      machineIdentifierPath,
      named: "machineIdentifierPath",
      in: bundleURL
    )
    let installationMediaURL = try installationMediaPath.map {
      try resolveArtifact(
        $0,
        named: "installationMediaPath",
        in: bundleURL
      )
    }
    let setupConfigurationMediaURL = try setupConfigurationMediaPath.map {
      try resolveArtifact(
        $0,
        named: "setupConfigurationMediaPath",
        in: bundleURL
      )
    }
    let guestAgentSecretURL = try guestAgentSecretPath.map {
      try resolveArtifact(
        $0,
        named: "guestAgentSecretPath",
        in: bundleURL
      )
    }
    let guestToolsMediaURL: URL?
    if let configuration = manifest.windowsConfiguration,
      configuration.guestToolsMediaAttached,
      let release = configuration.guestTools
    {
      guestToolsMediaURL = try windowsGuestToolsCache.resolve(release)
    } else {
      guestToolsMediaURL = nil
    }

    return ResolvedLinuxVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: diskSnapshotLayerURLs,
      efiVariableStoreURL: efiVariableStoreURL,
      machineIdentifierURL: machineIdentifierURL,
      installationMediaURL: installationMediaURL,
      setupConfigurationMediaURL: setupConfigurationMediaURL,
      guestAgentSecretURL: guestAgentSecretURL,
      guestToolsMediaURL: guestToolsMediaURL
    )
  }

  private func requireBundleDirectory(_ bundleURL: URL) throws {
    do {
      try artifactResolver.requireBundleDirectory(bundleURL)
    } catch let error as VirtualMachineBundleArtifactResolutionError {
      throw map(error)
    }
  }

  func resolveArtifact(
    _ path: String,
    named name: String,
    in bundleURL: URL,
    writable: Bool = false
  ) throws -> URL {
    do {
      return try artifactResolver.resolve(
        path,
        named: name,
        in: bundleURL,
        writable: writable
      )
    } catch let error as VirtualMachineBundleArtifactResolutionError {
      throw map(error)
    }
  }

  private func map(
    _ error: VirtualMachineBundleArtifactResolutionError
  ) -> LinuxVirtualMachineError {
    switch error {
    case .invalidBundle(let reason):
      .invalidBundle(reason)
    case .invalidArtifact(let name):
      .invalidArtifact(name)
    }
  }
}
