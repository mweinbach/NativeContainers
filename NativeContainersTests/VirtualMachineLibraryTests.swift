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
}
