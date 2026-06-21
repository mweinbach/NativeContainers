import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageMigrationServiceTests {
  @Test
  func migratesRAWOutOfPlaceThenCommitsAndRetiresTheSource() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let result = try await service.migrateToASIF(
      machineID: fixture.manifest.id
    )

    #expect(result.manifest.diskImagePath == "Installed/Disk.asif")
    #expect(result.manifest.effectiveDiskImageFormat == .asif)
    #expect(store.currentManifest == result.manifest)
    #expect(store.commits.count == 1)
    #expect(await converter.callCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    #expect(
      try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func refusesMigrationUntilSavedStateIsExplicitlyDiscarded() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let summary = MacVirtualMachineSavedStateSummary(
      createdAt: Date(),
      stateSizeBytes: 4_096
    )
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .available(summary),
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.savedStateMustBeDiscarded
    ) {
      _ = try await service.migrateToASIF(
        machineID: fixture.manifest.id
      )
    }

    #expect(await converter.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
  }

  @Test
  func conversionFailureRemovesItsPartialAndDurableJournal() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .failAfterWriting)
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    await #expect(throws: TestDiskMigrationError.expected) {
      _ = try await service.migrateToASIF(
        machineID: fixture.manifest.id
      )
    }

    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    #expect(try migrationPartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func cancellationRemovesItsPartialOnlyAfterTheConverterStops() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = BlockingMigrationConverter()
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let migration = Task {
      try await service.migrateToASIF(machineID: fixture.manifest.id)
    }
    await converter.waitUntilStarted()
    migration.cancel()
    await converter.resume()

    await #expect(throws: CancellationError.self) {
      _ = try await migration.value
    }
    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(try migrationPartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func rejectsAConvertedImageWithDifferentVirtualCapacity() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      asifLogicalBytes: fixture.manifest.resources.diskBytes - 512
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.logicalSizeMismatch(
        expected: fixture.manifest.resources.diskBytes,
        actual: fixture.manifest.resources.diskBytes - 512
      )
    ) {
      _ = try await service.migrateToASIF(
        machineID: fixture.manifest.id
      )
    }

    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    #expect(try migrationPartials(in: fixture.installedURL).isEmpty)
  }

  @Test
  func startupRecoveryRollsBackAnUncommittedPartial() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let sourceIdentity = try FileVirtualMachineStorageArtifactInspector().inspect(
      at: fixture.sourceURL
    )
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    try Data("partial".utf8).write(to: stagingURL)
    let journal = VirtualMachineDiskImageMigrationJournal(
      version: VirtualMachineDiskImageMigrationJournal.currentVersion,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath: "Installed/Disk.asif",
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      destinationIdentity: nil,
      phase: .planned
    )
    try FileVirtualMachineDiskImageMigrationJournalStore().save(
      journal,
      in: fixture.bundleURL
    )
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let service = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let report = try await service.recoverInterruptedMigrations()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(report.deferredMachineIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(
      try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func startupRecoveryFinishesCleanupAfterManifestCommit() async throws {
    var fixture = try MigrationFixture()
    defer { fixture.remove() }
    let inspector = FileVirtualMachineStorageArtifactInspector()
    let sourceIdentity = try inspector.inspect(at: fixture.sourceURL)
    let operationID = UUID()
    let stagingPath =
      "Installed/.DiskImageMigration-\(operationID.uuidString.lowercased()).asif.partial"
    let stagingURL = fixture.bundleURL.appending(path: stagingPath)
    try Data("converted-asif".utf8).write(to: stagingURL)
    let stagingIdentity = try inspector.inspect(at: stagingURL)
    var journal = VirtualMachineDiskImageMigrationJournal(
      version: VirtualMachineDiskImageMigrationJournal.currentVersion,
      operationID: operationID,
      machineID: fixture.manifest.id,
      sourcePath: fixture.manifest.diskImagePath,
      destinationPath: "Installed/Disk.asif",
      stagingPath: stagingPath,
      sourceIdentity: sourceIdentity,
      sourceLogicalBytes: fixture.manifest.resources.diskBytes,
      destinationIdentity: nil,
      phase: .planned
    )
    let journalStore = FileVirtualMachineDiskImageMigrationJournalStore()
    try journalStore.save(journal, in: fixture.bundleURL)
    journal.destinationIdentity = stagingIdentity
    journal.phase = .converted
    try journalStore.save(journal, in: fixture.bundleURL)
    try FileManager.default.moveItem(
      at: stagingURL,
      to: fixture.destinationURL
    )
    journal.destinationIdentity = try inspector.inspect(
      at: fixture.destinationURL
    )
    journal.phase = .promoted
    try journalStore.save(journal, in: fixture.bundleURL)
    fixture.manifest.markDiskImageMigrated(
      to: "Installed/Disk.asif",
      format: .asif
    )

    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let service = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let report = try await service.recoverInterruptedMigrations()

    #expect(report.recoveredMachineIDs == [fixture.manifest.id])
    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    #expect(try journalStore.load(in: fixture.bundleURL) == nil)
  }

  private func makeService(
    store: MigrationStoreDouble,
    converter: any VirtualMachineDiskImageConverting,
    savedState: MacVirtualMachineSavedStateStatus,
    logicalBytes: UInt64,
    asifLogicalBytes: UInt64? = nil
  ) -> VirtualMachineDiskImageMigrationService {
    VirtualMachineDiskImageMigrationService(
      store: store,
      savedStates: SavedStateInspectorDouble(status: savedState),
      converter: converter,
      imageInspector: StubDiskImageInspector(
        rawLogicalBytes: logicalBytes,
        asifLogicalBytes: asifLogicalBytes ?? logicalBytes
      )
    )
  }

  private func migrationPartials(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(".DiskImageMigration-")
    }
  }
}

