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

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    artifactResolver = VirtualMachineBundleArtifactResolver(fileManager: fileManager)
  }

  func resolve(_ manifest: VirtualMachineManifest) throws -> ResolvedLinuxVirtualMachine {
    guard manifest.guest == .linux else {
      throw VirtualMachineModelError.requiresLinuxGuest(manifest.id)
    }
    guard let linuxConfiguration = manifest.linuxConfiguration else {
      throw LinuxVirtualMachineError.missingManifestValue("linuxConfiguration")
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
    let efiVariableStoreURL = try resolveArtifact(
      linuxConfiguration.efiVariableStorePath,
      named: "efiVariableStorePath",
      in: bundleURL,
      writable: true
    )
    let machineIdentifierURL = try resolveArtifact(
      linuxConfiguration.machineIdentifierPath,
      named: "machineIdentifierPath",
      in: bundleURL
    )
    let installationMediaURL = try linuxConfiguration.installationMediaPath.map {
      try resolveArtifact(
        $0,
        named: "installationMediaPath",
        in: bundleURL
      )
    }

    return ResolvedLinuxVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      efiVariableStoreURL: efiVariableStoreURL,
      machineIdentifierURL: machineIdentifierURL,
      installationMediaURL: installationMediaURL
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
