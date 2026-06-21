import Foundation
import Testing

@testable import NativeContainers

@Suite("Linux machine request validation")
struct LinuxMachineRequestValidationTests {
  @Test
  func acceptsSafePersistentMachineRequest() throws {
    let request = try LinuxMachineCreationRequest(
      name: "dev-machine",
      imageReference: "alpine:3.22",
      cpuCount: 6,
      memoryBytes: 4_096 * LinuxMachineCreationRequest.bytesPerMiB,
      homeMount: .readOnly
    )

    #expect(request.name == "dev-machine")
    #expect(request.homeMount == .readOnly)
    #expect(request.startAfterCreation)
  }

  @Test
  func rejectsInvalidNameAndUndersizedMemory() {
    #expect(throws: LinuxMachineValidationError.invalidName) {
      try LinuxMachineCreationRequest(name: "Dev_Machine", imageReference: "alpine:3.22")
    }
    #expect(throws: LinuxMachineValidationError.invalidMemory) {
      try LinuxMachineCreationRequest(
        name: "dev",
        imageReference: "alpine:3.22",
        memoryBytes: 512 * LinuxMachineCreationRequest.bytesPerMiB
      )
    }
  }

  @Test
  func enforcesPinnedRuntimeMachineNameLimitBeforeImagePreparation() throws {
    let acceptedName = String(repeating: "a", count: 57)
    #expect(
      try LinuxMachineCreationRequest(
        name: acceptedName,
        imageReference: "alpine:3.22"
      ).name == acceptedName
    )

    #expect(throws: LinuxMachineValidationError.nameTooLong) {
      try LinuxMachineCreationRequest(
        name: String(repeating: "a", count: 58),
        imageReference: "alpine:3.22"
      )
    }
  }

  @Test
  func writableHomeMountRequiresExplicitAuthorization() {
    #expect(throws: LinuxMachineValidationError.writableHomeMountRequiresAuthorization) {
      try LinuxMachineCreationRequest(
        name: "dev",
        imageReference: "alpine:3.22",
        homeMount: .readWrite
      )
    }
  }
}

@Suite("Linux machine management model")
@MainActor
struct LinuxMachineManagementModelTests {
  @Test
  func creationPublishesProgressAndRefreshesInventory() async throws {
    let service = RecordingMachineService()
    let refresh = RefreshRecorder()
    let model = LinuxMachineManagementModel(
      creator: service,
      lifecycle: service
    ) {
      await refresh.record()
    }

    let succeeded = await model.createMachine(
      try LinuxMachineCreationRequest(name: "dev", imageReference: "alpine:3.22")
    )

    #expect(succeeded)
    #expect(model.progress?.phase == .completed)
    #expect(model.errorMessage == nil)
    #expect(await refresh.count == 1)
  }

  @Test
  func partialCreationRemainsVisibleAndRefreshesInventory() async throws {
    let service = RecordingMachineService(returnsPartialCompletion: true)
    let refresh = RefreshRecorder()
    let model = LinuxMachineManagementModel(
      creator: service,
      lifecycle: service
    ) {
      await refresh.record()
    }

    let succeeded = await model.createMachine(
      try LinuxMachineCreationRequest(name: "dev", imageReference: "alpine:3.22")
    )

    #expect(!succeeded)
    #expect(model.partialCreation?.identity.id == "dev")
    #expect(model.errorMessage?.contains("automatically stopped") == true)
    #expect(await refresh.count == 1)
  }

