import Foundation
import Testing

@testable import NativeContainers

struct LinuxVirtualMachineLibraryTests {
  @Test
  func preparesArtifactsAndAtomicallyPersistsLinuxConfiguration() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let preparer = TestLinuxPlatformArtifactPreparer(behavior: .success)
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: preparer
    )
    let draft = try await library.createDraft(
      name: "GUI Linux",
      guest: .linux,
      resources: fixture.resources
    )

    let prepared = try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: fixture.installationMedia
    )

    #expect(prepared.installState == .readyToInstall)
    #expect(
      prepared.linuxConfiguration
        == LinuxVirtualMachineConfiguration(
          efiVariableStorePath: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
          machineIdentifierPath: LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
          installationMediaPath: LinuxPlatformArtifactURLs.installationMediaManifestPath,
          macAddress: TestLinuxPlatformArtifactPreparer.macAddress
        )
    )
    #expect(try await library.list() == [prepared])
    #expect(await preparer.recordedInstallationMediaURL == fixture.installationMedia)

    let artifacts = LinuxPlatformArtifactURLs(
      directory: fixture.bundleURL(for: draft.id).appending(
        path: LinuxPlatformArtifactURLs.directoryName,
        directoryHint: .isDirectory
      )
    )
    for artifact in artifacts.all {
      #expect(FileManager.default.fileExists(atPath: artifact.path))
    }
    try expectNoPartialDirectories(in: fixture.bundleURL(for: draft.id))
  }

  @Test
  func preparationFailureRollsBackArtifactsAndManifest() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .failAfterFirstArtifact
      )
    )
    let draft = try await library.createDraft(
      name: "Rollback Linux",
      guest: .linux,
      resources: fixture.resources
    )

    await #expect(throws: TestLinuxPlatformPreparationError.expected) {
      _ = try await library.prepareLinuxVM(
        id: draft.id,
        installationMediaURL: fixture.installationMedia
      )
    }

    #expect(try await library.list() == [draft])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.bundleURL(for: draft.id)
          .appending(path: LinuxPlatformArtifactURLs.directoryName).path
      )
    )
    try expectNoPartialDirectories(in: fixture.bundleURL(for: draft.id))
  }

  @Test
  func missingPreparedArtifactRollsBackBeforePromotion() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .omitMachineIdentifier
      )
    )
    let draft = try await library.createDraft(
      name: "Incomplete Linux",
      guest: .linux,
      resources: fixture.resources
    )

    await #expect(
      throws: LinuxPlatformArtifactError.missingArtifact(
        LinuxPlatformArtifactURLs.machineIdentifierFilename
      )
    ) {
      _ = try await library.prepareLinuxVM(
        id: draft.id,
        installationMediaURL: fixture.installationMedia
      )
    }

    #expect(try await library.list() == [draft])
    try expectNoPartialDirectories(in: fixture.bundleURL(for: draft.id))
  }

  @Test
  func rejectsLinuxPreparationForMacGuest() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .success
      )
    )
    let draft = try await library.createDraft(
      name: "Not Linux",
      guest: .macOS,
      resources: fixture.resources
    )

    await #expect(throws: VirtualMachineModelError.requiresLinuxGuest(draft.id)) {
      _ = try await library.prepareLinuxVM(
        id: draft.id,
        installationMediaURL: fixture.installationMedia
      )
    }
  }

  @Test
  func networkConfigurationPersistsThroughLinuxRuntimeLease() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .success
      )
    )
    let draft = try await library.createDraft(
      name: "Network Linux",
      guest: .linux,
      resources: fixture.resources
    )
    let prepared = try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: fixture.installationMedia
    )
    let service = LinuxVirtualMachineNetworkService(
      leasingStore: library,
      persistence: library
    )

    #expect(try await service.snapshot(id: prepared.id).configuration == .nat)
    let updated = try await service.setAttachment(.shared, for: prepared.id)

    #expect(updated.configuration.revision == 1)
    #expect(updated.configuration.attachment == .shared)
    let reloaded = try #require(try await library.list().first)
    #expect(reloaded.effectiveNetworkConfiguration == updated.configuration)
    let replacementLease = try await library.acquireLinuxRuntime(id: prepared.id)
    #expect(
      replacementLease.machine.manifest.effectiveNetworkConfiguration
        == updated.configuration
    )
    replacementLease.release()
  }

  @Test
  func computeConfigurationPersistsThroughLinuxRuntimeLease() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .success
      )
    )
    let draft = try await library.createDraft(
      name: "Compute Linux",
      guest: .linux,
      resources: fixture.resources
    )
    let prepared = try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: fixture.installationMedia
    )
    let service = LinuxVirtualMachineComputeService(
      leasingStore: library,
      persistence: library,
      platformLimits: VirtualMachineComputeLimits(
        minimumCPUCount: 1,
        maximumCPUCount: 12,
        minimumMemoryBytes: VirtualMachineResources.bytesPerGiB,
        maximumMemoryBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )

    let updated = try await service.setConfiguration(
      VirtualMachineComputeConfiguration(
        cpuCount: 2,
        memoryBytes: 2 * VirtualMachineResources.bytesPerGiB
      ),
      for: prepared.id
    )

    #expect(updated.configuration.cpuCount == 2)
    #expect(
      updated.configuration.memoryBytes
        == 2 * VirtualMachineResources.bytesPerGiB
    )
    #expect(updated.diskBytes == prepared.resources.diskBytes)
    let reloaded = try #require(try await library.list().first)
    #expect(reloaded.resources.cpuCount == 2)
    #expect(
      reloaded.resources.memoryBytes
        == 2 * VirtualMachineResources.bytesPerGiB
    )
    #expect(reloaded.resources.diskBytes == prepared.resources.diskBytes)
  }

  @Test
  func linuxRuntimeLeasePersistsAndReloadsSharedDirectories() async throws {
    let fixture = try LinuxLibraryFixture()
    defer { fixture.remove() }
    let library = VirtualMachineLibrary(
      rootURL: fixture.root,
      linuxPlatformArtifactPreparer: TestLinuxPlatformArtifactPreparer(
        behavior: .success
      )
    )
    let draft = try await library.createDraft(
      name: "Shared Linux",
      guest: .linux,
      resources: fixture.resources
    )
    _ = try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: fixture.installationMedia
    )
    let directory = LinuxVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: "Projects",
      bookmarkData: Data("bookmark".utf8),
      lastKnownPath: "/tmp/Projects",
      sourceIdentity: .init(device: 1, inode: 2),
      readOnly: false
    )

    let firstLease = try await library.acquireLinuxRuntime(id: draft.id)
    let configuration = try await library.addLinuxSharedDirectory(
      directory,
      for: firstLease
    )
    firstLease.release()

    let secondLease = try await library.acquireLinuxRuntime(id: draft.id)
    defer { secondLease.release() }

    #expect(configuration.revision == 1)
    #expect(configuration.directories == [directory])
    #expect(secondLease.machine.sharedDirectories == configuration)
  }

  private func expectNoPartialDirectories(in bundleURL: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: bundleURL,
      includingPropertiesForKeys: nil
    )
    #expect(
      !entries.contains {
        $0.lastPathComponent.hasPrefix(
          ".\(LinuxPlatformArtifactURLs.directoryName).partial-"
        )
      }
    )
  }
}

