import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacVirtualMachineRuntimeServiceTests {
  @Test
  func lifecyclePublishesRunningPausedResumedAndStoppedStates() async throws {
    let fixture = try RuntimeServiceFixture()

    try await fixture.service.start(id: fixture.machineID)
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    let target = try #require(snapshot.target)
    #expect(snapshot.state == .running)
    #expect(snapshot.canPause)

    try await fixture.service.pause(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .paused)
    #expect(snapshot.canResume)

    try await fixture.service.resume(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)

    try fixture.service.requestStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopping)
    #expect(snapshot.canForceStop)
    #expect(fixture.engine.sessions[0].requestStopCount == 1)

    try await fixture.service.forceStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func failedForceStopKeepsTheGenerationOwnedAndKillAvailable() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    let session = fixture.engine.sessions[0]
    session.forceStopError = .expected

    try fixture.service.requestStop(target: target)
    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.forceStop(target: target)
    }

    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopping)
    #expect(snapshot.target == target)
    #expect(snapshot.canForceStop)
    #expect(snapshot.errorMessage?.isEmpty == false)
    #expect(fixture.releaseRecorder.count == 0)

    session.forceStopError = nil
    try await fixture.service.forceStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func callerCancellationNeverReleasesAnAcceptedStart() async throws {
    let fixture = try RuntimeServiceFixture(startWaits: true)
    let start = Task {
      try await fixture.service.start(id: fixture.machineID)
    }
    await fixture.engine.waitUntilFirstSessionStarts()

    start.cancel()
    await Task.yield()
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .starting)
    #expect(fixture.releaseRecorder.count == 0)
    await #expect(throws: MacVirtualMachineRuntimeError.duplicateSession(fixture.machineID)) {
      try await fixture.service.start(id: fixture.machineID)
    }

    fixture.engine.sessions[0].completeStart()
    try await start.value
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .running)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func delegateStopAndDuplicateTerminalEventsFinalizeExactlyOnce() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let session = fixture.engine.sessions[0]

    session.emit(.guestStopped)
    session.emit(.stoppedWithError("late duplicate"))

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.errorMessage == nil)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func staleGenerationCannotForceStopAReplacementSession() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let firstTarget = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.engine.sessions[0].emit(.guestStopped)

    try await fixture.service.start(id: fixture.machineID)
    let secondTarget = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    #expect(secondTarget != firstTarget)

    await #expect(throws: MacVirtualMachineRuntimeError.staleTarget(firstTarget)) {
      try await fixture.service.forceStop(target: firstTarget)
    }
    #expect(fixture.service.snapshot(for: fixture.machineID).target == secondTarget)
    #expect(fixture.engine.sessions[1].forceStopCount == 0)
  }

  @Test
  func foreignOwnershipIsPublishedAsRetryableRuntimeState() async throws {
    let machine = try makeRuntimeServiceMachine()
    let store = RuntimeServiceLeaseStore(
      machine: machine,
      acquisitionError: .ownedElsewhere(machine.manifest.id)
    )
    let service = MacVirtualMachineRuntimeService(
      leasingStore: store,
      engine: RuntimeServiceEngine(),
      savedStateService: RuntimeServiceSavedStateService()
    )

    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(machine.manifest.id)) {
      try await service.start(id: machine.manifest.id)
    }

    let snapshot = service.snapshot(for: machine.manifest.id)
    #expect(snapshot.state == .ownedElsewhere)
    #expect(snapshot.canStart)
    #expect(snapshot.target == nil)
  }

  @Test
  func availableCheckpointRestoresThenResumesWithoutColdBoot() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.status = .available(fixture.savedStateService.summary)

    try await fixture.service.start(id: fixture.machineID)

    let session = fixture.engine.sessions[0]
    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.savedStateStatus == .none)
    #expect(session.didStart == false)
    #expect(session.resumeCount == 1)
    #expect(fixture.savedStateService.restoreCount == 1)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func failedRestoreConsumesCheckpointAndReleasesGeneration() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.status = .available(fixture.savedStateService.summary)
    fixture.savedStateService.restoreError = .expected

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.start(id: fixture.machineID)
    }

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.savedStateStatus == .none)
    #expect(snapshot.target == nil)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func suspendSavesStopsAndPublishesReusableCheckpoint() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)

    try await fixture.service.suspend(target: target)

    let session = fixture.engine.sessions[0]
    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.savedStateStatus == .available(fixture.savedStateService.summary))
    #expect(session.pauseCount == 1)
    #expect(fixture.savedStateService.saveCount == 1)
    #expect(session.forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func saveFailureKeepsPausedGenerationAndKillAvailable() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.savedStateService.saveError = .expected

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.suspend(target: target)
    }

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .paused)
    #expect(snapshot.target == target)
    #expect(snapshot.canForceStop)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func forceStopQueuesDuringSaveAndCompletesAfterCallback() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.savedStateService.saveWaits = true

    let suspension = Task {
      try await fixture.service.suspend(target: target)
    }
    await fixture.savedStateService.waitUntilSaveBegins()

    try await fixture.service.forceStop(target: target)
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopping)
    #expect(snapshot.isForceStopQueued)
    #expect(snapshot.isForceStopCompleteAwaitingCleanup)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 0)

    fixture.savedStateService.completeSave()
    try await suspension.value
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func stopFailureAfterSaveKeepsCheckpointUntilLiveResumeDiscardsIt() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    let session = fixture.engine.sessions[0]
    session.forceStopError = .expected

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.suspend(target: target)
    }

    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .paused)
    #expect(snapshot.savedStateStatus == .available(fixture.savedStateService.summary))
    #expect(snapshot.canSuspend == false)
    #expect(fixture.releaseRecorder.count == 0)

    session.forceStopError = nil
    try await fixture.service.resume(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.savedStateService.discardCount == 1)
  }

  @Test
  func incompatibleCheckpointBlocksBootUntilExplicitFreshStart() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.status = .incompatible("host changed")

    await #expect(throws: MacVirtualMachineSavedStateError.self) {
      try await fixture.service.start(id: fixture.machineID)
    }
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.savedStateStatus == .incompatible("host changed"))
    #expect(snapshot.canStart == false)
    #expect(fixture.engine.sessions.isEmpty)
    #expect(fixture.releaseRecorder.count == 1)

    try await fixture.service.startFresh(id: fixture.machineID)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.savedStateService.discardCount == 1)
  }

  @Test
  func refreshUsesTemporaryLeaseAndPublishesSavedState() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.status = .available(fixture.savedStateService.summary)

    await fixture.service.refreshSavedState(id: fixture.machineID)

    #expect(
      fixture.service.snapshot(for: fixture.machineID).savedStateStatus
        == .available(fixture.savedStateService.summary)
    )
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func resumeFailureAfterRestoreKeepsConsumedCheckpointPausedAndOwned() async throws {
    let fixture = try RuntimeServiceFixture(resumeError: .expected)
    fixture.savedStateService.status = .available(fixture.savedStateService.summary)

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.start(id: fixture.machineID)
    }

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .paused)
    #expect(snapshot.savedStateStatus == .none)
    #expect(snapshot.target != nil)
    #expect(snapshot.canForceStop)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func delegateStopDuringSaveDefersReleaseUntilCheckpointFinishes() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.savedStateService.saveWaits = true

    let suspension = Task {
      try await fixture.service.suspend(target: target)
    }
    await fixture.savedStateService.waitUntilSaveBegins()
    fixture.engine.sessions[0].emit(.stoppedWithError("stopped while saving"))
    #expect(fixture.releaseRecorder.count == 0)

    fixture.savedStateService.completeSave()
    try await suspension.value

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.errorMessage == "stopped while saving")
    #expect(snapshot.savedStateStatus == .available(fixture.savedStateService.summary))
    #expect(fixture.engine.sessions[0].forceStopCount == 0)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func queuedForceStopSurvivesSaveFailureAndFinalizesAfterCallback() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.savedStateService.saveWaits = true

    let suspension = Task {
      try await fixture.service.suspend(target: target)
    }
    await fixture.savedStateService.waitUntilSaveBegins()
    try await fixture.service.forceStop(target: target)
    fixture.savedStateService.saveError = .expected
    fixture.savedStateService.completeSave()

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await suspension.value
    }

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func queuedForceStopWaitsForFrameworkCapabilityThenKillsHungSave() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    let session = fixture.engine.sessions[0]
    session.canForceStop = false
    fixture.savedStateService.saveWaits = true

    let suspension = Task {
      try await fixture.service.suspend(target: target)
    }
    await fixture.savedStateService.waitUntilSaveBegins()
    let kill = Task {
      try await fixture.service.forceStop(target: target)
    }
    await Task.yield()
    #expect(fixture.service.snapshot(for: fixture.machineID).isForceStopQueued)
    #expect(session.forceStopCount == 0)

    session.canForceStop = true
    try await kill.value
    #expect(session.forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 0)

    fixture.savedStateService.completeSave()
    try await suspension.value
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .stopped)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func inFlightSavedStateRefreshCannotBeOverwrittenByStart() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.inspectWaits = true

    let refresh = Task {
      await fixture.service.refreshSavedState(id: fixture.machineID)
    }
    await fixture.savedStateService.waitUntilInspectionBegins()

    await #expect(
      throws: MacVirtualMachineRuntimeError.operationInProgress(fixture.machineID)
    ) {
      try await fixture.service.start(id: fixture.machineID)
    }
    #expect(fixture.engine.sessions.isEmpty)

    fixture.savedStateService.completeInspection()
    await refresh.value
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .stopped)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func failedQueuedForceStopCanRetryWhileSaveRemainsPending() async throws {
    let fixture = try RuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    let session = fixture.engine.sessions[0]
    session.forceStopError = .expected
    fixture.savedStateService.saveWaits = true

    let suspension = Task {
      try await fixture.service.suspend(target: target)
    }
    await fixture.savedStateService.waitUntilSaveBegins()

    await #expect(throws: RuntimeServiceTestError.expected) {
      try await fixture.service.forceStop(target: target)
    }
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .saving)
    #expect(snapshot.isForceStopQueued == false)
    #expect(snapshot.canForceStop)
    #expect(fixture.releaseRecorder.count == 0)

    session.forceStopError = nil
    try await fixture.service.forceStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.isForceStopCompleteAwaitingCleanup)

    fixture.savedStateService.completeSave()
    try await suspension.value
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .stopped)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func savedStateDiscardSerializesAgainstStart() async throws {
    let fixture = try RuntimeServiceFixture()
    fixture.savedStateService.status = .available(fixture.savedStateService.summary)
    fixture.savedStateService.discardWaits = true

    let discard = Task {
      try await fixture.service.discardSavedState(id: fixture.machineID)
    }
    await fixture.savedStateService.waitUntilDiscardBegins()
    #expect(
      fixture.service.snapshot(for: fixture.machineID).state
        == .discardingSavedState
    )
    #expect(fixture.service.snapshot(for: fixture.machineID).canStartFresh == false)
    #expect(
      fixture.service.snapshot(for: fixture.machineID).canDiscardSavedState
        == false
    )
    await #expect(
      throws: MacVirtualMachineRuntimeError.operationInProgress(fixture.machineID)
    ) {
      try await fixture.service.start(id: fixture.machineID)
    }

    fixture.savedStateService.completeDiscard()
    try await discard.value
    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.releaseRecorder.count == 1)
  }
}

