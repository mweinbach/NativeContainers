import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Storage overview model")
struct StorageOverviewModelTests {
  @Test
  func remainsIdleUntilExplicitRefresh() async {
    let runtime = runtimeUsage(at: 1, allocatedBytes: 100)
    let virtualMachines = virtualMachineUsage(at: 1, allocatedBytes: 200)
    let service = ScriptedStorageUsageService(
      runtime: [.success(runtime)],
      virtualMachines: [.success(virtualMachines)]
    )
    let model = StorageOverviewModel(service: service)

    #expect(!model.hasAttempted)
    #expect(!model.isLoading)
    #expect(await service.runtimeLoadCount == 0)
    #expect(await service.virtualMachineLoadCount == 0)

    await model.refresh()

    #expect(model.hasAttempted)
    #expect(model.appleRuntimeUsage == runtime)
    #expect(model.virtualMachineUsage == virtualMachines)
    #expect(await service.runtimeLoadCount == 1)
    #expect(await service.virtualMachineLoadCount == 1)
  }

  @Test
  func refreshesLanesConcurrently() async {
    let service = BlockingStorageUsageService(
      runtime: runtimeUsage(at: 1, allocatedBytes: 100),
      virtualMachines: virtualMachineUsage(at: 1, allocatedBytes: 200)
    )
    let model = StorageOverviewModel(service: service)
    let refresh = Task {
      await model.refresh()
    }

    await service.waitUntilBothLoadsStart()

    #expect(model.isLoadingAppleRuntime)
    #expect(model.isLoadingVirtualMachines)
    await service.resumeBothLoads()
    await refresh.value

    #expect(!model.isLoading)
    #expect(model.appleRuntimeUsage != nil)
    #expect(model.virtualMachineUsage != nil)
  }

  @Test
  func partialFailureRetainsPriorSnapshotAndUpdatesSuccessfulLane() async {
    let originalRuntime = runtimeUsage(at: 1, allocatedBytes: 100)
    let originalVirtualMachines = virtualMachineUsage(
      at: 1,
      allocatedBytes: 200
    )
    let currentVirtualMachines = virtualMachineUsage(
      at: 2,
      allocatedBytes: 300
    )
    let service = ScriptedStorageUsageService(
      runtime: [
        .success(originalRuntime),
        .failure("Runtime storage is temporarily unavailable."),
      ],
      virtualMachines: [
        .success(originalVirtualMachines),
        .success(currentVirtualMachines),
      ]
    )
    let model = StorageOverviewModel(service: service)

    await model.refresh()
    await model.refresh()

    #expect(model.appleRuntimeUsage == originalRuntime)
    #expect(
      model.appleRuntimeErrorMessage
        == "Runtime storage is temporarily unavailable."
    )
    #expect(model.virtualMachineUsage == currentVirtualMachines)
    #expect(model.virtualMachineErrorMessage == nil)
  }

  @Test
  func cancellingCurrentOperationClearsLoadingWithoutPublishingErrors() async {
    let service = CancellationAwareStorageUsageService()
    let model = StorageOverviewModel(service: service)
    model.startRefresh()
    await service.waitUntilBothLoadsStart()

    model.cancelCurrentOperation()
    while model.isLoading {
      await Task.yield()
    }

    #expect(model.appleRuntimeUsage == nil)
    #expect(model.virtualMachineUsage == nil)
    #expect(model.appleRuntimeErrorMessage == nil)
    #expect(model.virtualMachineErrorMessage == nil)
    #expect(await service.observedCancellationCount == 2)
  }

  @Test
  func postMutationReconciliationRefreshesOnlyAppleRuntimeLane() async {
    let runtime = runtimeUsage(at: 2, allocatedBytes: 150)
    let service = ScriptedStorageUsageService(
      runtime: [.success(runtime)],
      virtualMachines: [
        .success(virtualMachineUsage(at: 2, allocatedBytes: 300))
      ]
    )
    let model = StorageOverviewModel(
      service: service,
      appleRuntimeUsage: runtimeUsage(at: 1, allocatedBytes: 100),
      virtualMachineUsage: virtualMachineUsage(at: 1, allocatedBytes: 200)
    )

    await model.refreshAppleRuntimeAfterMutation()

    #expect(model.appleRuntimeUsage == runtime)
    #expect(!model.isAppleRuntimeSnapshotStale)
    #expect(await service.runtimeLoadCount == 1)
    #expect(await service.virtualMachineLoadCount == 0)
  }

  private func runtimeUsage(
    at timestamp: TimeInterval,
    allocatedBytes: UInt64
  ) -> AppleRuntimeStorageUsage {
    AppleRuntimeStorageUsage(
      capturedAt: Date(timeIntervalSince1970: timestamp),
      images: StorageResourceUsage(
        totalCount: 1,
        activeCount: 1,
        allocatedBytes: allocatedBytes,
        reclaimableBytes: 0
      ),
      containers: StorageResourceUsage(
        totalCount: 0,
        activeCount: 0,
        allocatedBytes: 0,
        reclaimableBytes: 0
      ),
      volumes: StorageResourceUsage(
        totalCount: 0,
        activeCount: 0,
        allocatedBytes: 0,
        reclaimableBytes: 0
      )
    )
  }

  private func virtualMachineUsage(
    at timestamp: TimeInterval,
    allocatedBytes: UInt64
  ) -> VirtualMachineStorageSummary {
    VirtualMachineStorageSummary(
      capturedAt: Date(timeIntervalSince1970: timestamp),
      discoveredMachineCount: 0,
      libraryLogicalBytes: allocatedBytes,
      libraryAllocatedBytes: allocatedBytes,
      libraryEntryCount: 0,
      libraryHardLinkCount: 0,
      libraryNonRegularEntryCount: 0,
      libraryMissingEntryCount: 0,
      libraryOverflowed: false,
      machines: [],
      issues: []
    )
  }
}

