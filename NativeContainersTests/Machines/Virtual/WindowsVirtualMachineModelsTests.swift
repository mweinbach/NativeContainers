import Foundation
import Testing

@testable import NativeContainers

struct WindowsVirtualMachineModelsTests {
  @Test
  func windowsConfigurationDefaultsToTheCurrentBootableSecurityMode() {
    let configuration = WindowsVirtualMachineConfiguration(
      efiVariableStorePath: "WindowsPlatform/NVRAM",
      machineIdentifierPath: "WindowsPlatform/MachineIdentifier",
      installationMediaPath: "WindowsPlatform/Installation.iso",
      setupConfigurationMediaPath: "WindowsPlatform/SetupConfig.img",
      guestAgentSecretPath: "WindowsPlatform/GuestAgentSecret",
      installationMedia: makeWindowsInstallationMediaMetadata(),
      macAddress: "02:00:00:00:00:01"
    )

    #expect(configuration.securityMode == .developmentTestSigning)
    #expect(configuration.securityMode.isCurrentlyBootable)
    #expect(!WindowsVirtualMachineSecurityMode.productionSecureBoot.isCurrentlyBootable)
  }

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
      installationMedia: makeWindowsInstallationMediaMetadata(),
      macAddress: "02:00:00:00:00:01",
      securityMode: .developmentTestSigning
    )
  }
}

struct WindowsVirtualMachineCreationServiceTests {
  @Test
  func createsWindowsMachineWithSecureBootOff() async throws {
    let library = WindowsCreationTestLibrary()
    let guestTools = RecordingWindowsCreationGuestTools()
    let service = WindowsVirtualMachineCreationService(
      library: library,
      guestTools: guestTools
    )
    let mediaURL = URL(filePath: "/tmp/Windows.iso")

    let machine = try await service.createWindowsVirtualMachine(
      name: "Windows 11",
      resources: try makeWindowsCreationResources(),
      installationMediaURL: mediaURL,
      securityMode: .currentDefault
    )

    #expect(machine.guest == .windows)
    #expect(machine.installState == .readyToInstall)
    #expect(machine.windowsConfiguration?.securityMode == .developmentTestSigning)
    #expect(await library.preparedMediaURL == mediaURL)
    #expect(await library.preparedGuestTools == nil)
    #expect(await guestTools.prepareCount == 0)
  }

  @Test
  func secureBootIsBlockedBeforeDraftOrGuestToolsPreparation() async throws {
    let library = WindowsCreationTestLibrary()
    let guestTools = RecordingWindowsCreationGuestTools()
    let service = WindowsVirtualMachineCreationService(
      library: library,
      guestTools: guestTools
    )

    await #expect(throws: WindowsVirtualMachineError.secureBootBootUnavailable) {
      _ = try await service.createWindowsVirtualMachine(
        name: "Blocked Secure Boot",
        resources: try makeWindowsCreationResources(),
        installationMediaURL: URL(filePath: "/tmp/Windows.iso"),
        securityMode: .productionSecureBoot
      )
    }

    #expect(await library.draftCount == 0)
    #expect(await library.prepareCount == 0)
    #expect(await guestTools.prepareCount == 0)
  }
}

private actor WindowsCreationTestLibrary: VirtualMachineLibraryProtocol {
  private(set) var manifests: [VirtualMachineManifest] = []
  private(set) var draftCount = 0
  private(set) var prepareCount = 0
  private(set) var preparedMediaURL: URL?
  private(set) var preparedGuestTools: WindowsGuestToolsReleaseReference?

  func list() -> [VirtualMachineManifest] {
    manifests
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    draftCount += 1
    let manifest = try VirtualMachineManifest(
      name: name,
      guest: guest,
      installState: .draft,
      resources: resources
    )
    manifests.append(manifest)
    return manifest
  }

  func prepareWindowsVM(
    id: UUID,
    installationMediaURL: URL,
    securityMode: WindowsVirtualMachineSecurityMode,
    guestTools: WindowsGuestToolsReleaseReference?
  ) throws -> VirtualMachineManifest {
    prepareCount += 1
    preparedMediaURL = installationMediaURL
    preparedGuestTools = guestTools
    guard let index = manifests.firstIndex(where: { $0.id == id }) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    var manifest = manifests[index]
    manifest.markReadyToInstallWindows(
      configuration: WindowsVirtualMachineConfiguration(
        efiVariableStorePath: "WindowsPlatform/NVRAM",
        machineIdentifierPath: "WindowsPlatform/MachineIdentifier",
        installationMediaPath: "WindowsPlatform/Installation.iso",
        setupConfigurationMediaPath: "WindowsPlatform/SetupConfig.img",
        guestAgentSecretPath: "WindowsPlatform/GuestAgentSecret",
        installationMedia: makeWindowsInstallationMediaMetadata(),
        macAddress: "02:00:00:00:00:01",
        securityMode: securityMode,
        guestTools: guestTools
      )
    )
    manifests[index] = manifest
    return manifest
  }
}

private actor RecordingWindowsCreationGuestTools: WindowsGuestToolsReleaseManaging {
  private(set) var prepareCount = 0

  func prepareProductionRelease() -> WindowsGuestToolsReleaseReference {
    prepareCount += 1
    return WindowsGuestToolsReleaseReference(
      version: "1.0.0",
      artifactURL: URL(string: "https://example.invalid/NCTools.iso")!,
      sha256: String(repeating: "0", count: 64),
      byteCount: 1,
      isMicrosoftSigned: true
    )
  }
}

private func makeWindowsCreationResources() throws -> VirtualMachineResources {
  try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
}

private func makeWindowsInstallationMediaMetadata()
  -> WindowsInstallationMediaMetadata
{
  WindowsInstallationMediaMetadata(
    sha256: "abc123",
    byteCount: 7_994_415_104,
    volumeLabel: "CCCOMA_A64FRE_EN-US_DV9",
    architecture: .arm64,
    sourceFilename: "Win11_25H2_English_Arm64_v2.iso",
    efiBootManagerPath: "efi/boot/bootaa64.efi",
    bootImagePath: "sources/boot.wim",
    installImagePath: "sources/install.wim"
  )
}