  @Test
  func configurationPublishesVerifiedResultAndRefreshesInventory() async throws {
    let service = RecordingMachineService()
    let refresh = RefreshRecorder()
    let model = LinuxMachineManagementModel(
      creator: service,
      lifecycle: service,
      configuration: service
    ) {
      await refresh.record()
    }
    let machine = LinuxMachineRecord(
      id: "dev",
      imageReference: "alpine:3.22",
      platform: "linux/arm64",
      state: .running,
      ipAddress: "192.0.2.2",
      createdAt: Date(timeIntervalSince1970: 1),
      startedAt: Date(timeIntervalSince1970: 2),
      diskSizeBytes: nil,
      cpuCount: 4,
      memoryBytes: 2_048 * LinuxMachineConfiguration.bytesPerMiB,
      homeMount: .none,
      isInitialized: true
    )
    let request = try LinuxMachineConfigurationUpdateRequest(
      cpuCount: 6,
      memoryBytes: 4_096 * LinuxMachineConfiguration.bytesPerMiB,
      homeMount: .readOnly,
      allowsWritableHomeMount: false
    )

    let succeeded = await model.updateConfiguration(for: machine, request: request)

    #expect(succeeded)
    #expect(model.configurationUpdate?.configuration == request.configuration)
    #expect(model.configurationUpdate?.requiresRestart == true)
    #expect(model.errorMessage == nil)
    #expect(await service.configurationTargets == [LinuxMachineIdentity(machine: machine)])
    #expect(await refresh.count == 1)
  }
}