private enum ScriptedStorageResult<Value: Sendable>: Sendable {
  case success(Value)
  case failure(String)
}

private struct ScriptedStorageError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private actor ScriptedStorageUsageService: StorageUsageLoading {
  private var runtime: [ScriptedStorageResult<AppleRuntimeStorageUsage>]
  private var virtualMachines: [ScriptedStorageResult<VirtualMachineStorageSummary>]
  private(set) var runtimeLoadCount = 0
  private(set) var virtualMachineLoadCount = 0

  init(
    runtime: [ScriptedStorageResult<AppleRuntimeStorageUsage>],
    virtualMachines: [ScriptedStorageResult<VirtualMachineStorageSummary>]
  ) {
    self.runtime = runtime
    self.virtualMachines = virtualMachines
  }

  func loadAppleRuntimeStorageUsage() async throws
    -> AppleRuntimeStorageUsage
  {
    runtimeLoadCount += 1
    switch runtime.removeFirst() {
    case .success(let usage):
      return usage
    case .failure(let message):
      throw ScriptedStorageError(message: message)
    }
  }

  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    virtualMachineLoadCount += 1
    switch virtualMachines.removeFirst() {
    case .success(let usage):
      return usage
    case .failure(let message):
      throw ScriptedStorageError(message: message)
    }
  }
}

private actor BlockingStorageUsageService: StorageUsageLoading {
  let runtime: AppleRuntimeStorageUsage
  let virtualMachines: VirtualMachineStorageSummary

  private var runtimeStarted = false
  private var virtualMachinesStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var runtimeContinuation: CheckedContinuation<AppleRuntimeStorageUsage, Never>?
  private var virtualMachineContinuation: CheckedContinuation<VirtualMachineStorageSummary, Never>?

  init(
    runtime: AppleRuntimeStorageUsage,
    virtualMachines: VirtualMachineStorageSummary
  ) {
    self.runtime = runtime
    self.virtualMachines = virtualMachines
  }

  func loadAppleRuntimeStorageUsage() async throws
    -> AppleRuntimeStorageUsage
  {
    runtimeStarted = true
    resumeStartWaitersIfReady()
    return await withCheckedContinuation { continuation in
      runtimeContinuation = continuation
    }
  }

  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    virtualMachinesStarted = true
    resumeStartWaitersIfReady()
    return await withCheckedContinuation { continuation in
      virtualMachineContinuation = continuation
    }
  }

  func waitUntilBothLoadsStart() async {
    guard !runtimeStarted || !virtualMachinesStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resumeBothLoads() {
    runtimeContinuation?.resume(returning: runtime)
    runtimeContinuation = nil
    virtualMachineContinuation?.resume(returning: virtualMachines)
    virtualMachineContinuation = nil
  }

  private func resumeStartWaitersIfReady() {
    guard runtimeStarted, virtualMachinesStarted else { return }
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor CancellationAwareStorageUsageService: StorageUsageLoading {
  private var startedCount = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var observedCancellationCount = 0

  func loadAppleRuntimeStorageUsage() async throws
    -> AppleRuntimeStorageUsage
  {
    try await waitForCancellation()
  }

  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    try await waitForCancellation()
  }

  func waitUntilBothLoadsStart() async {
    guard startedCount < 2 else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  private func waitForCancellation<Value: Sendable>() async throws -> Value {
    startedCount += 1
    if startedCount == 2 {
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
    do {
      try await Task.sleep(for: .seconds(60))
      throw ScriptedStorageError(message: "Unexpected completion")
    } catch is CancellationError {
      observedCancellationCount += 1
      throw CancellationError()
    }
  }
}
