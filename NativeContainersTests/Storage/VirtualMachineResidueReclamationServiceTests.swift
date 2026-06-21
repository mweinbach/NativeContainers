import Foundation
import Testing

@testable import NativeContainers

@Suite("VM interrupted-residue reclamation")
struct VirtualMachineResidueReclamationServiceTests {
  @Test
  func discoversAndRemovesOnlyExactAllowlistedResidue() async throws {
    let fixture = try await ResidueFixture()
    defer { fixture.remove() }

    let rootResidue = fixture.rootURL.appending(
      path: ".Clone-\(UUID().uuidString)-\(UUID().uuidString).partial",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootResidue,
      withIntermediateDirectories: false
    )
    try Data("clone".utf8).write(to: rootResidue.appending(path: "payload"))

    let bundleResidue = fixture.bundleURL.appending(
      path: ".\(MacPlatformArtifactURLs.directoryName).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: bundleResidue,
      withIntermediateDirectories: false
    )
    try Data("platform".utf8).write(
      to: bundleResidue.appending(path: "payload")
    )

    let unknown = fixture.rootURL.appending(
      path: ".Unknown-\(UUID().uuidString).partial",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: unknown,
      withIntermediateDirectories: false
    )

    let plan = try await fixture.service
      .prepareInterruptedResidueReclamation()
    let result = try await fixture.service.reclaimInterruptedResidue(plan)

    #expect(plan.candidates.map(\.kind).contains(.cloneStaging))
    #expect(plan.candidates.map(\.kind).contains(.platformStaging))
    #expect(plan.candidates.count == 2)
    #expect(result.removedCandidateIDs.count == 2)
    #expect(!FileManager.default.fileExists(atPath: rootResidue.path))
    #expect(!FileManager.default.fileExists(atPath: bundleResidue.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
  }

  @Test
  func replacementAtAReviewedNameIsSkipped() async throws {
    let fixture = try await ResidueFixture()
    defer { fixture.remove() }
    let entryName =
      ".Import-\(UUID().uuidString)-\(UUID().uuidString).partial"
    let residue = fixture.rootURL.appending(
      path: entryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: residue,
      withIntermediateDirectories: false
    )
    try Data("first".utf8).write(to: residue.appending(path: "payload"))
    let plan = try await fixture.service.prepareInterruptedResidueReclamation()
    let candidate = try #require(
      plan.candidates.first(where: { $0.entryName == entryName })
    )

    try FileManager.default.removeItem(at: residue)
    try FileManager.default.createDirectory(
      at: residue,
      withIntermediateDirectories: false
    )
    try Data("replacement".utf8).write(to: residue.appending(path: "payload"))

    let result = try await fixture.service.reclaimInterruptedResidue(
      VirtualMachineStorageResidueReclamationPlan(
        candidates: [candidate],
        issues: []
      )
    )

    #expect(result.removedCandidateIDs.isEmpty)
    #expect(result.staleCandidateIDs == [candidate.id])
    #expect(
      try Data(contentsOf: residue.appending(path: "payload"))
        == Data("replacement".utf8))
  }

  @Test
  func symbolicAndHardLinkedCandidatesFailClosed() async throws {
    let fixture = try await ResidueFixture()
    defer { fixture.remove() }
    let outside = fixture.rootURL.appending(path: "outside")
    try Data("outside".utf8).write(to: outside)

    let symlinkName =
      ".SharedDirectories-\(UUID().uuidString).partial"
    let symlink = fixture.bundleURL.appending(path: symlinkName)
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: outside
    )

    let hardLinkDirectory = fixture.rootURL.appending(
      path: ".Deletion-\(UUID().uuidString)-\(UUID().uuidString).partial",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: hardLinkDirectory,
      withIntermediateDirectories: false
    )
    try FileManager.default.linkItem(
      at: outside,
      to: hardLinkDirectory.appending(path: "linked")
    )

    let plan = try await fixture.service.prepareInterruptedResidueReclamation()

    #expect(plan.candidates.isEmpty)
    #expect(plan.issues.count == 2)
    #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    #expect(FileManager.default.fileExists(atPath: symlink.path))
    #expect(FileManager.default.fileExists(atPath: hardLinkDirectory.path))
  }

  @Test
  func activeLibraryOperationLockFailsClosed() async throws {
    let fixture = try await ResidueFixture()
    defer { fixture.remove() }
    let lock = try #require(
      try AdvisoryFileLock.acquire(
        at: fixture.rootURL.appending(
          path: VirtualMachineLibrary.operationLockFilename
        )
      )
    )
    defer { lock.release() }

    await #expect(throws: VirtualMachineStorageReclamationError.libraryInUse) {
      try await fixture.service.prepareInterruptedResidueReclamation()
    }
  }
}

private struct ResidueFixture {
  let rootURL: URL
  let bundleURL: URL
  let library: VirtualMachineLibrary
  let service: VirtualMachineResidueReclamationService

  init() async throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    library = VirtualMachineLibrary(rootURL: rootURL)
    let manifest = try await library.createDraft(
      name: "Residue Test VM",
      guest: .macOS,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB
      )
    )
    bundleURL =
      rootURL
      .appending(
        path: manifest.id.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    service = VirtualMachineResidueReclamationService(inventory: library)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
