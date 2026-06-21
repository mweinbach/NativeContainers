import Foundation

struct VirtualMachineBundleStore {
  let rootURL: URL

  private let fileManager: FileManager

  init(rootURL: URL, fileManager: FileManager) {
    self.rootURL = rootURL
    self.fileManager = fileManager
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
      guard bundleURL.pathExtension == VirtualMachineLibrary.bundleExtension else { return nil }
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

  func manifest(id: UUID) throws -> VirtualMachineManifest {
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

  func readManifest(in bundleURL: URL) throws -> VirtualMachineManifest {
    let data = try Data(
      contentsOf: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename)
    )
    let manifest = try Self.decoder.decode(VirtualMachineManifest.self, from: data)
    guard manifest.schemaVersion == VirtualMachineManifest.currentSchemaVersion else {
      throw VirtualMachineModelError.unsupportedSchema(manifest.schemaVersion)
    }
    return manifest
  }

  func write(_ manifest: VirtualMachineManifest, to url: URL) throws {
    let data = try Self.encoder.encode(manifest)
    try data.write(to: url, options: [.atomic])
  }

  func ensureRootExists() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MacVirtualMachineInstallationError.invalidBundle(
        "installation workspace is missing or symbolic"
      )
    }
  }

  func createSparseDisk(at url: URL, size: UInt64) throws {
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: size)
  }

  func validatePreparedArtifacts(_ artifacts: MacPlatformArtifactURLs) throws {
    if let missingArtifact = firstMissingArtifact(in: artifacts.all) {
      throw MacPlatformArtifactError.missingArtifact(missingArtifact.lastPathComponent)
    }
  }

  func validatePreparedArtifacts(_ artifacts: LinuxPlatformArtifactURLs) throws {
    if let missingArtifact = firstMissingArtifact(in: artifacts.all) {
      throw LinuxPlatformArtifactError.missingArtifact(missingArtifact.lastPathComponent)
    }
  }

  func bundleURL(for id: UUID) -> URL {
    rootURL
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  func manifestURL(for id: UUID) -> URL {
    bundleURL(for: id).appending(path: VirtualMachineLibrary.manifestFilename)
  }

  func installationStagingDirectory(id: UUID, operationID: UUID) -> URL {
    bundleURL(for: id).appending(
      path:
        "\(VirtualMachineLibrary.installationStagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineLibrary.installationStagingSuffix)",
      directoryHint: .isDirectory
    )
  }

  func installationInstalledDirectory(id: UUID) -> URL {
    bundleURL(for: id).appending(
      path: VirtualMachineLibrary.installationInstalledDirectoryName,
      directoryHint: .isDirectory
    )
  }

  func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let directoryComponents = resolvedDirectory.pathComponents
    let candidateComponents = resolvedCandidate.pathComponents
    guard candidateComponents.count >= directoryComponents.count else { return false }
    return candidateComponents.prefix(directoryComponents.count)
      .elementsEqual(directoryComponents)
  }

  func removeRecoveryArtifacts() throws {
    try removeRootDirectories(
      prefix: VirtualMachineLibrary.deletionTombstonePrefix,
      suffix: VirtualMachineLibrary.deletionTombstoneSuffix
    )
    try removeRootDirectories(
      prefix: VirtualMachineLibrary.cloneStagingPrefix,
      suffix: VirtualMachineLibrary.cloneStagingSuffix
    )
    try removeRootDirectories(
      prefix: VirtualMachineLibrary.importStagingPrefix,
      suffix: VirtualMachineLibrary.importStagingSuffix
    )
  }

  func removeOrphanedInstallationStagingDirectories(id: UUID) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL(for: id),
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(VirtualMachineLibrary.installationStagingPrefix),
        name.hasSuffix(VirtualMachineLibrary.installationStagingSuffix)
      else {
        continue
      }
      try requireDirectory(entry)
      try fileManager.removeItem(at: entry)
    }
  }

  static func defaultRootURL(fileManager: FileManager) -> URL {
    let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return
      supportURL
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Virtual Machines", directoryHint: .isDirectory)
  }

  private func firstMissingArtifact(in artifacts: [URL]) -> URL? {
    artifacts.first { artifact in
      var isDirectory: ObjCBool = false
      return !fileManager.fileExists(atPath: artifact.path, isDirectory: &isDirectory)
        || isDirectory.boolValue
    }
  }

  private func removeRootDirectories(prefix: String, suffix: String) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
      try requireDirectory(entry)
      try fileManager.removeItem(at: entry)
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()
}