@Suite("Apple machine management service")
struct AppleMachineManagementServiceTests {
  @Test
  func creationBootsAndProvisionsBeforeReportingReady() async throws {
    let runtime = MockLinuxMachineRuntime()
    let service = makeService(runtime: runtime)
    let request = try makeRequest()
    let progress = ProgressRecorder()

    let result = try await service.createMachine(request: request) { update in
      await progress.record(update)
    }

    #expect(result.state == .running)
    #expect(result.isInitialized)
    #expect(
      await runtime.calls == [
        .snapshot("dev"),
        .create("dev"),
        .boot("dev"),
        .provision("dev", timeoutSeconds: 30),
        .snapshot("dev"),
      ]
    )
    #expect(await progress.phases.last == .completed)
  }

  @Test
  func creationCanLeaveReviewedMachineStopped() async throws {
    let runtime = MockLinuxMachineRuntime()
    let service = makeService(runtime: runtime)
    let request = try makeRequest(startAfterCreation: false)

    let result = try await service.createMachine(request: request) { _ in }

    #expect(result.state == .stopped)
    #expect(!result.isInitialized)
    #expect(await runtime.calls == [.snapshot("dev"), .create("dev")])
  }

  @Test
  func creationCommitWithFailedReconciliationReportsUnknownOutcome() async throws {
    let runtime = MockLinuxMachineRuntime(
      createThrowsAfterCommit: true,
      snapshotFailuresAfterCreate: 1
    )
    let service = makeService(runtime: runtime)

    await #expect(throws: LinuxMachineManagementError.creationOutcomeUnknown("dev")) {
      try await service.createMachine(request: makeRequest()) { _ in }
    }

    #expect((await runtime.current)?.identity.id == "dev")
  }

  @Test
  func startLeavesAlreadyReadyMachineRunning() async throws {
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime")
    )
    let service = makeService(runtime: runtime)

    try await service.startMachine(makeIdentity())

    #expect(await runtime.calls == [.snapshot("dev")])
    #expect((await runtime.current)?.state == .running)
  }

  @Test
  func callerCancellationAfterCreateStopsDurableMachine() async throws {
    let runtime = MockLinuxMachineRuntime(suspendProvisioning: true)
    let service = makeService(runtime: runtime)
    let request = try makeRequest()
    let operation = Task {
      try await service.createMachine(request: request) { _ in }
    }

    while !(await runtime.hasStartedProvisioning) {
      await Task.yield()
    }
    operation.cancel()

    do {
      _ = try await operation.value
      Issue.record("Expected partial completion after cancellation.")
    } catch let error as LinuxMachinePartialCompletionError {
      #expect(error.result.identity.id == "dev")
      #expect(error.recovery == .gracefullyStopped)
    } catch {
      Issue.record("Expected partial completion, got \(error).")
    }

    #expect((await runtime.current)?.state == .stopped)
    #expect((await runtime.calls).contains(.stop("dev")))
  }

  @Test
  func provisioningFailureFallsBackFromStopToPinnedKill() async throws {
    let runtime = MockLinuxMachineRuntime(
      provisionError: .provisionFailed,
      stopError: .stopFailed
    )
    let service = makeService(runtime: runtime)
    let request = try makeRequest()

    do {
      _ = try await service.createMachine(request: request) { _ in }
      Issue.record("Expected partial completion.")
    } catch let error as LinuxMachinePartialCompletionError {
      #expect(error.result.identity.id == "dev")
      #expect(error.recovery == .forceStopped)
    }

    let calls = await runtime.calls
    #expect(calls.contains(.stop("dev")))
    #expect(calls.contains(.forceStop("dev-runtime")))
    #expect((await runtime.current)?.state == .stopped)
  }

  @Test
  func recoveryDoesNotKillWhenGracefulStopLandsAtFinalRecheck() async throws {
    let runtime = MockLinuxMachineRuntime(
      provisionError: .provisionFailed,
      stopError: .stopFailed,
      stopCompletesAfterSnapshotCount: 26
    )
    let service = makeService(runtime: runtime)

    do {
      _ = try await service.createMachine(request: makeRequest()) { _ in }
      Issue.record("Expected partial completion.")
    } catch let error as LinuxMachinePartialCompletionError {
      #expect(error.recovery == .gracefullyStopped)
    }

    #expect(!(await runtime.calls).contains(.forceStop("dev-runtime")))
    #expect((await runtime.current)?.state == .stopped)
  }

  @Test
  func recoveryReconcilesKillReplyLostAfterCommit() async throws {
    let runtime = MockLinuxMachineRuntime(
      provisionError: .provisionFailed,
      stopError: .stopFailed,
      forceStopThrowsAfterMutation: true
    )
    let service = makeService(runtime: runtime)

    do {
      _ = try await service.createMachine(request: makeRequest()) { _ in }
      Issue.record("Expected partial completion.")
    } catch let error as LinuxMachinePartialCompletionError {
      #expect(error.recovery == .forceStopped)
    }

    #expect((await runtime.current)?.state == .stopped)
  }

  @Test
  func forceStopRevalidatesIdentityAndKillsOnlyPinnedBackingContainer() async throws {
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime")
    )
    let service = makeService(runtime: runtime)
    let target = makeIdentity()

    try await service.forceStopMachine(
      target,
      authorization: .confirmed(for: target)
    )

    #expect(
      await runtime.calls == [
        .snapshot("dev"),
        .forceStop("dev-runtime"),
        .snapshot("dev"),
      ]
    )
    #expect((await runtime.current)?.state == .stopped)
  }

  @Test
  func forceStopRecoversMachineStuckStopping() async throws {
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .stopping, backingContainerID: "dev-runtime")
    )
    let service = makeService(runtime: runtime)
    let target = makeIdentity()

    try await service.forceStopMachine(
      target,
      authorization: .confirmed(for: target)
    )

    #expect((await runtime.current)?.state == .stopped)
    #expect((await runtime.calls).contains(.forceStop("dev-runtime")))
  }

  @Test
  func forceStopRequiresExplicitServiceAuthorization() async {
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime")
    )
    let service = makeService(runtime: runtime)
    let target = makeIdentity()

    await #expect(throws: LinuxMachineManagementError.forceStopNotAuthorized("dev")) {
      try await service.forceStopMachine(
        target,
        authorization: LinuxMachineForceStopAuthorization(
          target: target,
          allowsKill: false
        )
      )
    }

    #expect(await runtime.calls.isEmpty)
  }

  @Test
  func forceStopRequiresConfirmedExitAfterKill() async {
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime"),
      forceStopLeavesRunning: true
    )
    let service = makeService(runtime: runtime)
    let target = makeIdentity()

    await #expect(throws: LinuxMachineManagementError.forceStopNotConfirmed("dev")) {
      try await service.forceStopMachine(
        target,
        authorization: .confirmed(for: target)
      )
    }
  }

  @Test
  func forceStopRefusesReplacementWithSameName() async {
    let replacement = LinuxMachineRuntimeSnapshot(
      identity: LinuxMachineIdentity(
        id: "dev",
        imageReference: "alpine:3.22",
        platform: "linux/arm64",
        createdAt: Date(timeIntervalSince1970: 2)
      ),
      state: .running,
      backingContainerID: "replacement-runtime",
      isInitialized: true
    )
    let runtime = MockLinuxMachineRuntime(current: replacement)
    let service = makeService(runtime: runtime)

    await #expect(throws: LinuxMachineManagementError.staleTarget("dev")) {
      let target = makeIdentity()
      try await service.forceStopMachine(
        target,
        authorization: .confirmed(for: target)
      )
    }
    #expect(!(await runtime.calls).contains(.forceStop("replacement-runtime")))
  }

  @Test
  func deleteRequiresStableStoppedIdentity() async {
    let runningRuntime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime")
    )
    let runningService = makeService(runtime: runningRuntime)

    await #expect(throws: LinuxMachineManagementError.stopBeforeDeleting("dev")) {
      try await runningService.deleteMachine(makeIdentity())
    }

    let legacyTarget = LinuxMachineIdentity(
      id: "dev",
      imageReference: "alpine:3.22",
      platform: "linux/arm64",
      createdAt: nil
    )
    let legacyRuntime = MockLinuxMachineRuntime(
      current: LinuxMachineRuntimeSnapshot(
        identity: legacyTarget,
        state: .stopped,
        backingContainerID: nil,
        isInitialized: true
      )
    )
    let legacyService = makeService(runtime: legacyRuntime)

    await #expect(throws: LinuxMachineManagementError.stableIdentityRequired("dev")) {
      try await legacyService.deleteMachine(legacyTarget)
    }
  }

  @Test
  func deletionRevalidatesAndConfirmsAbsence() async throws {
    let runtime = MockLinuxMachineRuntime(current: makeSnapshot(state: .stopped))
    let service = makeService(runtime: runtime)

    try await service.deleteMachine(makeIdentity())

    #expect(await runtime.calls == [.snapshot("dev"), .delete("dev"), .snapshot("dev")])
    #expect(await runtime.current == nil)
  }

  @Test
  func lifecycleReconcilesRepliesLostAfterCommit() async throws {
    let stopRuntime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime"),
      stopThrowsAfterMutation: true
    )
    try await makeService(runtime: stopRuntime).stopMachine(makeIdentity())
    #expect((await stopRuntime.current)?.state == .stopped)

    let forceRuntime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime"),
      forceStopThrowsAfterMutation: true
    )
    let target = makeIdentity()
    try await makeService(runtime: forceRuntime).forceStopMachine(
      target,
      authorization: .confirmed(for: target)
    )
    #expect((await forceRuntime.current)?.state == .stopped)

    let deleteRuntime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .stopped),
      deleteThrowsAfterMutation: true
    )
    try await makeService(runtime: deleteRuntime).deleteMachine(makeIdentity())
    #expect(await deleteRuntime.current == nil)
  }

  @Test
  func injectedCoordinatorSerializesMachineMutationWithOtherRuntimeWork() async throws {
    let coordinator = RuntimeMutationCoordinator()
    let gate = MachineMutationGate()
    let runtime = MockLinuxMachineRuntime(
      current: makeSnapshot(state: .running, backingContainerID: "dev-runtime")
    )
    let service = makeService(runtime: runtime, coordinator: coordinator)
    let blocker = Task {
      try await coordinator.perform {
        await gate.hold()
      }
    }
    await gate.waitUntilEntered()

    let stop = Task {
      try await service.stopMachine(makeIdentity())
    }
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await runtime.calls.isEmpty)

    await gate.release()
    try await blocker.value
    try await stop.value
    #expect((await runtime.current)?.state == .stopped)
  }

  private func makeService(
    runtime: MockLinuxMachineRuntime,
    coordinator: RuntimeMutationCoordinator = RuntimeMutationCoordinator()
  ) -> AppleMachineManagementService {
    AppleMachineManagementService(
      runtime: runtime,
      runtimeMutationCoordinator: coordinator,
      sleep: { _ in }
    )
  }

  private func makeRequest(
    startAfterCreation: Bool = true
  ) throws -> LinuxMachineCreationRequest {
    try LinuxMachineCreationRequest(
      name: "dev",
      imageReference: "alpine:3.22",
      memoryBytes: 2_048 * LinuxMachineCreationRequest.bytesPerMiB,
      startAfterCreation: startAfterCreation
    )
  }
}

