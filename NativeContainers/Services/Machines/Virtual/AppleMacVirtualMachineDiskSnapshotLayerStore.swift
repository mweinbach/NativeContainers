import Darwin
import DiskImageKit
import Foundation

protocol MacVirtualMachineDiskSnapshotLayerStoring: Sendable {
  func recoverUnreferencedLayers(
    in bundleURL: URL,
    configuration: MacVirtualMachineDiskSnapshotConfiguration
  ) throws

  func createLayer(
    _ layer: MacVirtualMachineDiskSnapshotLayer,
    baseURL: URL,
    retainedLayerURLs: [URL],
    targetLogicalBytes: UInt64,
    in bundleURL: URL
  ) throws -> URL

  func removeLayers(
    _ layers: [MacVirtualMachineDiskSnapshotLayer],
    in bundleURL: URL
  ) throws
}

struct AppleMacVirtualMachineDiskSnapshotLayerStore:
  MacVirtualMachineDiskSnapshotLayerStoring,
  @unchecked Sendable
{
  private static let stagingPrefix = ".Snapshot-"
  private static let stagingSuffix = ".asif.partial"

  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let fileManager: FileManager

  init(
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    fileManager: FileManager = .default
  ) {
    self.artifactInspector = artifactInspector
    self.fileManager = fileManager
  }

  func recoverUnreferencedLayers(
    in bundleURL: URL,
    configuration: MacVirtualMachineDiskSnapshotConfiguration
  ) throws {
    let directoryURL = snapshotDirectory(in: bundleURL)
    guard exists(directoryURL) else { return }
    try requireOwnedDirectory(directoryURL)

    let referencedNames = Set(
      configuration.layers.map {
        URL(filePath: $0.relativePath).lastPathComponent
      }
    )
    let entries = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )

    for entry in entries {
      let name = entry.lastPathComponent
      if referencedNames.contains(name) {
        _ = try inspectOwnedFile(at: entry)
      } else if Self.isOwnedLayerFilename(name)
        || Self.isStagingFilename(name)
      {
        try removeOwnedFile(at: entry)
      } else {
        throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(name)
      }
    }
    try synchronizeDirectory(directoryURL)
  }

  func createLayer(
    _ layer: MacVirtualMachineDiskSnapshotLayer,
    baseURL: URL,
    retainedLayerURLs: [URL],
    targetLogicalBytes: UInt64,
    in bundleURL: URL
  ) throws -> URL {
    guard #available(macOS 27.0, *) else {
      throw MacVirtualMachineDiskSnapshotError.unavailable
    }
    guard layer.isCanonical else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "a new layer has a noncanonical path"
      )
    }

    let directoryURL = snapshotDirectory(in: bundleURL)
    try ensureSnapshotDirectory(directoryURL, in: bundleURL)
    let destinationURL = bundleURL.appending(path: layer.relativePath)
    let stagingURL = directoryURL.appending(
      path: "\(Self.stagingPrefix)\(layer.id.uuidString)\(Self.stagingSuffix)"
    )
    try requireAbsent(destinationURL)
    try requireAbsent(stagingURL)

    do {
      try createOverlayStack(
        baseURL: baseURL,
        retainedLayerURLs: retainedLayerURLs,
        stagingURL: stagingURL,
        targetLogicalBytes: targetLogicalBytes
      )
      _ = try inspectOwnedFile(at: stagingURL)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: stagingURL.path
      )
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      try synchronizeDirectory(directoryURL)
      return destinationURL
    } catch {
      let operationError = error
      do {
        try removeOwnedFileIfPresent(at: stagingURL)
        try removeOwnedFileIfPresent(at: destinationURL)
        try synchronizeDirectory(directoryURL)
      } catch {
        throw MacVirtualMachineDiskSnapshotError.operationAndCleanupFailed(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      if let snapshotError = operationError
        as? MacVirtualMachineDiskSnapshotError
      {
        throw snapshotError
      }
      throw MacVirtualMachineDiskSnapshotError.layerCreationFailed(
        operationError.localizedDescription
      )
    }
  }

  func removeLayers(
    _ layers: [MacVirtualMachineDiskSnapshotLayer],
    in bundleURL: URL
  ) throws {
    guard !layers.isEmpty else { return }
    let directoryURL = snapshotDirectory(in: bundleURL)
    try requireOwnedDirectory(directoryURL)
    for layer in layers {
      guard layer.isCanonical else {
        throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
          "a retired layer has a noncanonical path"
        )
      }
      try removeOwnedFile(
        at: bundleURL.appending(path: layer.relativePath)
      )
    }
    try synchronizeDirectory(directoryURL)
  }

  @available(macOS 27.0, *)
  private func createOverlayStack(
    baseURL: URL,
    retainedLayerURLs: [URL],
    stagingURL: URL,
    targetLogicalBytes: UInt64
  ) throws {
    var image = try DiskImage(
      opening: .open(url: baseURL, mode: .readOnly)
    )
    for layerURL in retainedLayerURLs {
      let layer = try DiskImage(
        opening: .open(url: layerURL, mode: .readOnly)
      )
      image = try image.appending(layer)
    }
    guard let currentLogicalBytes = UInt64(exactly: image.size),
      let blockSizeBytes = UInt64(exactly: image.blockSize.rawValue),
      targetLogicalBytes >= currentLogicalBytes,
      targetLogicalBytes.isMultiple(of: blockSizeBytes),
      let targetBlockCount = Int(
        exactly: targetLogicalBytes / blockSizeBytes
      )
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "the requested active layer capacity is invalid"
      )
    }
    let stack = try image.appending(
      .asifLayer(
        url: stagingURL,
        type: .overlay(blockCount: targetBlockCount)
      )
    )
    guard stack.layers.count == retainedLayerURLs.count + 2,
      stack.layers.last?.url.standardizedFileURL
        == stagingURL.standardizedFileURL,
      stack.layers.last?.layerType == .overlay,
      stack.blockCount == targetBlockCount,
      UInt64(exactly: stack.size) == targetLogicalBytes
    else {
      throw MacVirtualMachineDiskSnapshotError.layerCreationFailed(
        "DiskImageKit returned an unexpected layer stack"
      )
    }
  }

  private func ensureSnapshotDirectory(
    _ directoryURL: URL,
    in bundleURL: URL
  ) throws {
    if exists(directoryURL) {
      try requireOwnedDirectory(directoryURL)
      return
    }
    guard errno == ENOENT else {
      throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
        directoryURL.lastPathComponent
      )
    }

    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try requireOwnedDirectory(directoryURL)
    try synchronizeDirectory(bundleURL)
  }

  private func snapshotDirectory(in bundleURL: URL) -> URL {
    bundleURL.appending(
      path: MacVirtualMachineDiskSnapshotLayer.directoryName,
      directoryHint: .isDirectory
    )
  }

  private func requireOwnedDirectory(_ url: URL) throws {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid()
    else {
      throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
        url.lastPathComponent
      )
    }
  }

  private func inspectOwnedFile(
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1
    else {
      throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    return identity
  }

  private func removeOwnedFileIfPresent(at url: URL) throws {
    guard exists(url) else {
      guard errno == ENOENT else {
        throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
          url.lastPathComponent
        )
      }
      return
    }
    try removeOwnedFile(at: url)
  }

  private func removeOwnedFile(at url: URL) throws {
    _ = try inspectOwnedFile(at: url)
    try fileManager.removeItem(at: url)
  }

  private func requireAbsent(_ url: URL) throws {
    guard !exists(url), errno == ENOENT else {
      throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
        url.lastPathComponent
      )
    }
  }

  private func exists(_ url: URL) -> Bool {
    var metadata = stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw MacVirtualMachineDiskSnapshotError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private static func isStagingFilename(_ name: String) -> Bool {
    name.hasPrefix(stagingPrefix) && name.hasSuffix(stagingSuffix)
  }

  private static func isOwnedLayerFilename(_ name: String) -> Bool {
    let url = URL(filePath: name)
    guard url.pathExtension == MacVirtualMachineDiskSnapshotLayer.fileExtension,
      let identifier = UUID(
        uuidString: url.deletingPathExtension().lastPathComponent
      )
    else {
      return false
    }
    return name
      == URL(
        filePath: MacVirtualMachineDiskSnapshotLayer.relativePath(
          for: identifier
        )
      ).lastPathComponent
  }
}
