import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineLibraryTests {
  @Test
  func createsAtomicBundleWithSparseDiskAndReloadsIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )

    let created = try await library.createDraft(
      name: "Build Machine",
      guest: .macOS,
      resources: resources
    )
    let loaded = try await library.list()

    #expect(loaded == [created])

    let bundles = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    #expect(bundles.count == 1)
    #expect(bundles[0].pathExtension == VirtualMachineLibrary.bundleExtension)

    let diskURL = bundles[0].appending(path: created.diskImagePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
    #expect((attributes[.size] as? NSNumber)?.uint64Value == resources.diskBytes)

    let partials = bundles.filter { $0.lastPathComponent.contains(".partial-") }
    #expect(partials.isEmpty)
  }

  @Test
  func listRejectsUnknownManifestSchema() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let bundle =
      root
      .appending(path: "unknown", directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let manifest = """
      {
        "schemaVersion": 999,
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Future VM",
        "guest": "macOS",
        "installState": "draft",
        "resources": { "cpuCount": 4, "memoryBytes": 8589934592, "diskBytes": 68719476736 },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """
    try Data(manifest.utf8).write(
      to: bundle.appending(path: VirtualMachineLibrary.manifestFilename))

    let library = VirtualMachineLibrary(rootURL: root)
    await #expect(throws: VirtualMachineModelError.unsupportedSchema(999)) {
      _ = try await library.list()
    }
  }

  @Test
  func preparesMacPlatformArtifactsAndAtomicallyUpdatesManifest() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let preparer = TestMacPlatformArtifactPreparer(behavior: .success)
    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: preparer
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Prepared Mac",
      guest: .macOS,
      resources: resources
    )
    let restoreImageURL = root.appending(path: "Restore.ipsw")

    let prepared = try await library.prepareMacVM(
      id: draft.id,
      restoreImageURL: restoreImageURL
    )
    let reloaded = try await library.list()

    #expect(prepared.installState == .readyToInstall)
    #expect(prepared.restoreImageURL == restoreImageURL)
    #expect(
      prepared.auxiliaryStoragePath == MacPlatformArtifactURLs.auxiliaryStorageManifestPath
    )
    #expect(prepared.hardwareModelPath == MacPlatformArtifactURLs.hardwareModelManifestPath)
    #expect(
      prepared.machineIdentifierPath == MacPlatformArtifactURLs.machineIdentifierManifestPath
    )
    #expect(prepared.updatedAt >= draft.updatedAt)
    #expect(reloaded == [prepared])

    let artifactDirectory = bundleURL(root: root, id: draft.id).appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    let artifacts = MacPlatformArtifactURLs(directory: artifactDirectory)
    for artifact in artifacts.all {
      #expect(FileManager.default.fileExists(atPath: artifact.path))
    }
    #expect(try Data(contentsOf: artifacts.auxiliaryStorage) == Data("auxiliary".utf8))
    #expect(try Data(contentsOf: artifacts.hardwareModel) == Data("hardware".utf8))
    #expect(try Data(contentsOf: artifacts.machineIdentifier) == Data("machine".utf8))

    let recordedResources = await preparer.recordedResources
    let recordedRestoreImageURL = await preparer.recordedRestoreImageURL
    #expect(recordedResources == resources)
    #expect(recordedRestoreImageURL == restoreImageURL)
    try expectNoPartialDirectories(in: bundleURL(root: root, id: draft.id))
  }

  @Test
  func preparationFailureRollsBackArtifactsAndPreservesDraftManifest() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(
        behavior: .failAfterFirstArtifact
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Rollback Mac",
      guest: .macOS,
      resources: resources
    )

    await #expect(throws: TestMacPlatformPreparationError.failed) {
      _ = try await library.prepareMacVM(
        id: draft.id,
        restoreImageURL: root.appending(path: "Restore.ipsw")
      )
    }

    let reloaded = try await library.list()
    #expect(reloaded == [draft])
    let bundle = bundleURL(root: root, id: draft.id)
    #expect(
      !FileManager.default.fileExists(
        atPath: bundle.appending(path: MacPlatformArtifactURLs.directoryName).path
      )
    )
    try expectNoPartialDirectories(in: bundle)
  }

  @Test
  func missingPreparedArtifactRollsBackBeforePromotion() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(
        behavior: .omitMachineIdentifier
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Incomplete Mac",
      guest: .macOS,
      resources: resources
    )

    await #expect(
      throws: MacPlatformArtifactError.missingArtifact(
        MacPlatformArtifactURLs.machineIdentifierFilename
      )
    ) {
      _ = try await library.prepareMacVM(
        id: draft.id,
        restoreImageURL: root.appending(path: "Restore.ipsw")
      )
    }

    let reloaded = try await library.list()
    #expect(reloaded == [draft])
    try expectNoPartialDirectories(in: bundleURL(root: root, id: draft.id))
  }

  @Test
  func versionOneManifestWithoutMacPlatformFieldsRemainsDecodable() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let bundle = bundleURL(root: root, id: identifier)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let manifest = """
      {
        "schemaVersion": 1,
        "id": "\(identifier.uuidString)",
        "name": "Legacy VM",
        "guest": "macOS",
        "installState": "draft",
        "resources": { "cpuCount": 4, "memoryBytes": 4294967296, "diskBytes": 8589934592 },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """
    try Data(manifest.utf8).write(
      to: bundle.appending(path: VirtualMachineLibrary.manifestFilename)
    )

    let library = VirtualMachineLibrary(
      rootURL: root,
      macPlatformArtifactPreparer: TestMacPlatformArtifactPreparer(behavior: .success)
    )
    let manifests = try await library.list()
    let loaded = try #require(manifests.first)

    #expect(loaded.id == identifier)
    #expect(loaded.auxiliaryStoragePath == nil)
    #expect(loaded.hardwareModelPath == nil)
    #expect(loaded.machineIdentifierPath == nil)
    #expect(loaded.restoreImageURL == nil)

    let prepared = try await library.prepareMacVM(
      id: identifier,
      restoreImageURL: root.appending(path: "LegacyRestore.ipsw")
    )
    #expect(prepared.installState == .readyToInstall)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  private func bundleURL(root: URL, id: UUID) -> URL {
    root
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  private func expectNoPartialDirectories(in bundle: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: bundle,
      includingPropertiesForKeys: nil
    )
    #expect(entries.allSatisfy { !$0.lastPathComponent.contains(".partial-") })
  }
}

private actor TestMacPlatformArtifactPreparer: MacPlatformArtifactPreparing {
  enum Behavior: Equatable, Sendable {
    case success
    case failAfterFirstArtifact
    case omitMachineIdentifier
  }

  let behavior: Behavior
  private(set) var recordedResources: VirtualMachineResources?
  private(set) var recordedRestoreImageURL: URL?

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws {
    recordedRestoreImageURL = restoreImageURL
    recordedResources = resources

    try Data("hardware".utf8).write(to: destination.hardwareModel)
    if behavior == .failAfterFirstArtifact {
      throw TestMacPlatformPreparationError.failed
    }

    try Data("auxiliary".utf8).write(to: destination.auxiliaryStorage)
    if behavior != .omitMachineIdentifier {
      try Data("machine".utf8).write(to: destination.machineIdentifier)
    }
  }
}

private enum TestMacPlatformPreparationError: Error, Equatable {
  case failed
}