private actor RefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private actor RecordingMachineService: MachineManaging, MachineConfigurationManaging {
  private let returnsPartialCompletion: Bool
  private(set) var configurationTargets: [LinuxMachineIdentity] = []

  init(returnsPartialCompletion: Bool = false) {
    self.returnsPartialCompletion = returnsPartialCompletion
  }

  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    let result = LinuxMachineCreationResult(
      identity: LinuxMachineIdentity(
        id: request.name,
        imageReference: request.imageReference,
        platform: "linux/arm64",
        createdAt: Date(timeIntervalSince1970: 1)
      ),
      state: .stopped,
      isInitialized: false
    )
    await progress(
      ContainerOperationProgress(phase: .completed, message: "Linux machine created")
    )
    if returnsPartialCompletion {
      throw LinuxMachinePartialCompletionError(
        result: result,
        operationMessage: "Setup failed.",
        recovery: .gracefullyStopped
      )
    }
    return result
  }

  func startMachine(_ target: LinuxMachineIdentity) async throws {}
  func stopMachine(_ target: LinuxMachineIdentity) async throws {}
  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws {}
  func deleteMachine(_ target: LinuxMachineIdentity) async throws {}

  func updateConfiguration(
    for target: LinuxMachineIdentity,
    request: LinuxMachineConfigurationUpdateRequest
  ) async throws -> LinuxMachineConfigurationUpdateResult {
    configurationTargets.append(target)
    return LinuxMachineConfigurationUpdateResult(
      target: target,
      configuration: request.configuration,
      state: .running
    )
  }
}

