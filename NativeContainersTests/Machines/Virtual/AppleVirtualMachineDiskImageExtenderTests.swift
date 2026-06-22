import DiskImageKit
import Foundation
import Testing

@testable import NativeContainers

struct AppleVirtualMachineDiskImageExtenderTests {
  @Test
  func extendsStandaloneRAWAndASIFImages() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskImageExtenderFixture()
    defer { fixture.remove() }

    let rawURL = fixture.root.appending(path: "Disk.raw")
    _ = try DiskImage(
      creating: .raw(url: rawURL, blockCount: fixture.sourceBlockCount)
    )
    let asifURL = fixture.root.appending(path: "Disk.asif")
    _ = try DiskImage(
      creating: .asif(
        url: asifURL,
        blockCount: fixture.sourceBlockCount,
        blockSize: .bytes512
      )
    )

    let raw = try fixture.extender.extend(
      VirtualMachineDiskImageResizeSource(
        baseURL: rawURL,
        layerURLs: [],
        expectedFormat: .raw
      ),
      to: fixture.targetBytes
    )
    let asif = try fixture.extender.extend(
      VirtualMachineDiskImageResizeSource(
        baseURL: asifURL,
        layerURLs: [],
        expectedFormat: .asif
      ),
      to: fixture.targetBytes
    )

    #expect(raw.logicalBytes == fixture.targetBytes)
    #expect(raw.blockSizeBytes == fixture.blockSizeBytes)
    #expect(asif.logicalBytes == fixture.targetBytes)
    #expect(asif.blockSizeBytes == fixture.blockSizeBytes)
  }

  @Test
  func extendsOnlyTheWritableTopOfASnapshotStack() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskImageExtenderFixture()
    defer { fixture.remove() }

    let baseURL = fixture.root.appending(path: "Base.asif")
    let overlayURL = fixture.root.appending(path: "Overlay.asif")
    _ = try DiskImage(
      creating: .asif(
        url: baseURL,
        blockCount: fixture.sourceBlockCount,
        blockSize: .bytes512
      )
    )
    do {
      let base = try DiskImage(
        opening: .open(url: baseURL, mode: .readOnly)
      )
      _ = try base.appending(
        .asifLayer(url: overlayURL, type: .overlay)
      )
    }

    let source = VirtualMachineDiskImageResizeSource(
      baseURL: baseURL,
      layerURLs: [overlayURL],
      expectedFormat: .asif
    )
    let grown = try fixture.extender.extend(
      source,
      to: fixture.targetBytes
    )
    let base = try DiskImage(
      opening: .open(url: baseURL, mode: .readOnly)
    )
    let overlay = try DiskImage(
      opening: .open(url: overlayURL, mode: .readOnly)
    )

    #expect(grown.logicalBytes == fixture.targetBytes)
    #expect(base.blockCount == fixture.sourceBlockCount)
    #expect(overlay.blockCount == fixture.targetBlockCount)
  }

  @Test
  func rejectsShrinkAndUnalignedGrowth() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try DiskImageExtenderFixture()
    defer { fixture.remove() }

    let rawURL = fixture.root.appending(path: "Disk.raw")
    _ = try DiskImage(
      creating: .raw(url: rawURL, blockCount: fixture.sourceBlockCount)
    )
    let source = VirtualMachineDiskImageResizeSource(
      baseURL: rawURL,
      layerURLs: [],
      expectedFormat: .raw
    )

    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.extender.extend(
        source,
        to: fixture.sourceBytes - fixture.blockSizeBytes
      )
    }
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try fixture.extender.extend(
        source,
        to: fixture.targetBytes + 1
      )
    }
  }
}

private struct DiskImageExtenderFixture {
  let sourceBlockCount = 2_048
  let targetBlockCount = 4_096
  let blockSizeBytes: UInt64 = 512
  let root: URL
  let extender = AppleVirtualMachineDiskImageExtender()

  var sourceBytes: UInt64 {
    UInt64(sourceBlockCount) * blockSizeBytes
  }

  var targetBytes: UInt64 {
    UInt64(targetBlockCount) * blockSizeBytes
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-DiskImageExtender-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