@MainActor
private struct RuntimeServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder = RuntimeServiceReleaseRecorder()
  let store: RuntimeServiceLeaseStore
  let engine: RuntimeServiceEngine
  let savedStateService: RuntimeServiceSavedStateService
  let service: MacVirtualMachineRuntimeService

  var machineID: UUID { machine.manifest.id }

  init(
    startWaits: Bool = false,
    resumeError: RuntimeServiceTestError? = nil
  ) throws {
    machine = try makeRuntimeServiceMachine()
    store = RuntimeServiceLeaseStore(machine: machine, releaseRecorder: releaseRecorder)
    engine = RuntimeServiceEngine(
      startWaits: startWaits,
      resumeError: resumeError
    )
    savedStateService = RuntimeServiceSavedStateService()
    service = MacVirtualMachineRuntimeService(
      leasingStore: store,
      engine: engine,
      savedStateService: savedStateService
    )
  }
}

@MainActor
private final class RuntimeServiceSavedStateService:
  MacVirtualMachineSavedStateManaging
{
  let summary = MacVirtualMachineSavedStateSummary(
    createdAt: Date(timeIntervalSince1970: 1),
    stateSizeBytes: 1
  )
  var status: MacVirtualMachineSavedStateStatus = .none
  var saveError: RuntimeServiceTestError?
  var restoreError: RuntimeServiceTestError?
  var inspectWaits = false
  var discardWaits = false
  var saveWaits = false
  private(set) var saveCount = 0
  private(set) var restoreCount = 0
  private(set) var discardCount = 0
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveWaiters: [CheckedContinuation<Void, Never>] = []
  private var inspectContinuation: CheckedContinuation<Void, Never>?
  private var inspectWaiters: [CheckedContinuation<Void, Never>] = []
  private var discardContinuation: CheckedContinuation<Void, Never>?
  private var discardWaiters: [CheckedContinuation<Void, Never>] = []

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    let waiters = inspectWaiters
    inspectWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if inspectWaits {
      await withCheckedContinuation { continuation in
        inspectContinuation = continuation
      }
    }
    return status
  }

  func saveCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
    saveCount += 1
    let waiters = saveWaiters
    saveWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if saveWaits {
      await withCheckedContinuation { continuation in
        saveContinuation = continuation
      }
    }
    if let saveError { throw saveError }
    status = .available(summary)
    return summary
  }

  func restoreCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
    guard status.summary != nil else { throw RuntimeServiceTestError.expected }
    restoreCount += 1
    status = .none
    if let restoreError { throw restoreError }
    return summary
  }

  func discardCheckpoint(for lease: MacVirtualMachineRuntimeLease) async throws {
    discardCount += 1
    let waiters = discardWaiters
    discardWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if discardWaits {
      await withCheckedContinuation { continuation in
        discardContinuation = continuation
      }
    }
    status = .none
  }

  func waitUntilSaveBegins() async {
    if saveCount > 0 { return }
    await withCheckedContinuation { continuation in
      saveWaiters.append(continuation)
    }
  }

  func completeSave() {
    saveContinuation?.resume()
    saveContinuation = nil
  }

  func waitUntilInspectionBegins() async {
    if inspectContinuation != nil { return }
    await withCheckedContinuation { continuation in
      inspectWaiters.append(continuation)
    }
  }

  func completeInspection() {
    inspectContinuation?.resume()
    inspectContinuation = nil
  }

  func waitUntilDiscardBegins() async {
    if discardContinuation != nil { return }
    await withCheckedContinuation { continuation in
      discardWaiters.append(continuation)
    }
  }

  func completeDiscard() {
    discardContinuation?.resume()
    discardContinuation = nil
  }
}