private enum MockMachineRuntimeError: Error {
  case createFailed
  case missing
  case provisionFailed
  case replyLost
  case snapshotFailed
  case stopFailed
}

private enum MockMachineRuntimeCall: Equatable, Sendable {
  case snapshot(String)
  case create(String)
  case boot(String)
  case provision(String, timeoutSeconds: Int)
  case stop(String)
  case forceStop(String)
  case delete(String)
}

private actor ProgressRecorder {
  private(set) var phases: [ContainerOperationProgress.Phase] = []

  func record(_ progress: ContainerOperationProgress) {
    phases.append(progress.phase)
  }
}

private actor MachineMutationGate {
  private var hasEntered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func hold() async {
    hasEntered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor MockLinuxMachineRuntime: LinuxMachineRuntime {
  private(set) var current: LinuxMachineRuntimeSnapshot?
  private(set) var calls: [MockMachineRuntimeCall] = []
  private(set) var hasStartedProvisioning = false

  private let provisionError: MockMachineRuntimeError?
  private let stopError: MockMachineRuntimeError?
  private let stopCompletesAfterSnapshotCount: Int?
  private let suspendProvisioning: Bool
  private let createThrowsAfterCommit: Bool
  private let snapshotFailuresAfterCreate: Int
  private let stopThrowsAfterMutation: Bool
  private let forceStopThrowsAfterMutation: Bool
  private let forceStopLeavesRunning: Bool
  private let deleteThrowsAfterMutation: Bool
  private var remainingSnapshotFailures = 0
  private var stopWasRequested = false
  private var snapshotsSinceStop = 0

  init(
    current: LinuxMachineRuntimeSnapshot? = nil,
    provisionError: MockMachineRuntimeError? = nil,
    stopError: MockMachineRuntimeError? = nil,
    stopCompletesAfterSnapshotCount: Int? = nil,
    suspendProvisioning: Bool = false,
    createThrowsAfterCommit: Bool = false,
    snapshotFailuresAfterCreate: Int = 0,
    stopThrowsAfterMutation: Bool = false,
    forceStopThrowsAfterMutation: Bool = false,
    forceStopLeavesRunning: Bool = false,
    deleteThrowsAfterMutation: Bool = false
  ) {
    self.current = current
    self.provisionError = provisionError
    self.stopError = stopError
    self.stopCompletesAfterSnapshotCount = stopCompletesAfterSnapshotCount
    self.suspendProvisioning = suspendProvisioning
    self.createThrowsAfterCommit = createThrowsAfterCommit
    self.snapshotFailuresAfterCreate = snapshotFailuresAfterCreate
    self.stopThrowsAfterMutation = stopThrowsAfterMutation
    self.forceStopThrowsAfterMutation = forceStopThrowsAfterMutation
    self.forceStopLeavesRunning = forceStopLeavesRunning
    self.deleteThrowsAfterMutation = deleteThrowsAfterMutation
  }

  func snapshot(id: String) throws -> LinuxMachineRuntimeSnapshot? {
    calls.append(.snapshot(id))
    if remainingSnapshotFailures > 0 {
      remainingSnapshotFailures -= 1
      throw MockMachineRuntimeError.snapshotFailed
    }
    if stopWasRequested, let stopCompletesAfterSnapshotCount {
      snapshotsSinceStop += 1
      if snapshotsSinceStop >= stopCompletesAfterSnapshotCount, let current {
        self.current = LinuxMachineRuntimeSnapshot(
          identity: current.identity,
          state: .stopped,
          backingContainerID: nil,
          isInitialized: current.isInitialized
        )
      }
    }
    return current?.identity.id == id ? current : nil
  }

  func create(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineRuntimeSnapshot {
    calls.append(.create(request.name))
    let snapshot = makeSnapshot(state: .stopped, isInitialized: false)
    current = snapshot
    await progress(
      ContainerOperationProgress(phase: .creating, message: "Creating Linux machine")
    )
    if createThrowsAfterCommit {
      remainingSnapshotFailures = snapshotFailuresAfterCreate
      throw MockMachineRuntimeError.createFailed
    }
    return snapshot
  }

  func boot(id: String) throws -> LinuxMachineRuntimeSnapshot {
    calls.append(.boot(id))
    guard let current else { throw MockMachineRuntimeError.missing }
    let running = LinuxMachineRuntimeSnapshot(
      identity: current.identity,
      state: .running,
      backingContainerID: "dev-runtime",
      isInitialized: current.isInitialized
    )
    self.current = running
    return running
  }

  func provisionUser(id: String, timeoutSeconds: Int) async throws {
    calls.append(.provision(id, timeoutSeconds: timeoutSeconds))
    hasStartedProvisioning = true
    if suspendProvisioning {
      try await Task.sleep(for: .seconds(60))
    }
    if let provisionError { throw provisionError }
    guard let current else { throw MockMachineRuntimeError.missing }
    self.current = LinuxMachineRuntimeSnapshot(
      identity: current.identity,
      state: current.state,
      backingContainerID: current.backingContainerID,
      isInitialized: true
    )
  }

  func stop(id: String) throws {
    calls.append(.stop(id))
    stopWasRequested = true
    if let stopError, !stopThrowsAfterMutation { throw stopError }
    guard let current else { return }
    self.current = LinuxMachineRuntimeSnapshot(
      identity: current.identity,
      state: .stopped,
      backingContainerID: nil,
      isInitialized: current.isInitialized
    )
    if stopThrowsAfterMutation || stopError != nil {
      throw stopError ?? MockMachineRuntimeError.replyLost
    }
  }

  func forceStop(backingContainerID: String) throws {
    calls.append(.forceStop(backingContainerID))
    guard !forceStopLeavesRunning else { return }
    guard let current else { return }
    self.current = LinuxMachineRuntimeSnapshot(
      identity: current.identity,
      state: .stopped,
      backingContainerID: nil,
      isInitialized: current.isInitialized
    )
    if forceStopThrowsAfterMutation {
      throw MockMachineRuntimeError.replyLost
    }
  }

  func delete(_ target: LinuxMachineIdentity) throws {
    calls.append(.delete(target.id))
    if current?.identity == target {
      current = nil
    }
    if deleteThrowsAfterMutation {
      throw MockMachineRuntimeError.replyLost
    }
  }
}

private func makeIdentity() -> LinuxMachineIdentity {
  LinuxMachineIdentity(
    id: "dev",
    imageReference: "alpine:3.22",
    platform: "linux/arm64",
    createdAt: Date(timeIntervalSince1970: 1)
  )
}

private func makeSnapshot(
  state: RuntimeState,
  backingContainerID: String? = nil,
  isInitialized: Bool = true
) -> LinuxMachineRuntimeSnapshot {
  LinuxMachineRuntimeSnapshot(
    identity: makeIdentity(),
    state: state,
    backingContainerID: backingContainerID,
    isInitialized: isInitialized
  )
}
