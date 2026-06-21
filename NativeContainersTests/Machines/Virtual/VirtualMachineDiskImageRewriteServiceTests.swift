import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageRewriteServiceTests {
  @Test
  func commitsASmallerStandaloneASIFCandidate() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeService(
      fixture: fixture,
      store: store,
      sourceAllocatedBytes: 16_384,
      candidateAllocatedBytes: 4_096
    )

    let result = try await service.rewriteASIF(
      machineID: fixture.manifest.id
    )

    #expect(result.didReplace)
    #expect(result.reclaimedBytes == 12_288)
    #expect(store.commits.count == 1)
    #expect(result.manifest.effectiveDiskImageFormat == .asif)
    #expect(result.manifest.diskImagePath.hasPrefix("Installed/Disk-"))
    #expect(result.manifest.diskImagePath.hasSuffix(".asif"))
    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.bundleURL
          .appending(path: result.manifest.diskImagePath).path
      )
    )
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore()
        .load(in: fixture.bundleURL) == nil
    )
    #expect(try rewritePartials(in: fixture.installedURL).isEmpty)
  }

  @Test(arguments: [4_096 as UInt64, 8_192])
  func keepsTheSourceWhenTheCandidateDoesNotReduceAllocation(
    candidateAllocatedBytes: UInt64
  ) async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeService(
      fixture: fixture,
      store: store,
      sourceAllocatedBytes: 4_096,
      candidateAllocatedBytes: candidateAllocatedBytes
    )

    let result = try await service.rewriteASIF(
      machineID: fixture.manifest.id
    )

    #expect(!result.didReplace)
    #expect(result.reclaimedBytes == 0)
    #expect(result.manifest == fixture.manifest)
    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(try permanentCandidates(in: fixture.installedURL).isEmpty)
    #expect(try rewritePartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore()
        .load(in: fixture.bundleURL) == nil
    )
  }

  @Test
  func rejectsRAWWithoutInvokingTheConverter() async throws {
    let fixture = try RewriteFixture(format: .raw)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let converter = RewriteConverter()
    let service = makeService(
      fixture: fixture,
      store: store,
      converter: converter
    )

    await #expect(throws: VirtualMachineDiskImageReplacementError.requiresASIF) {
      _ = try await service.rewriteASIF(machineID: fixture.manifest.id)
    }

    #expect(await converter.callCount == 0)
    #expect(store.commits.isEmpty)
  }

  @Test
  func rejectsSavedStateBeforeCreatingAJournal() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let summary = MacVirtualMachineSavedStateSummary(
      createdAt: Date(),
      stateSizeBytes: 4_096
    )
    let service = makeService(
      fixture: fixture,
      store: store,
      savedState: .available(summary)
    )

    await #expect(
      throws: VirtualMachineDiskImageReplacementError
        .savedStateMustBeDiscarded
    ) {
      _ = try await service.rewriteASIF(machineID: fixture.manifest.id)
    }

    #expect(store.commits.isEmpty)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore()
        .load(in: fixture.bundleURL) == nil
    )
  }

  @Test
  func rejectsStackedASIFSources() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeService(
      fixture: fixture,
      store: store,
      sourceLayerType: .overlay
    )

    await #expect(
      throws: VirtualMachineDiskImageReplacementError.stackedImageUnsupported
    ) {
      _ = try await service.rewriteASIF(machineID: fixture.manifest.id)
    }

    #expect(store.commits.isEmpty)
  }

  @Test
  func rejectsCapacityOrBlockGeometryChangesAndRollsBack() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeService(
      fixture: fixture,
      store: store,
      candidateBlockSizeBytes: 4_096
    )

    await #expect(
      throws: VirtualMachineDiskImageReplacementError.blockSizeMismatch(
        expected: 512,
        actual: 4_096
      )
    ) {
      _ = try await service.rewriteASIF(machineID: fixture.manifest.id)
    }

    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(try rewritePartials(in: fixture.installedURL).isEmpty)
  }

  @Test
  func converterFailureRemovesOnlyItsPrivatePartial() async throws {
    let fixture = try RewriteFixture(format: .asif)
    defer { fixture.remove() }
    let store = RewriteStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let converter = RewriteConverter(behavior: .failAfterWriting)
    let service = makeService(
      fixture: fixture,
      store: store,
      converter: converter
    )

    await #expect(throws: RewriteTestError.expected) {
      _ = try await service.rewriteASIF(machineID: fixture.manifest.id)
    }

    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(try rewritePartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore()
        .load(in: fixture.bundleURL) == nil
    )
  }

  private func makeService(
    fixture: RewriteFixture,
    store: RewriteStoreDouble,
    converter: RewriteConverter = RewriteConverter(),
    savedState: MacVirtualMachineSavedStateStatus = .none,
    sourceAllocatedBytes: UInt64 = 8_192,
    candidateAllocatedBytes: UInt64 = 4_096,
    sourceLayerType: VirtualMachineDiskImageLayerType? = nil,
    candidateBlockSizeBytes: UInt64 = 512
  ) -> VirtualMachineDiskImageRewriteService {
    VirtualMachineDiskImageRewriteService(
      store: store,
      savedStates: RewriteSavedStateInspector(status: savedState),
      converter: converter,
      imageInspector: RewriteDiskImageInspector(
        sourceURL: fixture.sourceURL,
        logicalBytes: fixture.manifest.resources.diskBytes,
        sourceLayerType: sourceLayerType,
        candidateBlockSizeBytes: candidateBlockSizeBytes
      ),
      artifactInspector: RewriteArtifactInspector(
        sourceMarker: fixture.sourceMarker,
        candidateMarker: RewriteConverter.candidateMarker,
        sourceAllocatedBytes: sourceAllocatedBytes,
        candidateAllocatedBytes: candidateAllocatedBytes
      )
    )
  }

  private func rewritePartials(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter {
      VirtualMachineDiskImageReplacementArtifacts.isControlArtifact(
        relativePath: $0.lastPathComponent
      )
    }
  }

  private func permanentCandidates(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix("Disk-")
        && $0.pathExtension.lowercased() == "asif"
    }
  }
}