private actor RuntimeServiceLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: RuntimeServiceReleaseRecorder
  let acquisitionError: MacVirtualMachineRuntimeError?

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: RuntimeServiceReleaseRecorder = RuntimeServiceReleaseRecorder(),
    acquisitionError: MacVirtualMachineRuntimeError? = nil
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
    self.acquisitionError = acquisitionError
  }

  func acquireMacOSRuntime(id: UUID) throws -> MacVirtualMachineRuntimeLease {
    if let acquisitionError { throw acquisitionError }
    let target = MacVirtualMachineRuntimeTarget(machineID: id, generation: UUID())
    return MacVirtualMachineRuntimeLease(machine: machine, target: target) {
      self.releaseRecorder.record()
    }
  }
}

private final class RuntimeServiceReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

@MainActor
private final class RuntimeServiceEngine: MacVirtualMachineRuntimeEngine {
  private let startWaits: Bool
  private let resumeError: RuntimeServiceTestError?
  private(set) var sessions: [RuntimeServiceSession] = []
  private var firstSessionStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    startWaits: Bool = false,
    resumeError: RuntimeServiceTestError? = nil
  ) {
    self.startWaits = startWaits
    self.resumeError = resumeError
  }

  func makeSession(
    for machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget
  ) -> any MacVirtualMachineRuntimeEngineSession {
    let session = RuntimeServiceSession(
      target: target,
      startWaits: startWaits,
      resumeError: resumeError
    ) { [weak self] in
      guard let self else { return }
      let waiters = firstSessionStartWaiters
      firstSessionStartWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
    sessions.append(session)
    return session
  }

  func waitUntilFirstSessionStarts() async {
    if sessions.first?.didStart == true { return }
    await withCheckedContinuation { continuation in
      firstSessionStartWaiters.append(continuation)
    }
  }
}

