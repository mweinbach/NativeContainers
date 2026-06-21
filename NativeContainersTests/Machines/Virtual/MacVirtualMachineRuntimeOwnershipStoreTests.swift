import Foundation
import Testing

@testable import NativeContainers

struct MacVirtualMachineRuntimeOwnershipStoreTests {
  @Test
  func runtimeLeasePinsOneGenerationAndBlocksCompetingStartAndDiscard() async throws {
    let fixture = try RuntimeOwnershipFixture()
    defer { fixture.remove() }
    let machine = try await fixture.install()
    try FileManager.default.removeItem(at: fixture.restoreImageURL)

    let firstLease = try await fixture.library.acquireMacOSRuntime(id: machine.id)
    let competingLibrary = VirtualMachineLibrary(rootURL: fixture.libraryURL)

    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(machine.id)) {
      _ = try await competingLibrary.acquireMacOSRuntime(id: machine.id)
    }
    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(machine.id)) {
      try await competingLibrary.discardVirtualMachine(id: machine.id)
    }

    firstLease.release()
    let secondLease = try await competingLibrary.acquireMacOSRuntime(id: machine.id)
    #expect(secondLease.target.generation != firstLease.target.generation)
    secondLease.release()
  }

  @Test
  func ownerSidecarIsInformationalAndRemovedBeforeUnlock() async throws {
    let launchID = UUID()
    let fixture = try RuntimeOwnershipFixture(launchID: launchID)
    defer { fixture.remove() }
    let machine = try await fixture.install()

    let lease = try await fixture.library.acquireMacOSRuntime(id: machine.id)
    let ownerURL = fixture.bundleURL(for: machine.id).appending(
      path: VirtualMachineLibrary.runtimeOwnerFilename
    )
    let owner = try JSONDecoder().decode(
      MacVirtualMachineRuntimeOwnerRecord.self,
      from: Data(contentsOf: ownerURL)
    )

    #expect(owner.machineID == machine.id)
    #expect(owner.generation == lease.target.generation)
    #expect(owner.launchID == launchID)
    #expect(owner.processID == ProcessInfo.processInfo.processIdentifier)

    lease.release()
    #expect(!FileManager.default.fileExists(atPath: ownerURL.path))
  }
}

private struct RuntimeOwnershipFixture {
  let rootURL: URL
  let libraryURL: URL
  let restoreImageURL: URL
  let library: VirtualMachineLibrary

  init(launchID: UUID = UUID()) throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-RuntimeOwnershipTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    libraryURL = rootURL.appending(path: "Library", directoryHint: .isDirectory)
    restoreImageURL = rootURL.appending(path: "Restore.ipsw")
    try Data([0x50]).write(to: restoreImageURL)
    library = VirtualMachineLibrary(
      rootURL: libraryURL,
      launchID: launchID,
      macPlatformArtifactPreparer: RuntimeOwnershipArtifactPreparer()
    )
  }

  func install() async throws -> VirtualMachineManifest {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try await library.createDraft(
      name: "Runtime Ownership",
      guest: .macOS,
      resources: resources
    )
    _ = try await library.prepareMacVM(id: draft.id, restoreImageURL: restoreImageURL)
    let operationID = UUID()
    _ = try await library.stageMacOSInstallation(id: draft.id, operationID: operationID)
    try await library.beginMacOSInstallation(id: draft.id, operationID: operationID)
    try await library.completeMacOSInstallation(id: draft.id, operationID: operationID)
    return try #require(try await library.list().first { $0.id == draft.id })
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

private struct RuntimeOwnershipArtifactPreparer: MacPlatformArtifactPreparing {
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
