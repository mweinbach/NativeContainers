import CryptoKit
import Foundation
import Testing
@preconcurrency import Virtualization

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

  @Test
  func productionIdentityPersistsEnabledSecureBootState() throws {
    guard #available(macOS 27.0, *) else { return }
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    let artifacts = WindowsPlatformArtifactURLs(directory: fixture.artifacts)

    _ = try AppleWindowsPlatformIdentityService().create(
      at: artifacts,
      securityMode: .productionSecureBoot
    )

    let variableStore = VZEFIVariableStore(url: artifacts.efiVariableStore)
    #expect(try variableStore.isSecureBootEnabled)
  }

  @Test
  func bootableMediaPopulatorCopiesInstallerSplitsWIMAndWritesOnlyTPMBypass()
    async throws
  {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    try fixture.makeMountedWindowsVolume(machine: 0xaa64, mixedCase: true)
    let destination = fixture.root.appending(
      path: "BootableVolume",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: destination,
      withIntermediateDirectories: false
    )
    let readme = Data("installer payload".utf8)
    try readme.write(to: fixture.volume.appending(path: "README.txt"))
    let secret = Data((0..<32).map { UInt8($0) })
    let splitter = RecordingWindowsWIMImageSplitter()

    try await WindowsBootableInstallationMediaPopulator(
      splitter: splitter
    ).populate(
      from: fixture.volume,
      to: destination,
      guestAgentSecret: secret
    )
    let answer = try String(
      contentsOf: destination.appending(path: "Autounattend.xml"),
      encoding: .utf8
    )
    let embeddedSecret = try Data(
      contentsOf:
        destination
        .appending(
          path: DiskutilWindowsSetupConfigurationMediaWriter.integrationDirectoryName,
          directoryHint: .isDirectory
        )
        .appending(
          path: DiskutilWindowsSetupConfigurationMediaWriter.guestAgentSecretFilename
        )
    )
    let sources = destination.appending(path: "Sources", directoryHint: .isDirectory)
    let splitInvocation = try #require(await splitter.invocation)

    #expect(answer.contains("BypassTPMCheck"))
    #expect(!answer.contains("BypassSecureBootCheck"))
    #expect(!answer.contains("BypassCPUCheck"))
    #expect(!answer.contains("BypassRAMCheck"))
    #expect(embeddedSecret == secret)
    #expect(try Data(contentsOf: destination.appending(path: "README.txt")) == readme)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "EFI/Boot/BOOTAA64.EFI").path
      )
    )
    #expect(!FileManager.default.fileExists(atPath: sources.appending(path: "INSTALL.WIM").path))
    #expect(try Data(contentsOf: sources.appending(path: "install.swm")) == Data([2]))
    #expect(splitInvocation.sourceURL.lastPathComponent == "INSTALL.WIM")
    #expect(splitInvocation.destinationURL == sources.appending(path: "install.swm"))
  }

  @Test
  func wimlibSplitterUsesBoundedFAT32Parts() async throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    let executable = fixture.root.appending(path: "wimlib-imagex")
    try Data([0]).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let executor = RecordingWindowsHostCommandExecutor(
      result: HostCommandResult(
        exitCode: 0,
        standardOutput: "split complete",
        standardError: "",
        outputWasTruncated: false
      )
    )
    let destination = fixture.root.appending(path: "install.swm")

    try await WIMLibWindowsWIMImageSplitter(
      executor: executor,
      executableURL: executable
    ).split(sourceURL: fixture.sourceISO, destinationURL: destination)

    let invocation = try #require(await executor.invocation)
    #expect(invocation.executableURL == executable)
    #expect(
      invocation.arguments
        == [
          "split",
          fixture.sourceISO.path,
          destination.path,
          String(WIMLibWindowsWIMImageSplitter.maximumPartSizeMiB),
        ]
    )
  }

  @Test
  func setupWriterSizesBootableImageWithHeadroom() throws {
    #expect(
      try DiskutilWindowsSetupConfigurationMediaWriter.imageSize(
        installationMediaByteCount: 7_994_415_104
      ) == "8137MiB"
    )
  }

  @Test
  func setupWriterRejectsInvalidGuestAgentSecretBeforeCreatingImage() async throws {
    let fixture = try WindowsMediaFixture()
    defer { fixture.remove() }
    let imageURL = fixture.root.appending(path: "SetupConfig.img")

    await #expect(throws: WindowsPlatformArtifactError.invalidGuestAgentSecret) {
      try await DiskutilWindowsSetupConfigurationMediaWriter().write(
        installationMediaURL: fixture.sourceISO,
        installationMediaByteCount: 1,
        to: imageURL,
        guestAgentSecret: Data(repeating: 0, count: 31)
      )
    }

    #expect(!FileManager.default.fileExists(atPath: imageURL.path))
  }

  @Test
  func diskutilMounterEjectsWholeAttachedImageDevice() async throws {
    let executor = RecordingWindowsHostCommandExecutor(
      result: HostCommandResult(
        exitCode: 0,
        standardOutput: "Disk /dev/disk99 ejected",
        standardError: "",
        outputWasTruncated: false
      )
    )
    let image = MountedDiskImage(
      devicePath: "/dev/disk99",
      mountURL: URL(filePath: "/Volumes/NCTSETUP", directoryHint: .isDirectory),
      volumeLabel: "NCTSETUP"
    )

    try await DiskutilDiskImageMounter(executor: executor).detach(image)

    let invocation = try #require(await executor.invocation)
    #expect(invocation.executableURL == DiskutilDiskImageMounter.executableURL)
    #expect(invocation.arguments == ["eject", "/dev/disk99"])
  }
}

