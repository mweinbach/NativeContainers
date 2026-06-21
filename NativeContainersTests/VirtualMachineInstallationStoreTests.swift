import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineInstallationStoreTests {
  @Test
  func installationLeaseTransitionsToStoppedOnlyForMatchingOperation() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()

    let resolved = try await fixture.library.stageMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    var installing = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(resolved.manifest.id == manifest.id)
    #expect(installing.installState == .installing)
    #expect(installing.installationOperationID == operationID)

    await #expect(throws: MacVirtualMachineInstallationError.staleOperation(manifest.id)) {
      try await fixture.library.completeMacOSInstallation(
        id: manifest.id,
        operationID: UUID()
      )
    }

    try await fixture.library.completeMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    installing = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(installing.installState == .stopped)
    #expect(installing.installationOperationID == nil)
    #expect(installing.installationFailure == nil)
    #expect(installing.diskImagePath == "Installed/Disk.img")
    #expect(installing.auxiliaryStoragePath == "Installed/AuxiliaryStorage")
  }

  @Test
  func failedInstallRetainsTypedRecoveryReason() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()

    _ = try await fixture.library.stageMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.abortMacOSInstallation(
      id: manifest.id,
      operationID: operationID,
      kind: .cancelled,
      message: "Cancelled by test"
    )

    let failed = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(failed.installState == .readyToInstall)
    #expect(failed.installationOperationID == nil)
    #expect(failed.installationFailure?.kind == .cancelled)
    #expect(failed.installationFailure?.message == "Cancelled by test")
  }

  @Test
  func launchRecoveryRemovesAWorkspaceStagedBeforeLeaseCommit() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()
    let staged = try await fixture.simulateInterruptedInstallation(
      id: manifest.id,
      operationID: operationID,
      begin: false
    )
    let stagingDirectory = staged.diskImageURL.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: stagingDirectory.path))

    try await fixture.library.recoverInterruptedMacOSInstallations()

    let existsAfterRecovery = FileManager.default.fileExists(atPath: stagingDirectory.path)
    #expect(existsAfterRecovery == false)
    let recovered = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(recovered.installState == .readyToInstall)
  }

  @Test
  func discardRemovesAStoppedOrPreparedBundleButNeverAnActiveInstall() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()
    _ = try await fixture.library.stageMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )

    await #expect(throws: VirtualMachineModelError.invalidInstallState(.installing)) {
      try await fixture.library.discardVirtualMachine(id: manifest.id)
    }

    try await fixture.library.abortMacOSInstallation(
      id: manifest.id,
      operationID: operationID,
      kind: .cancelled,
      message: "Cancelled"
    )
    try await fixture.library.discardVirtualMachine(id: manifest.id)
    #expect(try await fixture.library.list().isEmpty)
  }

  @Test
  func launchRecoveryMarksOrphanedInstallationInterrupted() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()

    let operationID = UUID()
    _ = try await fixture.simulateInterruptedInstallation(
      id: manifest.id,
      operationID: operationID,
      begin: true
    )
    try await fixture.library.recoverInterruptedMacOSInstallations()

    let recovered = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(recovered.installState == .readyToInstall)
    #expect(recovered.installationFailure?.kind == .interrupted)
    #expect(recovered.installationFailure?.message.contains("app exited") == true)
  }

  @Test
  func competingProcessRecoveryLeavesALiveInstallationLeaseUntouched() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()
    let staged = try await fixture.library.stageMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )

    let competingLibrary = VirtualMachineLibrary(
      rootURL: fixture.libraryRoot,
      macPlatformArtifactPreparer: InstallationStoreArtifactPreparer()
    )
    try await competingLibrary.recoverInterruptedMacOSInstallations()

    let stillInstalling = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(stillInstalling.installState == .installing)
    #expect(FileManager.default.fileExists(atPath: staged.diskImageURL.path))

    try await fixture.library.abortMacOSInstallation(
      id: manifest.id,
      operationID: operationID,
      kind: .cancelled,
      message: "Cancelled by test"
    )
  }
}

private struct InstallationStoreFixture {
  let root: URL
  let libraryRoot: URL
  let library: VirtualMachineLibrary
  let restoreImage: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-InstallationStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
    restoreImage = root.appending(path: "Restore.ipsw")
    try Data([0x50]).write(to: restoreImage)
    library = VirtualMachineLibrary(
      rootURL: libraryRoot,
      macPlatformArtifactPreparer: InstallationStoreArtifactPreparer()
    )
  }

  func prepare() async throws -> VirtualMachineManifest {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Installation Store",
      guest: .macOS,
      resources: resources
    )
    return try await library.prepareMacVM(
      id: draft.id,
      restoreImageURL: restoreImage
    )
  }

  func simulateInterruptedInstallation(
    id: UUID,
    operationID: UUID,
    begin: Bool
  ) async throws -> PreparedMacVirtualMachine {
    let interruptedLibrary = VirtualMachineLibrary(
      rootURL: libraryRoot,
      macPlatformArtifactPreparer: InstallationStoreArtifactPreparer()
    )
    let staged = try await interruptedLibrary.stageMacOSInstallation(
      id: id,
      operationID: operationID
    )
    if begin {
      try await interruptedLibrary.beginMacOSInstallation(
        id: id,
        operationID: operationID
      )
    }
    return staged
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct InstallationStoreArtifactPreparer: MacPlatformArtifactPreparing {
  func prepare(
    restoreImageURL: URL,
    resources: VirtualMachineResources,
    destination: MacPlatformArtifactURLs
  ) async throws {
    try Data([1]).write(to: destination.auxiliaryStorage)
    try Data([2]).write(to: destination.hardwareModel)
    try Data([3]).write(to: destination.machineIdentifier)
  }
}
