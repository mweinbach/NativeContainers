import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct VirtualMachineTransferServiceTests {
  @Test
  func exportPreservesIdentityAndStripsHostLocalState() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Portable Mac",
      includeHostLocalState: true
    )
    let sourceBundle = fixture.bundleURL(root: fixture.sourceLibraryRoot, id: source.id)
    let sourceIdentifier = try fixture.machineIdentifier(in: sourceBundle, manifest: source)
    let destination = fixture.root.appending(
      path: "Portable Mac.nativevm",
      directoryHint: .isDirectory
    )
    let service = fixture.service(library: fixture.sourceLibrary)

    let receipt = try await service.exportVirtualMachine(
      id: source.id,
      to: destination
    )

    #expect(
      receipt == VirtualMachineExportReceipt(machineID: source.id, destinationURL: destination))
    let exported = try fixture.readManifest(in: destination)
    #expect(exported.id == source.id)
    #expect(exported.name == source.name)
    #expect(exported.installState == .stopped)
    #expect(exported.restoreImageURL == nil)
    #expect(exported.installationOperationID == nil)
    #expect(exported.installationFailure == nil)
    #expect(try fixture.machineIdentifier(in: destination, manifest: exported) == sourceIdentifier)
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appending(
          path: MacVirtualMachineSavedStateStore.directoryName
        ).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appending(
          path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
        ).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appending(
          path: VirtualMachineLibrary.runtimeOwnerFilename
        ).path
      )
    )

    #expect(
      FileManager.default.fileExists(
        atPath: sourceBundle.appending(
          path: MacVirtualMachineSavedStateStore.directoryName
        ).path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: sourceBundle.appending(
          path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
        ).path
      )
    )
    #expect(try fixture.readManifest(in: sourceBundle).restoreImageURL != nil)
    try fixture.expectNoExportPartials()
  }

  @Test
  func exportNeverReplacesAnExistingDestination() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "No Replace"
    )
    let destination = fixture.root.appending(
      path: "Existing.nativevm",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    await #expect(
      throws: VirtualMachineTransferError.destinationExists(destination)
    ) {
      _ = try await fixture.service(library: fixture.sourceLibrary)
        .exportVirtualMachine(id: source.id, to: destination)
    }

    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    try fixture.expectNoExportPartials()
  }

  @Test
  func exportCancellationRemovesPartialAndReleasesSourceLease() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Cancellable Export"
    )
    let blocker = BlockingVirtualMachineBundlePreparer()
    let cancellingService = fixture.service(
      library: fixture.sourceLibrary,
      preparer: blocker
    )
    let cancelledDestination = fixture.root.appending(
      path: "Cancelled.nativevm",
      directoryHint: .isDirectory
    )
    let task = Task {
      try await cancellingService.exportVirtualMachine(
        id: source.id,
        to: cancelledDestination
      )
    }

    await blocker.waitUntilStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: cancelledDestination.path))
    try fixture.expectNoExportPartials()

    let retryDestination = fixture.root.appending(
      path: "Retry.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: retryDestination)
    #expect(FileManager.default.fileExists(atPath: retryDestination.path))
  }

  @Test
  func exportRefusesMachineOwnedByRuntimeSession() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Busy Mac"
    )
    let runtimeLease = try await fixture.sourceLibrary.acquireMacOSRuntime(id: source.id)
    defer { runtimeLease.release() }

    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(source.id)) {
      _ = try await fixture.service(library: fixture.sourceLibrary)
        .exportVirtualMachine(
          id: source.id,
          to: fixture.root.appending(path: "Busy.nativevm")
        )
    }
    try fixture.expectNoExportPartials()
  }

  @Test
  func exportRejectsPendingDiskMigrationJournalBeforeCopy() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Pending Migration"
    )
    let sourceBundle = fixture.bundleURL(
      root: fixture.sourceLibraryRoot,
      id: source.id
    )
    try Data("pending".utf8).write(
      to: sourceBundle.appending(
        path: VirtualMachineDiskImageMigrationArtifacts.journalFilename
      )
    )
    let destination = fixture.root.appending(path: "Rejected.nativevm")

    await #expect(throws: VirtualMachineBundleError.self) {
      _ = try await fixture.service(library: fixture.sourceLibrary)
        .exportVirtualMachine(id: source.id, to: destination)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    try fixture.expectNoExportPartials()
  }

  @Test
  func preserveImportRoundTripsManifestAndPlatformIdentity() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Round Trip",
      includeHostLocalState: true
    )
    let package = fixture.root.appending(
      path: "Round Trip.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: package)
    let packageManifest = try fixture.readManifest(in: package)
    let packageIdentifier = try fixture.machineIdentifier(
      in: package,
      manifest: packageManifest
    )

    let imported = try await fixture.service(library: fixture.importLibrary)
      .importVirtualMachine(from: package, mode: .preserveIdentity)

    #expect(imported == packageManifest)
    #expect(imported.id == source.id)
    let importedBundle = fixture.bundleURL(root: fixture.importLibraryRoot, id: imported.id)
    #expect(
      try fixture.machineIdentifier(in: importedBundle, manifest: imported)
        == packageIdentifier
    )
    #expect(try await fixture.importLibrary.list() == [imported])
    #expect(FileManager.default.fileExists(atPath: package.path))
    try fixture.expectNoImportPartials()
  }

  @Test
  func cloneImportCreatesFreshManifestAndPlatformIdentities() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Identity Source"
    )
    let package = fixture.root.appending(
      path: "Identity Source.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: package)
    let packageManifest = try fixture.readManifest(in: package)
    let packageIdentifier = try fixture.machineIdentifier(
      in: package,
      manifest: packageManifest
    )

    let imported = try await fixture.service(library: fixture.importLibrary)
      .importVirtualMachine(from: package, mode: .clone(name: "Identity Copy"))

    #expect(imported.id != source.id)
    #expect(imported.name == "Identity Copy")
    #expect(imported.createdAt != source.createdAt)
    #expect(imported.restoreImageURL == nil)
    let importedBundle = fixture.bundleURL(root: fixture.importLibraryRoot, id: imported.id)
    let importedIdentifier = try fixture.machineIdentifier(
      in: importedBundle,
      manifest: imported
    )
    #expect(importedIdentifier != packageIdentifier)
    #expect(
      AppleMacVirtualMachineIdentifierGenerator()
        .isValidIdentifierData(importedIdentifier)
    )
    try fixture.expectNoImportPartials()
  }

  @Test
  func importRejectsNestedDiskMigrationPartialBeforeCopy() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Migration Partial"
    )
    let package = fixture.root.appending(
      path: "Migration Partial.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: package)
    let operationID = UUID()
    let partial = package.appending(
      path:
        "MacPlatform/\(VirtualMachineDiskImageMigrationArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageMigrationArtifacts.stagingSuffix)"
    )
    try Data("partial".utf8).write(to: partial)

    await #expect(throws: VirtualMachineBundleError.self) {
      _ = try await fixture.service(library: fixture.importLibrary)
        .importVirtualMachine(from: package, mode: .preserveIdentity)
    }

    #expect(try await fixture.importLibrary.list().isEmpty)
    try fixture.expectNoImportPartials()
  }

  @Test
  func preserveImportRejectsExistingManifestIdentityBeforeCopy() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Existing Identity"
    )
    let package = fixture.root.appending(
      path: "Existing Identity.nativevm",
      directoryHint: .isDirectory
    )
    let service = fixture.service(library: fixture.sourceLibrary)
    _ = try await service.exportVirtualMachine(id: source.id, to: package)

    await #expect(
      throws: VirtualMachineTransferError.identityCollision(source.id)
    ) {
      _ = try await service.importVirtualMachine(
        from: package,
        mode: .preserveIdentity
      )
    }

    #expect(try await fixture.sourceLibrary.list() == [source])
    try fixture.expectNoImportPartials(in: fixture.sourceLibraryRoot)
  }

  @Test
  func preserveImportRejectsPlatformIdentityCollisionWithDifferentManifestID() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let sharedIdentifier = try AppleMacVirtualMachineIdentifierGenerator()
      .makeIdentifierData()
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "External Identity",
      machineIdentifier: sharedIdentifier
    )
    let existing = try await fixture.makeStoppedMachine(
      library: fixture.importLibrary,
      libraryRoot: fixture.importLibraryRoot,
      name: "Existing Other VM",
      machineIdentifier: sharedIdentifier
    )
    #expect(existing.id != source.id)
    let package = fixture.root.appending(
      path: "External Identity.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: package)

    await #expect(
      throws: VirtualMachineTransferError.platformIdentityCollision
    ) {
      _ = try await fixture.service(library: fixture.importLibrary)
        .importVirtualMachine(from: package, mode: .preserveIdentity)
    }

    #expect(try await fixture.importLibrary.list() == [existing])
    try fixture.expectNoImportPartials()
  }

  @Test
  func importCancellationAbortsStagingAndReleasesLibraryLock() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let source = try await fixture.makeStoppedMachine(
      library: fixture.sourceLibrary,
      libraryRoot: fixture.sourceLibraryRoot,
      name: "Cancellable Import"
    )
    let package = fixture.root.appending(
      path: "Cancellable Import.nativevm",
      directoryHint: .isDirectory
    )
    _ = try await fixture.service(library: fixture.sourceLibrary)
      .exportVirtualMachine(id: source.id, to: package)
    let blocker = BlockingVirtualMachineBundlePreparer()
    let cancellingService = fixture.service(
      library: fixture.importLibrary,
      preparer: blocker
    )
    let task = Task {
      try await cancellingService.importVirtualMachine(
        from: package,
        mode: .preserveIdentity
      )
    }

    await blocker.waitUntilStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(try await fixture.importLibrary.list().isEmpty)
    try fixture.expectNoImportPartials()

    let imported = try await fixture.service(library: fixture.importLibrary)
      .importVirtualMachine(from: package, mode: .preserveIdentity)
    #expect(imported.id == source.id)
  }

  @Test
  func recoveryRemovesInterruptedImportStagingPackage() async throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let orphan = fixture.importLibraryRoot.appending(
      path:
        "\(VirtualMachineLibrary.importStagingPrefix)orphan\(VirtualMachineLibrary.importStagingSuffix)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: orphan,
      withIntermediateDirectories: true
    )
    try Data("partial".utf8).write(to: orphan.appending(path: "partial.data"))

    let result = try await fixture.importLibrary.recoverInterruptedMacOSInstallations()

    #expect(result == .recovered)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
  }

  @Test
  func inspectorRejectsSymbolicHardLinkedAndSpecialEntries() throws {
    let fixture = try VirtualMachineTransferFixture()
    defer { fixture.remove() }
    let inspector = FileVirtualMachineBundleInspector()

    let symbolicRoot = fixture.root.appending(
      path: "Symbolic.nativevm",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: symbolicRoot,
      withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
      at: symbolicRoot.appending(path: "link"),
      withDestinationURL: fixture.root
    )
    #expect(throws: VirtualMachineBundleError.self) {
      _ = try inspector.snapshot(of: symbolicRoot)
    }

    let hardLinkRoot = fixture.root.appending(
      path: "HardLink.nativevm",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: hardLinkRoot,
      withIntermediateDirectories: false
    )
    let original = hardLinkRoot.appending(path: "original")
    try Data("data".utf8).write(to: original)
    try FileManager.default.linkItem(
      at: original,
      to: hardLinkRoot.appending(path: "linked")
    )
    #expect(throws: VirtualMachineBundleError.self) {
      _ = try inspector.snapshot(of: hardLinkRoot)
    }

    let fifoRoot = fixture.root.appending(
      path: "FIFO.nativevm",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: fifoRoot,
      withIntermediateDirectories: false
    )
    let fifo = fifoRoot.appending(path: "pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: VirtualMachineBundleError.self) {
      _ = try inspector.snapshot(of: fifoRoot)
    }
  }
}

