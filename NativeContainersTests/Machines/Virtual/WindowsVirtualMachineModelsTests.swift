import Foundation
import Testing

@testable import NativeContainers

struct WindowsVirtualMachineModelsTests {
  @Test
  func olderManifestWithoutWindowsConfigurationStillDecodes() throws {
    let data = Data(
      """
      {
        "schemaVersion": 1,
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Existing Linux",
        "guest": "linux",
        "installState": "draft",
        "resources": {
          "cpuCount": 4,
          "memoryBytes": 4294967296,
          "diskBytes": 8589934592
        },
        "createdAt": 0,
        "updatedAt": 0,
        "diskImagePath": "Disk.img"
      }
      """.utf8
    )

    let manifest = try JSONDecoder().decode(VirtualMachineManifest.self, from: data)

    #expect(manifest.windowsConfiguration == nil)
    #expect(manifest.windowsDiskSnapshotConfiguration == nil)
    #expect(manifest.guest == .linux)
  }

  @Test
  func windowsPreparationRoundTripsWithoutChangingSchema() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 128 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Windows 11",
      guest: .windows,
      resources: resources
    )
    let configuration = makeConfiguration()

    manifest.markReadyToInstallWindows(configuration: configuration)
    let decoded = try JSONDecoder().decode(
      VirtualMachineManifest.self,
      from: JSONEncoder().encode(manifest)
    )

    #expect(decoded == manifest)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.installState == .readyToInstall)
    #expect(decoded.windowsConfiguration == configuration)
  }

  @Test
  func windowsConfigurationWithoutGuestToolsMediaFlagStillDecodes() throws {
    let configuration = makeConfiguration()
    var object = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(configuration)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "guestToolsMediaAttached")

    let decoded = try JSONDecoder().decode(
      WindowsVirtualMachineConfiguration.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.guestToolsMediaAttached == nil)
    #expect(!decoded.effectiveGuestToolsMediaAttached)
  }

  @Test
  func finishingInstallationEjectsBothSetupVolumesFromFutureBoots() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 128 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Windows 11",
      guest: .windows,
      resources: resources
    )
    manifest.markReadyToInstallWindows(configuration: makeConfiguration())

    manifest.markWindowsInstallationCompleted()

    #expect(manifest.installState == .stopped)
    #expect(manifest.windowsConfiguration?.installationMediaPath == nil)
    #expect(manifest.windowsConfiguration?.setupConfigurationMediaPath == nil)
    #expect(manifest.windowsConfiguration?.installationMedia.sha256 == "abc123")
  }

  @Test
  func windowsCloneRequiresFreshNetworkIdentity() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 128 * VirtualMachineResources.bytesPerGiB
    )
    var source = try VirtualMachineManifest(
      name: "Windows Source",
      guest: .windows,
      installState: .stopped,
      resources: resources
    )
    var installed = makeConfiguration()
    installed.installationMediaPath = nil
    installed.setupConfigurationMediaPath = nil
    source.windowsConfiguration = installed

    #expect(throws: WindowsVirtualMachineError.self) {
      _ = try VirtualMachineManifest(cloning: source, name: "Unsafe Copy")
    }

    let clone = try VirtualMachineManifest(
      cloning: source,
      name: "Safe Copy",
      windowsMACAddress: "02:00:00:00:00:02"
    )
    #expect(clone.windowsConfiguration?.macAddress == "02:00:00:00:00:02")
    #expect(clone.windowsConfiguration?.installationMediaPath == nil)
  }

  private func makeConfiguration() -> WindowsVirtualMachineConfiguration {
    WindowsVirtualMachineConfiguration(
      efiVariableStorePath: "WindowsPlatform/NVRAM",
      machineIdentifierPath: "WindowsPlatform/MachineIdentifier",
      installationMediaPath: "WindowsPlatform/Installation.iso",
      setupConfigurationMediaPath: "WindowsPlatform/SetupConfig.img",
      guestAgentSecretPath: "WindowsPlatform/GuestAgentSecret",
      installationMedia: WindowsInstallationMediaMetadata(
        sha256: "abc123",
        byteCount: 7_994_415_104,
        volumeLabel: "CCCOMA_A64FRE_EN-US_DV9",
        architecture: .arm64,
        sourceFilename: "Win11_25H2_English_Arm64_v2.iso",
        efiBootManagerPath: "efi/boot/bootaa64.efi",
        bootImagePath: "sources/boot.wim",
        installImagePath: "sources/install.wim"
      ),
      macAddress: "02:00:00:00:00:01",
      securityMode: .developmentTestSigning
    )
  }
}
