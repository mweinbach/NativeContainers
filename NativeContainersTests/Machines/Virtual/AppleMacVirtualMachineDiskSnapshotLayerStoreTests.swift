import DiskImageKit
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple macOS virtual machine disk snapshot layer store")
struct AppleMacVirtualMachineDiskSnapshotLayerStoreTests {
  @Test
  func createsAndRemovesAppleOverlayLayer() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskSnapshotLayerStoreFixture()
    defer { fixture.remove() }

    let layer = MacVirtualMachineDiskSnapshotLayer()
    let url = try fixture.store.createLayer(
      layer,
      baseURL: fixture.baseURL,
      retainedLayerURLs: [],
      targetLogicalBytes: 4_096,
      in: fixture.bundleURL
    )

    let image = try DiskImage(
      opening: .open(url: url, mode: .readOnly)
    )
    #expect(url == fixture.bundleURL.appending(path: layer.relativePath))
    #expect(image.format == .asif)
    #expect(image.size == 4_096)
    #expect(
      try url.resourceValues(forKeys: [.isRegularFileKey])
        .isRegularFile == true
    )

    try fixture.store.removeLayers([layer], in: fixture.bundleURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func createsAnActiveOverlayAtAnExplicitLargerCapacity() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskSnapshotLayerStoreFixture()
    defer { fixture.remove() }
    let targetLogicalBytes: UInt64 = 8_192

    let layer = MacVirtualMachineDiskSnapshotLayer()
    let url = try fixture.store.createLayer(
      layer,
      baseURL: fixture.baseURL,
      retainedLayerURLs: [],
      targetLogicalBytes: targetLogicalBytes,
      in: fixture.bundleURL
    )
    let base = try DiskImage(
      opening: .open(url: fixture.baseURL, mode: .readOnly)
    )
    let overlay = try DiskImage(
      opening: .open(url: url, mode: .readOnly)
    )
    let stack = try base.appending(overlay)

    #expect(UInt64(exactly: stack.size) == targetLogicalBytes)
    #expect(stack.layers.last?.layerType == .overlay)
    #expect(stack.layers.last?.url.standardizedFileURL == url.standardizedFileURL)
  }

  @Test
  func recoveryRemovesOnlyRecognizedUnreferencedPrivateArtifacts() throws {
    let fixture = try DiskSnapshotLayerStoreFixture()
    defer { fixture.remove() }
    let directory = fixture.bundleURL.appending(
      path: MacVirtualMachineDiskSnapshotLayer.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )

    let mutation = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Referenced")
    let referenced = mutation.createdLayer
    let referencedURL = fixture.bundleURL.appending(
      path: referenced.relativePath
    )
    let orphan = MacVirtualMachineDiskSnapshotLayer()
    let orphanURL = fixture.bundleURL.appending(path: orphan.relativePath)
    let stagingURL = directory.appending(
      path: ".Snapshot-\(UUID().uuidString).asif.partial"
    )
    try Data("reference".utf8).write(to: referencedURL)
    try Data("orphan".utf8).write(to: orphanURL)
    try Data("staging".utf8).write(to: stagingURL)

    try fixture.store.recoverUnreferencedLayers(
      in: fixture.bundleURL,
      configuration: mutation.configuration
    )

    #expect(FileManager.default.fileExists(atPath: referencedURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
  }

  @Test
  func recoveryFailsClosedForUnknownSnapshotDirectoryEntries() throws {
    let fixture = try DiskSnapshotLayerStoreFixture()
    defer { fixture.remove() }
    let directory = fixture.bundleURL.appending(
      path: MacVirtualMachineDiskSnapshotLayer.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    let unknownURL = directory.appending(path: "notes.txt")
    try Data("do not delete".utf8).write(to: unknownURL)

    #expect(
      throws: MacVirtualMachineDiskSnapshotError.unsafeArtifact("notes.txt")
    ) {
      try fixture.store.recoverUnreferencedLayers(
        in: fixture.bundleURL,
        configuration: .empty
      )
    }
    #expect(FileManager.default.fileExists(atPath: unknownURL.path))
  }
}

private struct DiskSnapshotLayerStoreFixture {
  let rootURL: URL
  let bundleURL: URL
  let baseURL: URL
  let store = AppleMacVirtualMachineDiskSnapshotLayerStore()

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-Snapshot-Layer-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    bundleURL = rootURL.appending(
      path: "Machine.nativevm",
      directoryHint: .isDirectory
    )
    baseURL = bundleURL.appending(path: "Disk.img")
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    try Data(count: 4_096).write(to: baseURL)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