private struct VirtualMachineTransferFixture {
  let root: URL
  let sourceLibraryRoot: URL
  let importLibraryRoot: URL
  let sourceLibrary: VirtualMachineLibrary
  let importLibrary: VirtualMachineLibrary

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-VMTransfer-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    sourceLibraryRoot = root.appending(
      path: "SourceLibrary",
      directoryHint: .isDirectory
    )
    importLibraryRoot = root.appending(
      path: "ImportLibrary",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    sourceLibrary = VirtualMachineLibrary(rootURL: sourceLibraryRoot)
    importLibrary = VirtualMachineLibrary(rootURL: importLibraryRoot)
  }

  func service(
    library: VirtualMachineLibrary,
    preparer: any VirtualMachineBundlePreparing =
      VirtualMachineBundlePreparationService()
  ) -> VirtualMachineTransferService {
    VirtualMachineTransferService(
      exportStore: library,
      importStore: library,
      preparer: preparer
    )
  }

  func makeStoppedMachine(
    library: VirtualMachineLibrary,
    libraryRoot: URL,
    name: String,
    machineIdentifier: Data? = nil,
    includeHostLocalState: Bool = false
  ) async throws -> VirtualMachineManifest {
    let draft = try await library.createDraft(
      name: name,
      guest: .macOS,
      resources: try VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB
      )
    )
    let bundle = bundleURL(root: libraryRoot, id: draft.id)
    let artifactDirectory = bundle.appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: false
    )
    let artifacts = MacPlatformArtifactURLs(directory: artifactDirectory)
    try Data("auxiliary".utf8).write(to: artifacts.auxiliaryStorage)
    try Data("hardware".utf8).write(to: artifacts.hardwareModel)
    let identifier =
      try machineIdentifier
      ?? AppleMacVirtualMachineIdentifierGenerator().makeIdentifierData()
    try identifier.write(to: artifacts.machineIdentifier)

    let restoreImage = root.appending(path: "\(draft.id.uuidString).ipsw")
    try Data("restore".utf8).write(to: restoreImage)
    var stopped = draft
    stopped.installState = .stopped
    stopped.updatedAt = Date()
    stopped.restoreImageURL = restoreImage
    stopped.auxiliaryStoragePath = MacPlatformArtifactURLs.auxiliaryStorageManifestPath
    stopped.hardwareModelPath = MacPlatformArtifactURLs.hardwareModelManifestPath
    stopped.machineIdentifierPath = MacPlatformArtifactURLs.machineIdentifierManifestPath
    try write(stopped, to: bundle)

    if includeHostLocalState {
      let savedState = bundle.appending(
        path: MacVirtualMachineSavedStateStore.directoryName,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: savedState,
        withIntermediateDirectories: false
      )
      try Data("state".utf8).write(
        to: savedState.appending(path: MacVirtualMachineSavedStateStore.stateFilename)
      )
      try Data("owner".utf8).write(
        to: bundle.appending(path: VirtualMachineLibrary.runtimeOwnerFilename)
      )
      try Data("bookmarks".utf8).write(
        to: bundle.appending(
          path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
        )
      )
    }
    return stopped
  }

  func machineIdentifier(
    in bundleURL: URL,
    manifest: VirtualMachineManifest
  ) throws -> Data {
    let path = try #require(manifest.machineIdentifierPath)
    return try Data(contentsOf: bundleURL.appending(path: path))
  }

  func readManifest(in bundleURL: URL) throws -> VirtualMachineManifest {
    try JSONDecoder().decode(
      VirtualMachineManifest.self,
      from: Data(
        contentsOf: bundleURL.appending(
          path: VirtualMachineLibrary.manifestFilename
        )
      )
    )
  }

  func write(
    _ manifest: VirtualMachineManifest,
    to bundleURL: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename),
      options: .atomic
    )
  }

  func bundleURL(root: URL, id: UUID) -> URL {
    root
      .appending(
        path: id.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  func expectNoExportPartials() throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    #expect(
      entries.allSatisfy {
        !$0.lastPathComponent.hasPrefix(".NativeContainersExport-")
      }
    )
  }

  func expectNoImportPartials(in directory: URL? = nil) throws {
    let root = directory ?? importLibraryRoot
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    let entries = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    #expect(
      entries.allSatisfy {
        !$0.lastPathComponent.hasPrefix(VirtualMachineLibrary.importStagingPrefix)
      }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor BlockingVirtualMachineBundlePreparer:
  VirtualMachineBundlePreparing
{
  private var started = false
  private var cancelled = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var operationContinuation: CheckedContinuation<Void, Never>?

  func prepare(_ request: VirtualMachineBundlePreparationRequest) async throws {
    try FileManager.default.createDirectory(
      at: request.destinationBundleURL,
      withIntermediateDirectories: false
    )
    try Data("partial".utf8).write(
      to: request.destinationBundleURL.appending(path: "partial.data")
    )
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancelled {
          continuation.resume()
        } else {
          operationContinuation = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel() }
    }
    try Task.checkCancellation()
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  private func cancel() {
    cancelled = true
    operationContinuation?.resume()
    operationContinuation = nil
  }
}
