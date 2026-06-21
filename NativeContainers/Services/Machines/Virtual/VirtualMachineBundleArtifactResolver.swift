import Foundation

enum VirtualMachineBundleArtifactResolutionError: LocalizedError, Equatable {
  case invalidBundle(String)
  case invalidArtifact(String)

  var errorDescription: String? {
    switch self {
    case .invalidBundle(let reason):
      "The virtual machine bundle is invalid: \(reason)."
    case .invalidArtifact(let name):
      "The virtual machine bundle contains an invalid \(name) artifact."
    }
  }
}

struct VirtualMachineBundleArtifactResolver: @unchecked Sendable {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func requireBundleDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw VirtualMachineBundleArtifactResolutionError.invalidBundle(
        "the expected bundle directory is missing or symbolic"
      )
    }
  }

  func resolve(
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
      throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
    }

    let candidate = bundleURL.appending(path: path).standardizedFileURL
    guard isStrictDescendant(candidate, of: bundleURL) else {
      throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
    }

    try requireRegularFile(candidate, name: name)
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    guard isStrictDescendant(resolvedCandidate, of: resolvedBundle) else {
      throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
    }
    if writable, !fileManager.isWritableFile(atPath: candidate.path) {
      throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
    }
    return candidate
  }

  private func requireRegularFile(_ url: URL, name: String) throws {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
      }
    } catch let error as VirtualMachineBundleArtifactResolutionError {
      throw error
    } catch {
      throw VirtualMachineBundleArtifactResolutionError.invalidArtifact(name)
    }
  }

  private func isStrictDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let directoryComponents = directory.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    guard candidateComponents.count > directoryComponents.count else { return false }
    return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
  }
}
