import Foundation
import Testing

@testable import NativeContainers

struct LinuxVirtualMachineRuntimeOwnershipStoreTests {
  @Test
  func runtimeLeasePinsOneGenerationAndBlocksCompetingStart() async throws {
    let fixture = try LinuxRuntimeOwnershipFixture()
    defer { fixture.remove() }
    let machine = try await fixture.prepare()

    let firstLease = try await fixture.library.acquireLinuxRuntime(id: machine.id)
    let competingLibrary = VirtualMachineLibrary(rootURL: fixture.libraryURL)

    await #expect(throws: LinuxVirtualMachineRuntimeError.ownedElsewhere(machine.id)) {
      _ = try await competingLibrary.acquireLinuxRuntime(id: machine.id)
    }

    firstLease.release()
    let secondLease = try await competingLibrary.acquireLinuxRuntime(id: machine.id)
    #expect(secondLease.target.generation != firstLease.target.generation)
    secondLease.release()
  }

  @Test
  func completionDetachesInstallerFromFutureBootsAndRetainsMediaArtifact() async throws {
    let fixture = try LinuxRuntimeOwnershipFixture()
    defer { fixture.remove() }
    let machine = try await fixture.prepare()
    let lease = try await fixture.library.acquireLinuxRuntime(id: machine.id)

    let completed = try await fixture.library.completeLinuxInstallation(lease: lease)

    #expect(completed.installState == .stopped)
    #expect(completed.linuxConfiguration?.installationMediaPath == nil)
    #expect(try await fixture.library.list() == [completed])
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.bundleURL(for: machine.id)
          .appending(path: LinuxPlatformArtifactURLs.installationMediaManifestPath).path
      )
    )
    lease.release()
  }

  @Test
  func releasedLeaseCannotCommitInstallationCompletion() async throws {
    let fixture = try LinuxRuntimeOwnershipFixture()
    defer { fixture.remove() }
    let machine = try await fixture.prepare()
    let lease = try await fixture.library.acquireLinuxRuntime(id: machine.id)
    lease.release()

    await #expect(
      throws: LinuxVirtualMachineRuntimeError.staleTarget(lease.target)
    ) {
      _ = try await fixture.library.completeLinuxInstallation(lease: lease)
    }
  }
}

private struct LinuxRuntimeOwnershipFixture {
  let rootURL: URL
  let libraryURL: URL
  let installationMediaURL: URL
  let library: VirtualMachineLibrary

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LinuxRuntimeOwnershipTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    libraryURL = rootURL.appending(path: "Library", directoryHint: .isDirectory)
    installationMediaURL = rootURL.appending(path: "Installer.iso")
    try Data("installer".utf8).write(to: installationMediaURL)
    library = VirtualMachineLibrary(
      rootURL: libraryURL,
      linuxPlatformArtifactPreparer: LinuxRuntimeOwnershipArtifactPreparer()
    )
  }

  func prepare() async throws -> VirtualMachineManifest {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Linux Runtime Ownership",
      guest: .linux,
      resources: resources
    )
    return try await library.prepareLinuxVM(
      id: draft.id,
      installationMediaURL: installationMediaURL
    )
  }

  func bundleURL(for identifier: UUID) -> URL {
    libraryURL
      .appending(path: identifier.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private struct LinuxRuntimeOwnershipArtifactPreparer: LinuxPlatformArtifactPreparing {
  func prepare(
    installationMediaURL: URL,
    destination: LinuxPlatformArtifactURLs
  ) async throws -> LinuxPlatformPreparationResult {
    try Data("efi".utf8).write(to: destination.efiVariableStore)
    try Data("machine".utf8).write(to: destination.machineIdentifier)
    try FileManager.default.copyItem(
      at: installationMediaURL,
      to: destination.installationMedia
    )
    return LinuxPlatformPreparationResult(macAddress: "02:00:00:00:00:02")
  }
}