struct WindowsBootMediaRepairTests {
  @Test
  func legacyBootMediaIsAtomicallyRebuiltOnceBeforeRuntimeUse() async throws {
    let fixture = try WindowsBootMediaRepairFixture()
    defer { fixture.remove() }
    let writer = RecordingWindowsSetupMediaWriter(behavior: .succeed)
    let library = fixture.makeLibrary(writer: writer)
    let machine = try await fixture.prepare(using: library)
    try fixture.markBootMediaLegacy(for: machine.id)
    let legacyBytes = try Data(contentsOf: fixture.setupMediaURL(for: machine.id))

    try await library.repairWindowsBootMediaIfNeeded(id: machine.id)

    let repaired = try #require(try await library.list().first)
    #expect(
      repaired.windowsConfiguration?.effectiveBootMediaFormatVersion
        == WindowsVirtualMachineConfiguration.currentBootMediaFormatVersion
    )
    #expect(try Data(contentsOf: fixture.setupMediaURL(for: machine.id)) != legacyBytes)
    #expect(await writer.writeCount == 1)
    try fixture.expectNoRepairPartials(for: machine.id)

    try await library.repairWindowsBootMediaIfNeeded(id: machine.id)
    #expect(await writer.writeCount == 1)
  }

  @Test
  func failedRepairPreservesLegacyMediaAndManifest() async throws {
    let fixture = try WindowsBootMediaRepairFixture()
    defer { fixture.remove() }
    let writer = RecordingWindowsSetupMediaWriter(behavior: .failAfterWrite)
    let library = fixture.makeLibrary(writer: writer)
    let machine = try await fixture.prepare(using: library)
    try fixture.markBootMediaLegacy(for: machine.id)
    let legacyBytes = try Data(contentsOf: fixture.setupMediaURL(for: machine.id))

    await #expect(throws: WindowsBootMediaRepairTestError.expected) {
      try await library.repairWindowsBootMediaIfNeeded(id: machine.id)
    }

    let preserved = try #require(try await library.list().first)
    #expect(preserved.windowsConfiguration?.bootMediaFormatVersion == nil)
    #expect(try Data(contentsOf: fixture.setupMediaURL(for: machine.id)) == legacyBytes)
    try fixture.expectNoRepairPartials(for: machine.id)
  }
}

private enum WindowsBootMediaRepairTestError: Error {
  case expected
}

private actor RecordingWindowsSetupMediaWriter:
  WindowsSetupConfigurationMediaWriting
{
  enum Behavior: Sendable {
    case succeed
    case failAfterWrite
  }

  private let behavior: Behavior
  private(set) var writeCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func write(
    installationMediaURL: URL,
    installationMediaByteCount: UInt64,
    to destinationURL: URL,
    guestAgentSecret: Data
  ) async throws {
    writeCount += 1
    try Data(
      repeating: 0x5a,
      count: Int(installationMediaByteCount) + 64
    ).write(to: destinationURL)
    if behavior == .failAfterWrite {
      throw WindowsBootMediaRepairTestError.expected
    }
  }
}