private struct MigrationFixture {
  let rootURL: URL
  let bundleURL: URL
  let installedURL: URL
  let sourceURL: URL
  let destinationURL: URL
  var manifest: VirtualMachineManifest

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    bundleURL =
      rootURL
      .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    installedURL = bundleURL.appending(
      path: "Installed",
      directoryHint: .isDirectory
    )
    sourceURL = installedURL.appending(path: "Disk.img")
    destinationURL = installedURL.appending(path: "Disk.asif")
    try FileManager.default.createDirectory(
      at: installedURL,
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x5A, count: 8_192).write(to: sourceURL)
    let auxiliaryURL = installedURL.appending(path: "AuxiliaryStorage")
    let hardwareURL = bundleURL.appending(path: "HardwareModel")
    let identifierURL = bundleURL.appending(path: "MachineIdentifier")
    try Data("aux".utf8).write(to: auxiliaryURL)
    try Data("hardware".utf8).write(to: hardwareURL)
    try Data("identifier".utf8).write(to: identifierURL)

    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Migration Test",
      guest: .macOS,
      installState: .stopped,
      resources: resources,
      diskImagePath: "Installed/Disk.img"
    )
    manifest.auxiliaryStoragePath = "Installed/AuxiliaryStorage"
    manifest.hardwareModelPath = "HardwareModel"
    manifest.machineIdentifierPath = "MachineIdentifier"
    self.manifest = manifest
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

@MainActor
private final class MigrationStoreDouble:
  VirtualMachineDiskImageMigrationStoring
{
  private(set) var currentManifest: VirtualMachineManifest
  private(set) var commits: [VirtualMachineDiskImageMigrationCommit] = []
  private let bundleURL: URL

  init(manifest: VirtualMachineManifest, bundleURL: URL) {
    currentManifest = manifest
    self.bundleURL = bundleURL
  }

  func list() async throws -> [VirtualMachineManifest] {
    [currentManifest]
  }

  func acquireMacOSRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease {
    guard id == currentManifest.id else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let diskURL = bundleURL.appending(path: currentManifest.diskImagePath)
    let machine = ResolvedMacVirtualMachine(
      manifest: currentManifest,
      bundleURL: bundleURL,
      diskImageURL: diskURL,
      auxiliaryStorageURL: bundleURL.appending(
        path: currentManifest.auxiliaryStoragePath!
      ),
      hardwareModelURL: bundleURL.appending(
        path: currentManifest.hardwareModelPath!
      ),
      machineIdentifierURL: bundleURL.appending(
        path: currentManifest.machineIdentifierPath!
      )
    )
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func commitDiskImageMigration(
    _ commit: VirtualMachineDiskImageMigrationCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest {
    guard lease.target.machineID == currentManifest.id,
      currentManifest.diskImagePath == commit.sourcePath,
      currentManifest.effectiveDiskImageFormat == commit.sourceFormat
    else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    commits.append(commit)
    currentManifest.markDiskImageMigrated(
      to: commit.destinationPath,
      format: commit.destinationFormat
    )
    return currentManifest
  }
}

@MainActor
private struct SavedStateInspectorDouble:
  MacVirtualMachineSavedStateInspecting
{
  let status: MacVirtualMachineSavedStateStatus

  func inspect(
    for _: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    status
  }
}

private struct StubDiskImageInspector: VirtualMachineDiskImageInspecting {
  let rawLogicalBytes: UInt64
  let asifLogicalBytes: UInt64

  func inspect(
    at _: URL,
    expectedFormat: VirtualMachineDiskImageFormat
  ) throws -> VirtualMachineDiskImageDescriptor {
    VirtualMachineDiskImageDescriptor(
      format: expectedFormat,
      logicalBytes: expectedFormat == .raw
        ? rawLogicalBytes : asifLogicalBytes,
      blockSizeBytes: 512
    )
  }
}

private enum TestDiskMigrationError: LocalizedError, Equatable {
  case expected

  var errorDescription: String? {
    "expected conversion failure"
  }
}

private actor RecordingMigrationConverter:
  VirtualMachineDiskImageConverting
{
  enum Behavior: Equatable, Sendable {
    case succeed
    case failAfterWriting
  }

  private let behavior: Behavior
  private(set) var callCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func convert(
    sourceURL _: URL,
    destinationURL: URL,
    to _: VirtualMachineDiskImageFormat
  ) async throws {
    callCount += 1
    try Data("converted-asif".utf8).write(to: destinationURL)
    if behavior == .failAfterWriting {
      throw TestDiskMigrationError.expected
    }
  }
}

private actor BlockingMigrationConverter:
  VirtualMachineDiskImageConverting
{
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func convert(
    sourceURL _: URL,
    destinationURL: URL,
    to _: VirtualMachineDiskImageFormat
  ) async throws {
    try Data("partial-asif".utf8).write(to: destinationURL)
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
    try Task.checkCancellation()
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}
