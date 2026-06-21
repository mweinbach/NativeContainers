import DiskImageKit
import Foundation
import Testing

@testable import NativeContainers

struct AppleVirtualMachineDiskImageInspectorTests {
  @Test
  func inspectsRAWLogicalCapacityFromItsBlockMapping() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diskURL = directory.appending(path: "Disk.img")
    #expect(FileManager.default.createFile(atPath: diskURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: diskURL)
    try handle.truncate(atOffset: 8 * 1_024 * 1_024)
    try handle.close()

    let descriptor = try AppleVirtualMachineDiskImageInspector().inspect(
      at: diskURL,
      expectedFormat: .raw
    )

    #expect(descriptor.format == .raw)
    #expect(descriptor.logicalBytes == 8 * 1_024 * 1_024)
    #expect(descriptor.blockSizeBytes == 512)
    #expect(descriptor.blockCount == 16_384)
  }

  @Test
  @available(macOS 27.0, *)
  func inspectsASIFLogicalCapacityRatherThanHostFileLength() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diskURL = directory.appending(path: "Disk.asif")
    let blockCount = 32_768
    do {
      let image = try DiskImage(
        creating: .asif(
          url: diskURL,
          blockCount: blockCount,
          blockSize: .bytes512
        )
      )
      withExtendedLifetime(image) {}
    }

    let descriptor = try AppleVirtualMachineDiskImageInspector().inspect(
      at: diskURL,
      expectedFormat: .asif
    )
    let hostBytes =
      try #require(
        FileManager.default.attributesOfItem(atPath: diskURL.path)[.size]
          as? NSNumber
      ).uint64Value

    #expect(descriptor.format == .asif)
    #expect(descriptor.logicalBytes == UInt64(blockCount * 512))
    #expect(descriptor.blockSizeBytes == 512)
    #expect(hostBytes != descriptor.logicalBytes)
  }

  @Test
  @available(macOS 27.0, *)
  func rejectsAnImageWhoseContentsDisagreeWithTheManifestFormat() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diskURL = directory.appending(path: "Declared-ASIF.img")
    do {
      let image = try DiskImage(
        creating: .raw(url: diskURL, blockCount: 16_384)
      )
      withExtendedLifetime(image) {}
    }

    #expect(
      throws: VirtualMachineDiskImageError.unexpectedFormat(
        expected: .asif,
        actual: "RAW"
      )
    ) {
      _ = try AppleVirtualMachineDiskImageInspector().inspect(
        at: diskURL,
        expectedFormat: .asif
      )
    }
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}
