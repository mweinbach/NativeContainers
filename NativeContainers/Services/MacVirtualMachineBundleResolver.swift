import Foundation

protocol MacVirtualMachineBundleResolving: Sendable {
  func resolve(_ manifest: VirtualMachineManifest) throws -> PreparedMacVirtualMachine
}

struct MacVirtualMachineBundleResolver: MacVirtualMachineBundleResolving, @unchecked Sendable {
  private let rootURL: URL
  private let fileManager: FileManager

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
  }

  func resolve(_ manifest: VirtualMachineManifest) throws -> PreparedMacVirtualMachine {
    guard manifest.guest == .macOS else {
      throw VirtualMachineModelError.requiresMacOSGuest(manifest.id)
    }

    let bundleURL =
      rootURL
      .appending(path: manifest.id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
      .standardizedFileURL

    try requireDirectory(bundleURL)

    guard let restoreImageURL = manifest.restoreImageURL else {
      throw MacVirtualMachineInstallationError.missingManifestValue("restoreImageURL")
    }
    guard restoreImageURL.isFileURL else {
      throw MacVirtualMachineInstallationError.invalidRestoreImage(restoreImageURL)
    }
    try requireRegularFile(restoreImageURL, name: restoreImageURL.lastPathComponent)

    let diskImageURL = try resolveArtifact(
      manifest.diskImagePath,
      named: "diskImagePath",
      in: bundleURL,
      writable: true
    )
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

    return PreparedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      restoreImageURL: restoreImageURL.standardizedFileURL,
      diskImageURL: diskImageURL,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL
    )
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

  private func resolveArtifact(
    _ path: String,
    named name: String,
    in bundleURL: URL,
    writable: Bool = false
  ) throws -> URL {
    let pathComponents = NSString(string: path).pathComponents
    guard !NSString(string: path).isAbsolutePath,
      !pathComponents.isEmpty,
      !pathComponents.contains(".."),
      pathComponents.allSatisfy({ $0 != "/" && $0 != "." })
    else {
      throw MacVirtualMachineInstallationError.invalidArtifact(name)
    }

    let candidate = bundleURL.appending(path: path).standardizedFileURL
    guard isStrictDescendant(candidate, of: bundleURL) else {
      throw MacVirtualMachineInstallationError.invalidArtifact(name)
    }

    try requireRegularFile(candidate, name: name)
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    guard isStrictDescendant(resolvedCandidate, of: resolvedBundle) else {
      throw MacVirtualMachineInstallationError.invalidArtifact(name)
    }
    if writable, !fileManager.isWritableFile(atPath: candidate.path) {
      throw MacVirtualMachineInstallationError.invalidArtifact(name)
    }
    return candidate
  }

  private func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "the expected bundle directory is missing or symbolic"
      )
    }
  }

  private func requireRegularFile(_ url: URL, name: String) throws {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw MacVirtualMachineInstallationError.invalidArtifact(name)
      }
    } catch let error as MacVirtualMachineInstallationError {
      throw error
    } catch {
      throw MacVirtualMachineInstallationError.invalidArtifact(name)
    }
  }

  private func isStrictDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let directoryComponents = directory.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    guard candidateComponents.count > directoryComponents.count else { return false }
    return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
  }
}
