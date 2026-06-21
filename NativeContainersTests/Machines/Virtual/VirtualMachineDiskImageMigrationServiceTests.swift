import Darwin
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
    let destinationValues = try fixture.destinationURL.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    #expect(destinationValues.isExcludedFromBackup != true)
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
  func unconfirmedConverterTerminationQuarantinesTheLeaseJournalAndPartial()
    async throws
  {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let converter = RecordingMigrationConverter(
      behavior: .terminationUnconfirmed
    )
    let service = makeService(
      store: store,
      converter: converter,
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    do {
      _ = try await service.migrateToASIF(machineID: fixture.manifest.id)
      Issue.record("Expected the converter termination to remain quarantined.")
    } catch let error as VirtualMachineDiskImageMigrationError {
      guard case .converterTerminationUnconfirmed = error else {
        Issue.record("Unexpected migration error: \(error)")
        return
      }
    }

    #expect(store.commits.isEmpty)
    #expect(store.acquireCount == 1)
    #expect(try migrationPartials(in: fixture.installedURL).count == 1)
    #expect(
      try FileVirtualMachineDiskImageMigrationJournalStore().load(
        in: fixture.bundleURL
      )?.phase == .terminationQuarantined
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.self
    ) {
      _ = try await service.migrateToASIF(machineID: fixture.manifest.id)
    }
    #expect(store.acquireCount == 1)
    #expect(try migrationPartials(in: fixture.installedURL).count == 1)
  }

  @Test
  func failedKillSignalRequiresAHostRestartBeforeRecovery() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let bootA = UUID().uuidString.lowercased()
    let bootB = UUID().uuidString.lowercased()
    var service: VirtualMachineDiskImageMigrationService? = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .killSignalFailed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootA)
    )

    await #expect(throws: VirtualMachineDiskImageMigrationError.self) {
      _ = try await service?.migrateToASIF(machineID: fixture.manifest.id)
    }
    let journalStore = FileVirtualMachineDiskImageMigrationJournalStore()
    let journal = try #require(
      try journalStore.load(in: fixture.bundleURL)
    )
    #expect(journal.phase == .terminationQuarantined)
    #expect(journal.terminationQuarantine == .untilHostRestart)
    #expect(journal.hostBootIdentifier == bootA)
    service = nil

    let sameBootService = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootA)
    )
    let blocked = try await sameBootService.recoverInterruptedMigrations()
    #expect(blocked.recoveredMachineIDs.isEmpty)
    #expect(blocked.failures.count == 1)
    #expect(try migrationPartials(in: fixture.installedURL).count == 1)

    let nextBootService = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      hostBootSession: StubHostBootSession(identifier: bootB)
    )
    let recovered = try await nextBootService.recoverInterruptedMigrations()
    #expect(recovered.recoveredMachineIDs == [fixture.manifest.id])
    #expect(recovered.failures.isEmpty)
    #expect(try migrationPartials(in: fixture.installedURL).isEmpty)
    #expect(try journalStore.load(in: fixture.bundleURL) == nil)
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
  func startupRecoveryDoesNotLeaseMachinesWithoutAJournal() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes
    )

    let report = try await service.recoverInterruptedMigrations()

    #expect(report == .empty)
    #expect(store.acquireCount == 0)
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
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
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
      phase: .planned,
      hostBootIdentifier: UUID().uuidString.lowercased()
    )
    let journalStore = FileVirtualMachineDiskImageMigrationJournalStore()
    try journalStore.save(journal, in: fixture.bundleURL)
    journal.destinationIdentity = stagingIdentity
    journal.phase = .converted
    journal.hostBootIdentifier = nil
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

  @Test
  func startupRecoveryContinuesPastAMalformedJournal() async throws {
    let malformed = try MigrationFixture()
    let recoverable = try MigrationFixture()
    defer {
      malformed.remove()
      recoverable.remove()
    }
    try Data("not-json".utf8).write(
      to: malformed.bundleURL.appending(
        path: FileVirtualMachineDiskImageMigrationJournalStore.filename
      )
    )

    let sourceIdentity = try FileVirtualMachineStorageArtifactInspector()
      .inspect(at: recoverable.sourceURL)
    let operationID = UUID()
    let stagingPath =
      "Installed/\(VirtualMachineDiskImageMigrationArtifacts.stagingPrefix)\(operationID.uuidString.lowercased())\(VirtualMachineDiskImageMigrationArtifacts.stagingSuffix)"
    let stagingURL = recoverable.bundleURL.appending(path: stagingPath)
    try Data("partial".utf8).write(to: stagingURL)
    try FileVirtualMachineDiskImageMigrationJournalStore().save(
      VirtualMachineDiskImageMigrationJournal(
        version: VirtualMachineDiskImageMigrationJournal.currentVersion,
        operationID: operationID,
        machineID: recoverable.manifest.id,
        sourcePath: recoverable.manifest.diskImagePath,
        destinationPath: "Installed/Disk.asif",
        stagingPath: stagingPath,
        sourceIdentity: sourceIdentity,
        sourceLogicalBytes: recoverable.manifest.resources.diskBytes,
        destinationIdentity: nil,
        phase: .planned,
        hostBootIdentifier: UUID().uuidString.lowercased()
      ),
      in: recoverable.bundleURL
    )
    let store = RecoveryMigrationStoreDouble(fixtures: [malformed, recoverable])
    let service = VirtualMachineDiskImageMigrationService(
      store: store,
      savedStates: SavedStateInspectorDouble(status: .none),
      converter: RecordingMigrationConverter(behavior: .succeed),
      imageInspector: StubDiskImageInspector(
        rawLogicalBytes: recoverable.manifest.resources.diskBytes,
        asifLogicalBytes: recoverable.manifest.resources.diskBytes
      )
    )

    let report = try await service.recoverInterruptedMigrations()

    #expect(report.recoveredMachineIDs == [recoverable.manifest.id])
    #expect(report.deferredMachineIDs.isEmpty)
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.machineID == malformed.manifest.id)
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
  }

  private func makeService(
    store: MigrationStoreDouble,
    converter: any VirtualMachineDiskImageConverting,
    savedState: MacVirtualMachineSavedStateStatus,
    logicalBytes: UInt64,
    asifLogicalBytes: UInt64? = nil,
    hostBootSession: any HostBootSessionIdentifying =
      DarwinHostBootSessionIdentifier()
  ) -> VirtualMachineDiskImageMigrationService {
    VirtualMachineDiskImageMigrationService(
      store: store,
      savedStates: SavedStateInspectorDouble(status: savedState),
      converter: converter,
      imageInspector: StubDiskImageInspector(
        rawLogicalBytes: logicalBytes,
        asifLogicalBytes: asifLogicalBytes ?? logicalBytes
      ),
      hostBootSession: hostBootSession
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
  private(set) var acquireCount = 0
  private let bundleURL: URL

  init(manifest: VirtualMachineManifest, bundleURL: URL) {
    currentManifest = manifest
    self.bundleURL = bundleURL
  }

  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
  {
    VirtualMachineStorageInventory(
      rootURL: bundleURL.deletingLastPathComponent(),
      targets: [
        VirtualMachineStorageTarget(
          manifest: currentManifest,
          bundleURL: bundleURL
        )
      ]
    )
  }

  func acquireDiskImageMigrationRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease {
    acquireCount += 1
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
    case terminationUnconfirmed
    case killSignalFailed
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
    if behavior == .terminationUnconfirmed {
      throw HostProcessError.didNotExitAfterKill
    }
    if behavior == .killSignalFailed {
      throw HostProcessError.signalFailed(signal: SIGKILL, code: EPERM)
    }
  }
}

private struct StubHostBootSession: HostBootSessionIdentifying {
  let identifier: String

  func currentBootIdentifier() throws -> String {
    identifier
  }
}

@MainActor
private final class RecoveryMigrationStoreDouble:
  VirtualMachineDiskImageMigrationStoring
{
  private let fixtures: [MigrationFixture]

  init(fixtures: [MigrationFixture]) {
    self.fixtures = fixtures
  }

  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
  {
    VirtualMachineStorageInventory(
      rootURL: fixtures[0].rootURL,
      targets: fixtures.map {
        VirtualMachineStorageTarget(
          manifest: $0.manifest,
          bundleURL: $0.bundleURL
        )
      }
    )
  }

  func acquireDiskImageMigrationRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease {
    guard let fixture = fixtures.first(where: { $0.manifest.id == id }) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let manifest = fixture.manifest
    return MacVirtualMachineRuntimeLease(
      machine: ResolvedMacVirtualMachine(
        manifest: manifest,
        bundleURL: fixture.bundleURL,
        diskImageURL: fixture.bundleURL.appending(path: manifest.diskImagePath),
        auxiliaryStorageURL: fixture.bundleURL.appending(
          path: manifest.auxiliaryStoragePath!
        ),
        hardwareModelURL: fixture.bundleURL.appending(
          path: manifest.hardwareModelPath!
        ),
        machineIdentifierURL: fixture.bundleURL.appending(
          path: manifest.machineIdentifierPath!
        )
      ),
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func commitDiskImageMigration(
    _: VirtualMachineDiskImageMigrationCommit,
    for _: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest {
    throw TestDiskMigrationError.expected
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
