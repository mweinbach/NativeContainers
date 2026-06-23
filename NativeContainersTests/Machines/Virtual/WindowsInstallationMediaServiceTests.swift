import CryptoKit
import Foundation
import Testing

@testable import NativeContainers

struct WindowsInstallationMediaServiceTests {
  @Test
  func copierPreservesBytesAndReturnsSHA256() async throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    let bytes = Data((0..<32_768).map { UInt8($0 % 251) })
    try bytes.write(to: fixture.sourceISO)

    let result = try await FileWindowsInstallationMediaCopier().copy(
      from: fixture.sourceISO,
      to: fixture.copiedISO
    )

    #expect(try Data(contentsOf: fixture.copiedISO) == bytes)
    #expect(result.byteCount == UInt64(bytes.count))
    #expect(
      result.sha256
        == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    )
  }

  @Test
  func volumeInspectorAcceptsCaseInsensitiveWindowsARM64Layout() throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    try fixture.makeMountedWindowsVolume(machine: 0xaa64, mixedCase: true)

    let result = try WindowsInstallationMediaVolumeInspector().inspect(
      fixture.volume
    )

    #expect(result.efiBootManagerPath == "efi/boot/bootaa64.efi")
    #expect(result.bootImagePath == "sources/boot.wim")
    #expect(result.installImagePath == "sources/install.wim")
  }

  @Test
  func volumeInspectorRejectsX64BootManager() throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    try fixture.makeMountedWindowsVolume(machine: 0x8664)

    #expect(
      throws: WindowsInstallationMediaError.unsupportedBootArchitecture(0x8664)
    ) {
      try WindowsInstallationMediaVolumeInspector().inspect(fixture.volume)
    }
  }

  @Test
  func diskutilInspectorAlwaysDetachesAndPersistsExactMetadata() async throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    try fixture.makeMountedWindowsVolume(machine: 0xaa64)
    let mounter = RecordingWindowsMediaMounter(
      image: MountedDiskImage(
        devicePath: "/dev/disk99",
        mountURL: fixture.volume,
        volumeLabel: "WINDOWS_ARM64"
      )
    )
    let inspector = DiskutilWindowsInstallationMediaInspector(mounter: mounter)

    let metadata = try await inspector.inspect(
      installationMediaURL: fixture.sourceISO,
      sourceFilename: "Windows.iso",
      copy: WindowsInstallationMediaCopyResult(sha256: "00ff", byteCount: 42)
    )

    #expect(metadata.sha256 == "00ff")
    #expect(metadata.byteCount == 42)
    #expect(metadata.volumeLabel == "WINDOWS_ARM64")
    #expect(metadata.architecture == .arm64)
    #expect(await mounter.detachCount() == 1)
  }

  @Test
  func developmentIdentityCreatesPersistentArtifactsAndSecret() throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    let artifacts = WindowsPlatformArtifactURLs(directory: fixture.artifacts)

    let address = try AppleWindowsPlatformIdentityService().create(
      at: artifacts,
      securityMode: .developmentTestSigning
    )

    #expect(try Data(contentsOf: artifacts.machineIdentifier).count > 0)
    #expect(try Data(contentsOf: artifacts.efiVariableStore).count > 0)
    #expect(try Data(contentsOf: artifacts.guestAgentSecret).count == 32)
    #expect(!address.isEmpty)
  }
}

private actor RecordingWindowsMediaMounter: DiskImageMounting {
  private let image: MountedDiskImage
  private var detachCalls = 0

  init(image: MountedDiskImage) {
    self.image = image
  }

  func attach(_ imageURL: URL, readOnly: Bool) -> MountedDiskImage {
    image
  }

  func detach(_ image: MountedDiskImage) {
    detachCalls += 1
  }

  func detachCount() -> Int {
    detachCalls
  }
}

private struct WindowsMediaFixture {
  let root: URL
  let sourceISO: URL
  let copiedISO: URL
  let volume: URL
  let artifacts: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-WindowsMediaTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    sourceISO = root.appending(path: "Source.iso")
    copiedISO = root.appending(path: "Copied.iso")
    volume = root.appending(path: "Volume", directoryHint: .isDirectory)
    artifacts = root.appending(path: "Artifacts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
  }

  func makeMountedWindowsVolume(machine: UInt16, mixedCase: Bool = false) throws {
    let efi = volume.appending(path: mixedCase ? "EFI" : "efi", directoryHint: .isDirectory)
    let boot = efi.appending(path: mixedCase ? "Boot" : "boot", directoryHint: .isDirectory)
    let sources = volume.appending(
      path: mixedCase ? "Sources" : "sources",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

    var pe = Data(repeating: 0, count: 128)
    pe[0] = 0x4d
    pe[1] = 0x5a
    pe[0x3c] = 0x40
    pe[0x40] = 0x50
    pe[0x41] = 0x45
    pe[0x44] = UInt8(machine & 0xff)
    pe[0x45] = UInt8(machine >> 8)
    try pe.write(to: boot.appending(path: mixedCase ? "BOOTAA64.EFI" : "bootaa64.efi"))
    try Data([1]).write(to: sources.appending(path: mixedCase ? "BOOT.WIM" : "boot.wim"))
    try Data([2]).write(
      to: sources.appending(path: mixedCase ? "INSTALL.WIM" : "install.wim")
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
