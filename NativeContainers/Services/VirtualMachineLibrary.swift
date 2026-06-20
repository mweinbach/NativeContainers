import Foundation

protocol VirtualMachineLibraryProtocol: Sendable {
  func list() async throws -> [VirtualMachineManifest]
  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest
}

actor VirtualMachineLibrary: VirtualMachineLibraryProtocol {
  static let bundleExtension = "nativevm"
  static let manifestFilename = "manifest.json"

  private let rootURL: URL
  private let fileManager: FileManager

  init(rootURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
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

      let data = try Data(contentsOf: bundleURL.appending(path: Self.manifestFilename))
      let manifest = try Self.decoder.decode(VirtualMachineManifest.self, from: data)
      guard manifest.schemaVersion == VirtualMachineManifest.currentSchemaVersion else {
        throw VirtualMachineModelError.unsupportedSchema(manifest.schemaVersion)
      }
      return manifest
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

  private func ensureRootExists() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  private func bundleURL(for id: UUID) -> URL {
    rootURL
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(Self.bundleExtension)
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
