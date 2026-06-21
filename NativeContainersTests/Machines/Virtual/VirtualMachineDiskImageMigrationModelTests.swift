import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageMigrationModelTests {
  @Test
  func publishesSuccessAndRefreshesTheLibrary() async throws {
    let manifest = try migratedManifest()
    let service = DiskMigrationServiceDouble(
      behavior: .succeed(
        VirtualMachineDiskImageMigrationResult(
          manifest: manifest,
          sourceAllocatedBytes: 8_192,
          destinationAllocatedBytes: 4_096
        )
      )
    )
    let counter = MigrationMutationCounter()
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: service
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(model.lastResult?.manifest == manifest)
    #expect(model.lastResult?.reclaimedBytes == 4_096)
    #expect(model.errorMessage == nil)
    #expect(counter.value == 1)
  }

  @Test
  func reportsOrdinaryFailureWithoutClaimingAMutation() async throws {
    let manifest = try migratedManifest()
    let service = DiskMigrationServiceDouble(
      behavior: .fail(.savedStateMustBeDiscarded)
    )
    let counter = MigrationMutationCounter()
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: service
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(
      model.errorMessage
        == VirtualMachineDiskImageMigrationError.savedStateMustBeDiscarded
        .localizedDescription
    )
    #expect(model.lastResult == nil)
    #expect(counter.value == 0)
  }

  @Test
  func refreshesAfterACommittedMigrationWhoseCleanupIsPending() async throws {
    let manifest = try migratedManifest()
    let service = DiskMigrationServiceDouble(
      behavior: .fail(.committedCleanupPending("journal cleanup failed"))
    )
    let counter = MigrationMutationCounter()
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: service
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(model.errorMessage?.contains("cleanup is pending") == true)
    #expect(counter.value == 1)
  }

  @Test
  func alreadyMigratedRecoveryStillRefreshesStaleLibraryState() async throws {
    let manifest = try migratedManifest()
    let counter = MigrationMutationCounter()
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: DiskMigrationServiceDouble(behavior: .fail(.alreadyASIF))
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(counter.value == 1)
    #expect(model.errorMessage?.contains("already uses") == true)
  }

  @Test
  func successIsPublishedOnlyAfterTheUncancellableRefreshPhase() async throws {
    let manifest = try migratedManifest()
    let result = VirtualMachineDiskImageMigrationResult(
      manifest: manifest,
      sourceAllocatedBytes: 8_192,
      destinationAllocatedBytes: 4_096
    )
    let refresh = BlockingMigrationRefresh()
    let settled = MigrationMutationCounter()
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: DiskMigrationServiceDouble(behavior: .succeed(result))
    ) {
      await refresh.run()
    } didSettle: {
      settled.value += 1
    }

    model.startMigration()
    await refresh.waitUntilStarted()

    #expect(model.isMigrating == false)
    #expect(model.isRefreshing)
    #expect(model.lastResult == nil)
    model.cancelMigration()
    refresh.resume()
    await waitUntilSettled(model)

    #expect(model.lastResult == result)
    #expect(settled.value == 1)
  }

  @Test
  func cancellationEndsQuietlyAndLeavesNoActiveTask() async throws {
    let manifest = try migratedManifest()
    let service = DiskMigrationServiceDouble(behavior: .waitForCancellation)
    let model = VirtualMachineDiskImageMigrationModel(
      machineID: manifest.id,
      service: service
    )

    model.startMigration()
    await service.waitUntilStarted()
    model.cancelMigration()
    await waitUntilSettled(model)

    #expect(model.isMigrating == false)
    #expect(model.errorMessage == nil)
    #expect(model.lastResult == nil)
  }

  private func waitUntilSettled(
    _ model: VirtualMachineDiskImageMigrationModel
  ) async {
    while model.isBusy {
      await Task.yield()
    }
  }

  private func migratedManifest() throws -> VirtualMachineManifest {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Migrated",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    manifest.markDiskImageMigrated(
      to: "Installed/Disk.asif",
      format: .asif
    )
    return manifest
  }
}

@MainActor
private final class MigrationMutationCounter {
  var value = 0
}

@MainActor
private final class BlockingMigrationRefresh {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<Void, Never>?

  func run() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class DiskMigrationServiceDouble:
  VirtualMachineDiskImageMigrating
{
  enum Behavior {
    case succeed(VirtualMachineDiskImageMigrationResult)
    case fail(VirtualMachineDiskImageMigrationError)
    case waitForCancellation
  }

  private let behavior: Behavior
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func migrateToASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }

    switch behavior {
    case .succeed(let result):
      return result
    case .fail(let error):
      throw error
    case .waitForCancellation:
      while !Task.isCancelled {
        await Task.yield()
      }
      throw CancellationError()
    }
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }
}