@MainActor
private final class RuntimeServiceSession: MacVirtualMachineRuntimeEngineSession {
  let target: MacVirtualMachineRuntimeTarget
  let console: MacVirtualMachineConsole? = nil
  let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport = .supported
  var canForceStop = true
  var eventHandler: MacVirtualMachineRuntimeEventHandler?
  var forceStopError: RuntimeServiceTestError?
  private(set) var didStart = false
  private(set) var pauseCount = 0
  private(set) var resumeCount = 0
  private(set) var requestStopCount = 0
  private(set) var forceStopCount = 0

  private let startWaits: Bool
  private let resumeError: RuntimeServiceTestError?
  private let didBeginStart: () -> Void
  private var startContinuation: CheckedContinuation<Void, Never>?

  init(
    target: MacVirtualMachineRuntimeTarget,
    startWaits: Bool,
    resumeError: RuntimeServiceTestError?,
    didBeginStart: @escaping () -> Void
  ) {
    self.target = target
    self.startWaits = startWaits
    self.resumeError = resumeError
    self.didBeginStart = didBeginStart
  }

  func start() async throws {
    didStart = true
    didBeginStart()
    if startWaits {
      await withCheckedContinuation { continuation in
        startContinuation = continuation
      }
    }
  }

  func saveState(to url: URL) async throws {}
  func restoreState(from url: URL) async throws {}

  func pause() async throws {
    pauseCount += 1
  }

  func resume() async throws {
    resumeCount += 1
    if let resumeError { throw resumeError }
  }

  func requestStop() throws {
    requestStopCount += 1
  }

  func forceStop() async throws {
    forceStopCount += 1
    if let forceStopError { throw forceStopError }
  }

  func completeStart() {
    startContinuation?.resume()
    startContinuation = nil
  }

  func emit(_ event: MacVirtualMachineRuntimeEvent) {
    eventHandler?(event)
  }
}

private enum RuntimeServiceTestError: LocalizedError, Equatable {
  case expected

  var errorDescription: String? { "Expected runtime service failure." }
}

private func makeRuntimeServiceMachine() throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  let manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Runtime Service",
    guest: .macOS,
    installState: .stopped,
    resources: resources
  )
  let bundle = URL(filePath: "/tmp/\(identifier.uuidString).nativevm", directoryHint: .isDirectory)
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundle.appending(path: "HardwareModel"),
    machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
  )
}
