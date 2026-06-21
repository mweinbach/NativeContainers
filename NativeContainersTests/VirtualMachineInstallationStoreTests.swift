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

    let resolved = try await fixture.library.resolvePreparedMacVM(id: manifest.id)
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
  }

  @Test
  func failedInstallRetainsTypedRecoveryReason() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()
    let operationID = UUID()

    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: operationID
    )
    try await fixture.library.failMacOSInstallation(
      id: manifest.id,
      operationID: operationID,
      kind: .cancelled,
      message: "Cancelled by test"
    )

    let failed = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(failed.installState == .failed)
    #expect(failed.installationOperationID == nil)
    #expect(failed.installationFailure?.kind == .cancelled)
    #expect(failed.installationFailure?.message == "Cancelled by test")
  }

  @Test
  func launchRecoveryMarksOrphanedInstallationInterrupted() async throws {
    let fixture = try InstallationStoreFixture()
    defer { fixture.remove() }
    let manifest = try await fixture.prepare()

    try await fixture.library.beginMacOSInstallation(
      id: manifest.id,
      operationID: UUID()
    )
    try await fixture.library.recoverInterruptedMacOSInstallations()

    let recovered = try #require(
      try await fixture.library.list().first { $0.id == manifest.id }
    )
    #expect(recovered.installState == .failed)
    #expect(recovered.installationFailure?.kind == .interrupted)
    #expect(recovered.installationFailure?.message.contains("app exited") == true)
  }
}

private struct InstallationStoreFixture {
  let root: URL
  let library: VirtualMachineLibrary
  let restoreImage: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-InstallationStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    restoreImage = root.appending(path: "Restore.ipsw")
    try Data([0x50]).write(to: restoreImage)
    library = VirtualMachineLibrary(
      rootURL: root.appending(path: "Library", directoryHint: .isDirectory),
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