private struct LinuxLibraryFixture {
  let root: URL
  let installationMedia: URL
  let resources: VirtualMachineResources

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LinuxLibraryTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    installationMedia = root.appending(path: "Installer.iso")
    resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
  }

  func bundleURL(for id: UUID) -> URL {
    root
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor TestLinuxPlatformArtifactPreparer: LinuxPlatformArtifactPreparing {
  static let macAddress = "02:00:00:00:00:01"

  enum Behavior {
    case success
    case failAfterFirstArtifact
    case omitMachineIdentifier
  }

  let behavior: Behavior
  private(set) var recordedInstallationMediaURL: URL?

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func prepare(
    installationMediaURL: URL,
    destination: LinuxPlatformArtifactURLs
  ) async throws -> LinuxPlatformPreparationResult {
    recordedInstallationMediaURL = installationMediaURL
    try Data("efi".utf8).write(to: destination.efiVariableStore)
    if behavior == .failAfterFirstArtifact {
      throw TestLinuxPlatformPreparationError.expected
    }
    if behavior != .omitMachineIdentifier {
      try Data("machine".utf8).write(to: destination.machineIdentifier)
    }
    try Data("iso".utf8).write(to: destination.installationMedia)
    return LinuxPlatformPreparationResult(macAddress: Self.macAddress)
  }
}

private enum TestLinuxPlatformPreparationError: Error {
  case expected
}
