import Foundation
import Testing

@testable import NativeContainers

struct MacVirtualMachineBundleResolverTests {
  @Test
  func resolvesOnlyPreparedBundleArtifacts() throws {
    let fixture = try MacBundleFixture()
    defer { fixture.remove() }

    let resolved = try fixture.resolver.resolve(fixture.manifest)

    #expect(resolved.manifest.id == fixture.manifest.id)
    #expect(resolved.bundleURL == fixture.bundle)
    #expect(resolved.diskImageURL == fixture.bundle.appending(path: "Disk.img"))
    #expect(
      resolved.auxiliaryStorageURL
        == fixture.bundle.appending(path: MacPlatformArtifactURLs.auxiliaryStorageManifestPath)
    )
    #expect(resolved.restoreImageURL == fixture.restoreImage)
  }

  @Test
  func runtimeResolutionDoesNotRequireTheCachedRestoreImage() throws {
    let fixture = try MacBundleFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.restoreImage)

    let resolved = try fixture.resolver.resolveRuntime(fixture.manifest)

    #expect(resolved.manifest.id == fixture.manifest.id)
    #expect(resolved.diskImageURL == fixture.bundle.appending(path: "Disk.img"))
    #expect(throws: MacVirtualMachineInstallationError.invalidArtifact("Restore.ipsw")) {
      try fixture.resolver.resolve(fixture.manifest)
    }
  }

  @Test
  func rejectsPathTraversalBeforeReadingOutsideBundle() throws {
    let fixture = try MacBundleFixture(diskImagePath: "../Outside.img")
    defer { fixture.remove() }

    #expect(throws: MacVirtualMachineInstallationError.invalidArtifact("diskImagePath")) {
      try fixture.resolver.resolve(fixture.manifest)
    }
  }

  @Test
  func rejectsSymbolicArtifact() throws {
    let fixture = try MacBundleFixture(symbolicAuxiliaryStorage: true)
    defer { fixture.remove() }

    #expect(
      throws: MacVirtualMachineInstallationError.invalidArtifact("auxiliaryStoragePath")
    ) {
      try fixture.resolver.resolve(fixture.manifest)
    }
  }
}

private struct MacBundleFixture {
  let root: URL
  let bundle: URL
  let restoreImage: URL
  let manifest: VirtualMachineManifest
  let resolver: MacVirtualMachineBundleResolver

  init(
    diskImagePath: String = "Disk.img",
    symbolicAuxiliaryStorage: Bool = false
  ) throws {
    let fileManager = FileManager.default
    root = fileManager.temporaryDirectory.appending(
      path: "NativeContainers-BundleResolverTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Resolver Test",
      guest: .macOS,
      resources: resources,
      diskImagePath: diskImagePath
    )
    bundle =
      root
      .appending(path: manifest.id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    try fileManager.createDirectory(at: bundle, withIntermediateDirectories: false)

    let platformDirectory = bundle.appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: platformDirectory, withIntermediateDirectories: false)

    if diskImagePath == "Disk.img" {
      try Data([0]).write(to: bundle.appending(path: diskImagePath))
    }

    let auxiliaryStorage = platformDirectory.appending(
      path: MacPlatformArtifactURLs.auxiliaryStorageFilename
    )
    if symbolicAuxiliaryStorage {
      let realAuxiliaryStorage = root.appending(path: "RealAuxiliaryStorage")
      try Data([1]).write(to: realAuxiliaryStorage)
      try fileManager.createSymbolicLink(
        at: auxiliaryStorage,
        withDestinationURL: realAuxiliaryStorage
      )
    } else {
      try Data([1]).write(to: auxiliaryStorage)
    }
    try Data([2]).write(
      to: platformDirectory.appending(path: MacPlatformArtifactURLs.hardwareModelFilename)
    )
    try Data([3]).write(
      to: platformDirectory.appending(path: MacPlatformArtifactURLs.machineIdentifierFilename)
    )

    restoreImage = root.appending(path: "Restore.ipsw")
    try Data([4]).write(to: restoreImage)
    manifest.markReadyToInstallMacOS(
      restoreImageURL: restoreImage,
      auxiliaryStoragePath: MacPlatformArtifactURLs.auxiliaryStorageManifestPath,
      hardwareModelPath: MacPlatformArtifactURLs.hardwareModelManifestPath,
      machineIdentifierPath: MacPlatformArtifactURLs.machineIdentifierManifestPath
    )

    self.manifest = manifest
    resolver = MacVirtualMachineBundleResolver(rootURL: root)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
