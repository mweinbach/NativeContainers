import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct VirtualMachineDiskImageMaintenanceModelTests {
  @Test
  func migrationPublishesSuccessAndRefreshesTheLibrary() async throws {
    let manifest = try asifManifest()
    let result = VirtualMachineDiskImageMigrationResult(
      manifest: manifest,
      sourceAllocatedBytes: 8_192,
      destinationAllocatedBytes: 4_096
    )
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      migration: DiskMigrationServiceDouble(behavior: .succeed(result))
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(model.completion == .migration(result))
    #expect(model.errorMessage == nil)
    #expect(counter.value == 1)
  }

  @Test
  func rewritePublishesMeasuredSavingsAndRefreshesTheLibrary() async throws {
    let manifest = try asifManifest()
    let result = VirtualMachineDiskImageRewriteResult(
      manifest: manifest,
      sourceAllocatedBytes: 12_288,
      destinationAllocatedBytes: 4_096
    )
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      rewrite: DiskRewriteServiceDouble(behavior: .succeed(result))
    ) {
      counter.value += 1
    }

    model.startRewrite()
    await waitUntilSettled(model)

    #expect(model.completion == .rewrite(result))
    #expect(counter.value == 1)
  }

  @Test
  func rewriteWithoutMeasuredSavingsDoesNotClaimAMutation() async throws {
    let manifest = try asifManifest()
    let result = VirtualMachineDiskImageRewriteResult(
      manifest: manifest,
      sourceAllocatedBytes: 4_096,
      destinationAllocatedBytes: 4_096,
      didReplace: false
    )
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      rewrite: DiskRewriteServiceDouble(behavior: .succeed(result))
    ) {
      counter.value += 1
    }

    model.startRewrite()
    await waitUntilSettled(model)

    #expect(model.completion == .rewrite(result))
    #expect(counter.value == 0)
    #expect(model.errorMessage == nil)
  }

  @Test
  func completedMaintenanceCanBeDismissedForAnotherOperation() async throws {
    let manifest = try asifManifest()
    let result = VirtualMachineDiskImageRewriteResult(
      manifest: manifest,
      sourceAllocatedBytes: 4_096,
      destinationAllocatedBytes: 4_096,
      didReplace: false
    )
    let model = makeModel(
      manifest: manifest,
      rewrite: DiskRewriteServiceDouble(behavior: .succeed(result))
    )

    model.startRewrite()
    await waitUntilSettled(model)
    model.clearCompletion()

    #expect(model.completion == nil)
    #expect(!model.isBusy)
  }

  @Test
  func reportsOrdinaryFailureWithoutClaimingAMutation() async throws {
    let manifest = try asifManifest()
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      migration: DiskMigrationServiceDouble(
        behavior: .fail(.savedStateMustBeDiscarded)
      )
    ) {
      counter.value += 1
    }

    model.startMigration()
    await waitUntilSettled(model)

    #expect(
      model.errorMessage
        == VirtualMachineDiskImageReplacementError.savedStateMustBeDiscarded
        .localizedDescription
    )
    #expect(model.completion == nil)
    #expect(counter.value == 0)
  }

  @Test
  func refreshesAfterACommittedReplacementWhoseCleanupIsPending() async throws {
    let manifest = try asifManifest()
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      rewrite: DiskRewriteServiceDouble(
        behavior: .fail(.committedCleanupPending("journal cleanup failed"))
      )
    ) {
      counter.value += 1
    }

    model.startRewrite()
    await waitUntilSettled(model)

    #expect(model.errorMessage?.contains("cleanup is pending") == true)
    #expect(counter.value == 1)
  }

  @Test
  func alreadyMigratedRecoveryStillRefreshesStaleLibraryState() async throws {
    let manifest = try asifManifest()
    let counter = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      migration: DiskMigrationServiceDouble(behavior: .fail(.alreadyASIF))
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
    let manifest = try asifManifest()
    let result = VirtualMachineDiskImageMigrationResult(
      manifest: manifest,
      sourceAllocatedBytes: 8_192,
      destinationAllocatedBytes: 4_096
    )
    let refresh = BlockingMaintenanceRefresh()
    let settled = MaintenanceMutationCounter()
    let model = makeModel(
      manifest: manifest,
      migration: DiskMigrationServiceDouble(behavior: .succeed(result))
    ) {
      await refresh.run()
    } didSettle: {
      settled.value += 1
    }

    model.startMigration()
    await refresh.waitUntilStarted()

    #expect(!model.isMigrating)
    #expect(model.isRefreshing)
    #expect(model.completion == nil)
    model.cancelMaintenance()
    refresh.resume()
    await waitUntilSettled(model)

    #expect(model.completion == .migration(result))
    #expect(settled.value == 1)
  }

  @Test
  func cancellationEndsQuietlyAndLeavesNoActiveTask() async throws {
    let manifest = try asifManifest()
    let service = DiskRewriteServiceDouble(behavior: .waitForCancellation)
    let model = makeModel(
      manifest: manifest,
      rewrite: service
    )

    model.startRewrite()
    await service.waitUntilStarted()
    model.cancelMaintenance()
    await waitUntilSettled(model)

    #expect(!model.isBusy)
    #expect(model.errorMessage == nil)
    #expect(model.completion == nil)
  }

  private func makeModel(
    manifest: VirtualMachineManifest,
    migration: any VirtualMachineDiskImageMigrating =
      DiskMigrationServiceDouble(behavior: .fail(.unavailable)),
    rewrite: any VirtualMachineDiskImageRewriting =
      DiskRewriteServiceDouble(behavior: .fail(.unavailable)),
    didMutate: @escaping @MainActor @Sendable () async -> Void = {},
    didSettle: @escaping @MainActor @Sendable () async -> Void = {}
  ) -> VirtualMachineDiskImageMaintenanceModel {
    VirtualMachineDiskImageMaintenanceModel(
      machineID: manifest.id,
      migration: migration,
      rewrite: rewrite,
      didMutate: didMutate,
      didSettle: didSettle
    )
  }

  private func waitUntilSettled(
    _ model: VirtualMachineDiskImageMaintenanceModel
  ) async {
    while model.isBusy {
      await Task.yield()
    }
  }

  private func asifManifest() throws -> VirtualMachineManifest {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "ASIF",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    manifest.markDiskImageReplaced(
      to: "Installed/Disk.asif",
      format: .asif
    )
    return manifest
  }
}

@MainActor
private final class MaintenanceMutationCounter {
  var value = 0
}

@MainActor
private final class BlockingMaintenanceRefresh {
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
    case fail(VirtualMachineDiskImageReplacementError)
    case waitForCancellation
  }

  private let behavior: Behavior

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func migrateToASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
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
}

@MainActor
private final class DiskRewriteServiceDouble:
  VirtualMachineDiskImageRewriting
{
  enum Behavior {
    case succeed(VirtualMachineDiskImageRewriteResult)
    case fail(VirtualMachineDiskImageReplacementError)
    case waitForCancellation
  }

  private let behavior: Behavior
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func rewriteASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageRewriteResult {
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
