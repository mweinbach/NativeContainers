import Darwin
import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageMigrationServiceTests {
  @Test
  func migratesRAWOutOfPlaceThenCommitsAndRetiresTheSource() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let service = makeDiskImageMigrationService(
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
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func refusesMigrationUntilSavedStateIsExplicitlyDiscarded() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let summary = MacVirtualMachineSavedStateSummary(
      createdAt: Date(),
      stateSizeBytes: 4_096
    )
    let service = makeDiskImageMigrationService(
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
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .failAfterWriting)
    let service = makeDiskImageMigrationService(
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
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func cancellationRemovesItsPartialOnlyAfterTheConverterStops() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = BlockingMigrationConverter()
    let service = makeDiskImageMigrationService(
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
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).isEmpty)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: fixture.bundleURL
      ) == nil
    )
  }

  @Test
  func unconfirmedConverterTerminationQuarantinesTheLeaseJournalAndPartial()
    async throws
  {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let converter = RecordingMigrationConverter(
      behavior: .terminationUnconfirmed
    )
    let service = makeDiskImageMigrationService(
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
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).count == 1)
    #expect(
      try FileVirtualMachineDiskImageReplacementJournalStore().load(
        in: fixture.bundleURL
      )?.phase == .terminationQuarantined
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.self
    ) {
      _ = try await service.migrateToASIF(machineID: fixture.manifest.id)
    }
    #expect(store.acquireCount == 1)
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).count == 1)
  }

  @Test
  func rejectsAConvertedImageWithDifferentVirtualCapacity() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(manifest: fixture.manifest, bundleURL: fixture.bundleURL)
    let converter = RecordingMigrationConverter(behavior: .succeed)
    let service = makeDiskImageMigrationService(
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
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).isEmpty)
  }

  @Test
  func rejectsAConvertedImageWithDifferentBlockGeometry() async throws {
    let fixture = try DiskImageMigrationFixture()
    defer { fixture.remove() }
    let store = MigrationStoreDouble(
      manifest: fixture.manifest,
      bundleURL: fixture.bundleURL
    )
    let service = makeDiskImageMigrationService(
      store: store,
      converter: RecordingMigrationConverter(behavior: .succeed),
      savedState: .none,
      logicalBytes: fixture.manifest.resources.diskBytes,
      asifBlockSizeBytes: 4_096
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.blockSizeMismatch(
        expected: 512,
        actual: 4_096
      )
    ) {
      _ = try await service.migrateToASIF(machineID: fixture.manifest.id)
    }

    #expect(store.commits.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    #expect(try diskImageMigrationPartials(in: fixture.installedURL).isEmpty)
  }

}
