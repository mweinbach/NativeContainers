import Foundation
import Testing

@testable import NativeContainers

@Suite("Virtual machine compute model")
@MainActor
struct VirtualMachineComputeModelTests {
  @Test
  func loadPublishesPersistedConfigurationAndLimitsOnlyOnce() async throws {
    let service = ComputeModelService(
      snapshot: computeModelSnapshot(cpuCount: 6, memoryGiB: 12)
    )
    let model = VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try computeModelResources(
        cpuCount: 4,
        memoryGiB: 8
      ),
      service: service
    )

    await model.load()

    #expect(model.isLoaded)
    #expect(model.cpuCount == 6)
    #expect(model.memoryGiB == 12)
    #expect(model.cpuRange == 1...12)
    #expect(model.memoryGiBRange == 1...64)
    #expect(await service.snapshotCount == 1)

    await model.load()
    #expect(await service.snapshotCount == 1)
  }

  @Test
  func savePublishesReturnedStateAndRefreshesInventory() async throws {
    let service = ComputeModelService(
      snapshot: computeModelSnapshot(cpuCount: 4, memoryGiB: 8)
    )
    let refresh = ComputeRefreshRecorder()
    let model = VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try computeModelResources(
        cpuCount: 4,
        memoryGiB: 8
      ),
      service: service
    ) {
      refresh.record()
    }
    await model.load()
    model.cpuCount = 8
    model.memoryGiB = 16

    let saved = await model.save()

    #expect(saved)
    #expect(model.cpuCount == 8)
    #expect(model.memoryGiB == 16)
    #expect(!model.hasChanges)
    #expect(model.errorMessage == nil)
    #expect(await service.setCount == 1)
    #expect(refresh.count == 1)
  }

  @Test
  func failedSaveKeepsDraftForCorrectionAndCanRevert() async throws {
    let service = ComputeModelService(
      snapshot: computeModelSnapshot(cpuCount: 4, memoryGiB: 8),
      mutationError: .unavailable
    )
    let model = VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try computeModelResources(
        cpuCount: 4,
        memoryGiB: 8
      ),
      service: service
    )
    await model.load()
    model.cpuCount = 6
    model.memoryGiB = 12

    let saved = await model.save()

    #expect(!saved)
    #expect(model.cpuCount == 6)
    #expect(model.memoryGiB == 12)
    #expect(model.hasChanges)
    #expect(model.errorMessage?.contains("unavailable") == true)

    model.resetChanges()
    model.clearError()

    #expect(model.cpuCount == 4)
    #expect(model.memoryGiB == 8)
    #expect(!model.hasChanges)
    #expect(model.errorMessage == nil)
  }

  @Test
  func manifestRefreshReloadsUnlessTheUserHasStagedEdits() async throws {
    let service = ComputeModelService(
      snapshot: computeModelSnapshot(cpuCount: 4, memoryGiB: 8)
    )
    let model = VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try computeModelResources(
        cpuCount: 4,
        memoryGiB: 8
      ),
      service: service
    )
    await model.load()
    model.cpuCount = 5
    await service.replaceSnapshot(
      computeModelSnapshot(cpuCount: 6, memoryGiB: 12)
    )

    await model.reload()
    #expect(model.cpuCount == 5)

    model.resetChanges()
    await model.reload()

    #expect(model.cpuCount == 6)
    #expect(model.memoryGiB == 12)
    #expect(await service.snapshotCount == 2)
  }
}

private actor ComputeModelService: VirtualMachineComputeManaging {
  private var current: VirtualMachineComputeSnapshot
  private let mutationError: VirtualMachineComputeError?
  private(set) var snapshotCount = 0
  private(set) var setCount = 0

  init(
    snapshot: VirtualMachineComputeSnapshot,
    mutationError: VirtualMachineComputeError? = nil
  ) {
    current = snapshot
    self.mutationError = mutationError
  }

  func snapshot(id: UUID) -> VirtualMachineComputeSnapshot {
    snapshotCount += 1
    return current
  }

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) throws -> VirtualMachineComputeSnapshot {
    setCount += 1
    if let mutationError {
      throw mutationError
    }
    try current.limits.validate(configuration)
    current = VirtualMachineComputeSnapshot(
      configuration: configuration,
      diskBytes: current.diskBytes,
      limits: current.limits
    )
    return current
  }

  func replaceSnapshot(_ snapshot: VirtualMachineComputeSnapshot) {
    current = snapshot
  }
}

private final class ComputeRefreshRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func computeModelSnapshot(
  cpuCount: Int,
  memoryGiB: UInt64
) -> VirtualMachineComputeSnapshot {
  VirtualMachineComputeSnapshot(
    configuration: VirtualMachineComputeConfiguration(
      cpuCount: cpuCount,
      memoryBytes: memoryGiB * VirtualMachineResources.bytesPerGiB
    ),
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB,
    limits: VirtualMachineComputeLimits(
      minimumCPUCount: 1,
      maximumCPUCount: 12,
      minimumMemoryBytes: VirtualMachineResources.bytesPerGiB,
      maximumMemoryBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
}

private func computeModelResources(
  cpuCount: Int,
  memoryGiB: UInt64
) throws -> VirtualMachineResources {
  try VirtualMachineResources(
    cpuCount: cpuCount,
    memoryBytes: memoryGiB * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
}