private struct WindowsBootMediaRepairFixture {
  static let installationBytes = Data(repeating: 0x42, count: 256)

  let root: URL
  let libraryRoot: URL
  let sourceISO: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-WindowsBootMediaRepairTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
    sourceISO = root.appending(path: "Windows.iso")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    try Self.installationBytes.write(to: sourceISO)
  }

  func makeLibrary(
    writer: any WindowsSetupConfigurationMediaWriting
  ) -> VirtualMachineLibrary {
    VirtualMachineLibrary(
      rootURL: libraryRoot,
      windowsPlatformArtifactPreparer: WindowsBootMediaRepairArtifactPreparer(),
      windowsSetupMediaWriter: writer
    )
  }

  func prepare(using library: VirtualMachineLibrary) async throws
    -> VirtualMachineManifest
  {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Legacy Windows",
      guest: .windows,
      resources: resources
    )
    return try await library.prepareWindowsVM(
      id: draft.id,
      installationMediaURL: sourceISO,
      securityMode: .developmentTestSigning,
      guestTools: nil
    )
  }

  func markBootMediaLegacy(for id: UUID) throws {
    let manifestURL = bundleURL(for: id).appending(
      path: VirtualMachineLibrary.manifestFilename
    )
    var manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        as? [String: Any]
    )
    var configuration = try #require(
      manifest["windowsConfiguration"] as? [String: Any]
    )
    configuration.removeValue(forKey: "bootMediaFormatVersion")
    manifest["windowsConfiguration"] = configuration
    try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: manifestURL, options: [.atomic])
  }

  func setupMediaURL(for id: UUID) -> URL {
    bundleURL(for: id)
      .appending(
        path: WindowsPlatformArtifactURLs.directoryName,
        directoryHint: .isDirectory
      )
      .appending(path: WindowsPlatformArtifactURLs.setupConfigurationMediaFilename)
  }

  func expectNoRepairPartials(for id: UUID) throws {
    let platform = setupMediaURL(for: id).deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: platform.path)
    #expect(!names.contains(where: { $0.hasPrefix(".SetupConfig.repair-") }))
  }

  func bundleURL(for id: UUID) -> URL {
    libraryRoot
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct WindowsBootMediaRepairArtifactPreparer:
  WindowsPlatformArtifactPreparing
{
  func prepare(
    installationMediaURL: URL,
    destination: WindowsPlatformArtifactURLs,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> WindowsPlatformPreparationResult {
    try Data("nvram".utf8).write(to: destination.efiVariableStore)
    try Data("machine".utf8).write(to: destination.machineIdentifier)
    try FileManager.default.copyItem(
      at: installationMediaURL,
      to: destination.installationMedia
    )
    try Data(repeating: 0x11, count: 16).write(
      to: destination.setupConfigurationMedia
    )
    try Data(repeating: 0x22, count: 32).write(to: destination.guestAgentSecret)
    return WindowsPlatformPreparationResult(
      macAddress: "02:00:00:00:00:44",
      installationMedia: WindowsInstallationMediaMetadata(
        sha256: String(repeating: "0", count: 64),
        byteCount: UInt64(WindowsBootMediaRepairFixture.installationBytes.count),
        volumeLabel: "WINDOWS_ARM64",
        architecture: .arm64,
        sourceFilename: installationMediaURL.lastPathComponent,
        efiBootManagerPath: "efi/boot/bootaa64.efi",
        bootImagePath: "sources/boot.wim",
        installImagePath: "sources/install.wim"
      )
    )
  }
}

private actor RecordingWindowsWIMImageSplitter: WindowsWIMImageSplitting {
  struct Invocation: Sendable {
    let sourceURL: URL
    let destinationURL: URL
  }

  private(set) var invocation: Invocation?

  func split(sourceURL: URL, destinationURL: URL) async throws {
    invocation = Invocation(
      sourceURL: sourceURL,
      destinationURL: destinationURL
    )
    try Data(contentsOf: sourceURL).write(to: destinationURL)
  }
}

private actor RecordingWindowsHostCommandExecutor: HostCommandExecuting {
  struct Invocation: Sendable {
    let executableURL: URL
    let arguments: [String]
  }

  private let result: HostCommandResult
  private(set) var invocation: Invocation?

  init(result: HostCommandResult) {
    self.result = result
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    invocation = Invocation(
      executableURL: executableURL,
      arguments: arguments
    )
    return result
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
