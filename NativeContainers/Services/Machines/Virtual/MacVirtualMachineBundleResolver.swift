import Foundation

protocol MacVirtualMachineBundleResolving: Sendable {
  func resolve(_ manifest: VirtualMachineManifest) throws -> PreparedMacVirtualMachine
  func resolveRuntime(_ manifest: VirtualMachineManifest) throws -> ResolvedMacVirtualMachine
  func resolveArtifact(
    _ path: String,
    named name: String,
    in bundleURL: URL,
    writable: Bool
  ) throws -> URL
}

struct MacVirtualMachineBundleResolver: MacVirtualMachineBundleResolving, Sendable {
  private let rootURL: URL
  private let artifactResolver: VirtualMachineBundleArtifactResolver

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    artifactResolver = VirtualMachineBundleArtifactResolver(fileManager: fileManager)
  }

  func resolve(_ manifest: VirtualMachineManifest) throws -> PreparedMacVirtualMachine {
    let runtimeMachine = try resolveRuntime(manifest)

    guard let restoreImageURL = manifest.restoreImageURL else {
      throw MacVirtualMachineInstallationError.missingManifestValue("restoreImageURL")
    }
    guard restoreImageURL.isFileURL else {
      throw MacVirtualMachineInstallationError.invalidRestoreImage(restoreImageURL)
    }
    try requireRegularArtifact(
      restoreImageURL,
      name: restoreImageURL.lastPathComponent,
      in: restoreImageURL.deletingLastPathComponent()
    )

    return PreparedMacVirtualMachine(
      manifest: manifest,
      bundleURL: runtimeMachine.bundleURL,
      restoreImageURL: restoreImageURL.standardizedFileURL,
      diskImageURL: runtimeMachine.diskImageURL,
      auxiliaryStorageURL: runtimeMachine.auxiliaryStorageURL,
      hardwareModelURL: runtimeMachine.hardwareModelURL,
      machineIdentifierURL: runtimeMachine.machineIdentifierURL
    )
  }

  func resolveRuntime(_ manifest: VirtualMachineManifest) throws -> ResolvedMacVirtualMachine {
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(manifest.id)
    }
    guard manifest.linuxDiskSnapshotConfiguration == nil else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "Linux disk snapshot state is present"
      )
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
    let snapshotLayers =
      manifest.effectiveMacOSDiskSnapshotConfiguration.layers
    let diskSnapshotLayerURLs = try snapshotLayers.enumerated().map { index, layer in
      try resolveArtifact(
        layer.relativePath,
        named: "macOSDiskSnapshotConfiguration.layers[\(index)]",
        in: bundleURL,
        writable: index == snapshotLayers.indices.last
      )
    }
    let auxiliaryStorageURL = try resolveRequiredArtifact(
      manifest.auxiliaryStoragePath,
      named: "auxiliaryStoragePath",
      in: bundleURL,
      writable: true
    )
    let hardwareModelURL = try resolveRequiredArtifact(
      manifest.hardwareModelPath,
      named: "hardwareModelPath",
      in: bundleURL
    )
    let machineIdentifierURL = try resolveRequiredArtifact(
      manifest.machineIdentifierPath,
      named: "machineIdentifierPath",
      in: bundleURL
    )

    return ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      diskSnapshotLayerURLs: diskSnapshotLayerURLs,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL
    )
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

  private func resolveRequiredArtifact(
    _ path: String?,
    named name: String,
    in bundleURL: URL,
    writable: Bool = false
  ) throws -> URL {
    guard let path else {
      throw MacVirtualMachineInstallationError.missingManifestValue(name)
    }
    return try resolveArtifact(path, named: name, in: bundleURL, writable: writable)
  }

  private func requireBundleDirectory(_ bundleURL: URL) throws {
    do {
      try artifactResolver.requireBundleDirectory(bundleURL)
    } catch let error as VirtualMachineBundleArtifactResolutionError {
      throw map(error)
    }
  }

  private func requireRegularArtifact(_ url: URL, name: String, in directory: URL) throws {
    do {
      _ = try artifactResolver.resolve(
        url.lastPathComponent,
        named: name,
        in: directory
      )
    } catch let error as VirtualMachineBundleArtifactResolutionError {
      throw map(error)
    }
  }

  private func map(
    _ error: VirtualMachineBundleArtifactResolutionError
  ) -> MacVirtualMachineInstallationError {
    switch error {
    case .invalidBundle(let reason):
      .invalidBundle(reason)
    case .invalidArtifact(let name):
      .invalidArtifact(name)
    }
  }
}
