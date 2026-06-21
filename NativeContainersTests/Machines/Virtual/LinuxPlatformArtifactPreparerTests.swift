import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

struct LinuxPlatformArtifactPreparerTests {
  @Test
  func copiesISOAndCreatesPersistentPlatformIdentity() async throws {
    let fixture = try LinuxPlatformArtifactFixture()
    defer { fixture.remove() }
    let sourceData = Data((0..<16_384).map { UInt8($0 % 251) })
    try sourceData.write(to: fixture.installationMedia)

    let result = try await LinuxPlatformArtifactPreparer().prepare(
      installationMediaURL: fixture.installationMedia,
      destination: fixture.artifacts
    )

    #expect(try Data(contentsOf: fixture.artifacts.installationMedia) == sourceData)
    let identifierData = try Data(contentsOf: fixture.artifacts.machineIdentifier)
    #expect(VZGenericMachineIdentifier(dataRepresentation: identifierData) != nil)
    #expect(
      (try FileManager.default.attributesOfItem(
        atPath: fixture.artifacts.efiVariableStore.path
      )[.size] as? NSNumber)?.intValue ?? 0 > 0
    )
    let macAddress = try #require(VZMACAddress(string: result.macAddress))
    #expect(macAddress.isLocallyAdministeredAddress)
    #expect(macAddress.isUnicastAddress)
    #expect(try permissions(at: fixture.artifacts.machineIdentifier) == 0o600)
    #expect(try permissions(at: fixture.artifacts.efiVariableStore) == 0o600)
  }

  @Test
  func rejectsNonISOInstallationMedia() async throws {
    let fixture = try LinuxPlatformArtifactFixture(sourceExtension: "img")
    defer { fixture.remove() }
    try Data([1]).write(to: fixture.installationMedia)

    await #expect(
      throws: LinuxPlatformArtifactError.unsupportedInstallationMedia(
        fixture.installationMedia.standardizedFileURL
      )
    ) {
      try await FileLinuxInstallationMediaCopier().copy(
        from: fixture.installationMedia,
        to: fixture.artifacts.installationMedia
      )
    }
  }

  @Test
  func rejectsEmptyInstallationMedia() async throws {
    let fixture = try LinuxPlatformArtifactFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.installationMedia)

    await #expect(
      throws: LinuxPlatformArtifactError.emptyInstallationMedia(
        fixture.installationMedia.standardizedFileURL
      )
    ) {
      try await FileLinuxInstallationMediaCopier().copy(
        from: fixture.installationMedia,
        to: fixture.artifacts.installationMedia
      )
    }
  }

  @Test
  func rejectsSymbolicInstallationMedia() async throws {
    let fixture = try LinuxPlatformArtifactFixture()
    defer { fixture.remove() }
    let realMedia = fixture.root.appending(path: "Real.iso")
    try Data([1]).write(to: realMedia)
    try FileManager.default.createSymbolicLink(
      at: fixture.installationMedia,
      withDestinationURL: realMedia
    )

    await #expect(
      throws: LinuxPlatformArtifactError.invalidInstallationMedia(
        fixture.installationMedia.standardizedFileURL
      )
    ) {
      try await FileLinuxInstallationMediaCopier().copy(
        from: fixture.installationMedia,
        to: fixture.artifacts.installationMedia
      )
    }
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }
}

private struct LinuxPlatformArtifactFixture {
  let root: URL
  let installationMedia: URL
  let artifacts: LinuxPlatformArtifactURLs

  init(sourceExtension: String = "iso") throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LinuxPlatformTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    installationMedia = root.appending(path: "Installer.\(sourceExtension)")
    let destination = root.appending(path: "Destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    artifacts = LinuxPlatformArtifactURLs(directory: destination)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
