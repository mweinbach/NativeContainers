import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct LinuxVirtualMachineRuntimeServiceTests {
  @Test
  func lifecyclePublishesRunningPausedResumedAndStoppedStates() async throws {
    let fixture = try LinuxRuntimeServiceFixture()

    try await fixture.service.start(id: fixture.machineID)
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    let target = try #require(snapshot.target)
    #expect(snapshot.state == .running)
    #expect(snapshot.hasInstallationMedia)

    try await fixture.service.pause(target: target)
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .paused)

    try await fixture.service.resume(target: target)
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .running)

    try fixture.service.requestStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopping)
    #expect(snapshot.canForceStop)
    #expect(fixture.engine.sessions[0].requestStopCount == 1)

    try await fixture.service.forceStop(target: target)
    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(fixture.shutdownScheduler.pendingCount == 0)
    #expect(fixture.engine.sessions[0].closeCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func suspendSavesStopsAndNextStartRestoresTheLinuxSession() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let firstTarget = try #require(
      fixture.service.snapshot(for: fixture.machineID).target
    )

    try await fixture.service.suspend(target: firstTarget)

    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(snapshot.savedStateStatus.summary != nil)
    #expect(fixture.savedState.saveCount == 1)
    #expect(fixture.engine.sessions[0].pauseCount == 1)
    #expect(fixture.engine.sessions[0].saveCount == 1)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)

    try await fixture.service.start(id: fixture.machineID)

    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.savedState.restoreCount == 1)
    #expect(fixture.engine.sessions[1].restoreCount == 1)
    #expect(fixture.engine.sessions[1].resumeCount == 1)
    #expect(fixture.engine.sessions[1].didStart == false)
  }

  @Test
  func incompatibleLinuxSavedStateRequiresExplicitStartFresh() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    fixture.savedState.status = .incompatible("configuration changed")

    await #expect(throws: LinuxVirtualMachineSavedStateError.self) {
      try await fixture.service.start(id: fixture.machineID)
    }
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(!snapshot.canStart)
    #expect(snapshot.canStartFresh)
    #expect(snapshot.savedStateStatus == .incompatible("configuration changed"))

    try await fixture.service.startFresh(id: fixture.machineID)

    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.savedStateStatus == .none)
    #expect(fixture.savedState.discardCount == 1)
    #expect(fixture.engine.sessions.count == 1)
    #expect(fixture.engine.sessions[0].didStart)
  }

  @Test
  func gracefulStopTimeoutAutomaticallyForceStopsHungGuest() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)

    try fixture.service.requestStop(target: target)
    #expect(fixture.shutdownScheduler.pendingCount == 1)

    await fixture.shutdownScheduler.fireNext()

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func callerCancellationNeverReleasesAnAcceptedStart() async throws {
    let fixture = try LinuxRuntimeServiceFixture(startWaits: true)
    let start = Task {
      try await fixture.service.start(id: fixture.machineID)
    }
    await fixture.engine.waitUntilFirstSessionStarts()

    start.cancel()
    await Task.yield()
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .starting)
    #expect(fixture.releaseRecorder.count == 0)

    fixture.engine.sessions[0].completeStart()
    try await start.value
    #expect(fixture.service.snapshot(for: fixture.machineID).state == .running)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func forceStopQueuesDuringStartAndFinalizesAfterStartCallback() async throws {
    let fixture = try LinuxRuntimeServiceFixture(startWaits: true)
    let start = Task {
      try await fixture.service.start(id: fixture.machineID)
    }
    await fixture.engine.waitUntilFirstSessionStarts()
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)

    try await fixture.service.forceStop(target: target)
    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.isForceStopQueued)
    #expect(snapshot.isForceStopCompleteAwaitingCleanup)
    #expect(fixture.releaseRecorder.count == 0)

    fixture.engine.sessions[0].completeStart()
    try await start.value

    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.target == nil)
    #expect(fixture.engine.sessions[0].forceStopCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func ejectsInstallerAndPersistsCompletedInstallation() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)

    let manifest = try await fixture.service.ejectInstallationMedia(target: target)

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(manifest.installState == .stopped)
    #expect(manifest.linuxConfiguration?.installationMediaPath == nil)
    #expect(snapshot.state == .running)
    #expect(!snapshot.hasInstallationMedia)
    #expect(!snapshot.canEjectInstallationMedia)
    #expect(!snapshot.canSuspend)
    #expect(
      snapshot.saveRestoreSupport
        == .unsupported("Restart after installation")
    )
    #expect(fixture.engine.sessions[0].ejectCount == 1)
    #expect(await fixture.store.completionCount == 1)
  }

  @Test
  func completionFailureRetriesPersistenceWithoutDetachingTwice() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    await fixture.store.setCompletionError(.expected)

    await #expect(throws: LinuxRuntimeServiceTestError.expected) {
      _ = try await fixture.service.ejectInstallationMedia(target: target)
    }

    var snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.hasInstallationMedia)
    #expect(snapshot.canEjectInstallationMedia)
    #expect(fixture.engine.sessions[0].ejectCount == 1)

    await fixture.store.setCompletionError(nil)
    _ = try await fixture.service.ejectInstallationMedia(target: target)

    snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(!snapshot.hasInstallationMedia)
    #expect(fixture.engine.sessions[0].ejectCount == 1)
    #expect(await fixture.store.completionCount == 2)
  }

  @Test
  func unavailableForceStopCapabilityFailsWithinBoundAndKeepsRecovery() async throws {
    let fixture = try LinuxRuntimeServiceFixture(
      forceStopCapabilityTimeout: .milliseconds(5)
    )
    try await fixture.service.start(id: fixture.machineID)
    let target = try #require(fixture.service.snapshot(for: fixture.machineID).target)
    fixture.engine.sessions[0].canForceStop = false

    await #expect(throws: LinuxVirtualMachineRuntimeError.self) {
      try await fixture.service.forceStop(target: target)
    }

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .running)
    #expect(snapshot.target == target)
    #expect(snapshot.canForceStop)
    #expect(snapshot.errorMessage?.isEmpty == false)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func duplicateTerminalEventsFinalizeGenerationExactlyOnce() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let session = fixture.engine.sessions[0]

    session.emit(.guestStopped)
    session.emit(.stoppedWithError("late duplicate"))

    let snapshot = fixture.service.snapshot(for: fixture.machineID)
    #expect(snapshot.state == .stopped)
    #expect(snapshot.errorMessage == nil)
    #expect(session.closeCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func staleGenerationCannotForceStopReplacementSession() async throws {
    let fixture = try LinuxRuntimeServiceFixture()
    try await fixture.service.start(id: fixture.machineID)
    let firstTarget = try #require(
      fixture.service.snapshot(for: fixture.machineID).target
    )
    try await fixture.service.forceStop(target: firstTarget)

    try await fixture.service.start(id: fixture.machineID)
    let secondTarget = try #require(
      fixture.service.snapshot(for: fixture.machineID).target
    )
    #expect(secondTarget != firstTarget)

    await #expect(
      throws: LinuxVirtualMachineRuntimeError.staleTarget(firstTarget)
    ) {
      try await fixture.service.forceStop(target: firstTarget)
    }
    #expect(fixture.engine.sessions[1].forceStopCount == 0)
  }
}

@MainActor
private struct LinuxRuntimeServiceFixture {
  let machine: ResolvedLinuxVirtualMachine
  let releaseRecorder = LinuxRuntimeServiceReleaseRecorder()
  let store: LinuxRuntimeServiceStore
  let engine: LinuxRuntimeServiceEngine
  let savedState: LinuxRuntimeServiceSavedStateService
  let shutdownScheduler: LinuxRuntimeServiceShutdownScheduler
  let service: LinuxVirtualMachineRuntimeService

  var machineID: UUID { machine.manifest.id }

  init(
    startWaits: Bool = false,
    forceStopCapabilityTimeout: Duration = .seconds(1)
  ) throws {
    machine = try makeLinuxRuntimeServiceMachine()
    store = LinuxRuntimeServiceStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    engine = LinuxRuntimeServiceEngine(startWaits: startWaits)
    savedState = LinuxRuntimeServiceSavedStateService()
    shutdownScheduler = LinuxRuntimeServiceShutdownScheduler()
    service = LinuxVirtualMachineRuntimeService(
      leasingStore: store,
      installationStore: store,
      engine: engine,
      savedStateService: savedState,
      shutdownPolicy: VirtualMachineShutdownPolicy(
        gracefulStopTimeout: .seconds(1),
        forceStopCapabilityTimeout: forceStopCapabilityTimeout,
        forceStopPollInterval: .milliseconds(1)
      ),
      shutdownScheduler: shutdownScheduler
    )
  }
}

@MainActor
private final class LinuxRuntimeServiceShutdownScheduler:
  VirtualMachineShutdownScheduling
{
  private struct Entry {
    let state: LinuxRuntimeServiceScheduledShutdownState
    let operation: @MainActor @Sendable () async -> Void
  }

  private var entries: [Entry] = []

  var pendingCount: Int {
    entries.count { !$0.state.isCancelled }
  }

  func schedule(
    after delay: Duration,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> VirtualMachineScheduledShutdown {
    let state = LinuxRuntimeServiceScheduledShutdownState()
    entries.append(Entry(state: state, operation: operation))
    return VirtualMachineScheduledShutdown {
      state.cancel()
    }
  }

  func fireNext() async {
    while !entries.isEmpty {
      let entry = entries.removeFirst()
      guard !entry.state.isCancelled else { continue }
      await entry.operation()
      return
    }
  }
}

private final class LinuxRuntimeServiceScheduledShutdownState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() {
    lock.withLock { cancelled = true }
  }
}

private actor LinuxRuntimeServiceStore:
  LinuxVirtualMachineRuntimeLeasing,
  LinuxVirtualMachineInstallationCompleting
{
  let machine: ResolvedLinuxVirtualMachine
  let releaseRecorder: LinuxRuntimeServiceReleaseRecorder
  private(set) var completionCount = 0
  private var completionError: LinuxRuntimeServiceTestError?

  init(
    machine: ResolvedLinuxVirtualMachine,
    releaseRecorder: LinuxRuntimeServiceReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireLinuxRuntime(id: UUID) throws -> LinuxVirtualMachineRuntimeLease {
    let target = LinuxVirtualMachineRuntimeTarget(machineID: id, generation: UUID())
    return LinuxVirtualMachineRuntimeLease(machine: machine, target: target) {
      self.releaseRecorder.record()
    }
  }

  func completeLinuxInstallation(
    lease: LinuxVirtualMachineRuntimeLease
  ) throws -> VirtualMachineManifest {
    completionCount += 1
    if let completionError { throw completionError }
    var manifest = lease.machine.manifest
    manifest.markLinuxInstallationCompleted()
    return manifest
  }

  func setCompletionError(_ error: LinuxRuntimeServiceTestError?) {
    completionError = error
  }
}

private final class LinuxRuntimeServiceReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

@MainActor
private final class LinuxRuntimeServiceEngine: LinuxVirtualMachineRuntimeEngine {
  private let startWaits: Bool
  private(set) var sessions: [LinuxRuntimeServiceSession] = []
  private var firstSessionStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(startWaits: Bool) {
    self.startWaits = startWaits
  }

  func makeSession(
    for machine: ResolvedLinuxVirtualMachine,
    target: LinuxVirtualMachineRuntimeTarget
  ) -> any LinuxVirtualMachineRuntimeEngineSession {
    let session = LinuxRuntimeServiceSession(
      target: target,
      startWaits: startWaits,
      hasInstallationMedia: machine.installationMediaURL != nil
    ) { [weak self] in
      guard let self else { return }
      let waiters = firstSessionStartWaiters
      firstSessionStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
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
private final class LinuxRuntimeServiceSession:
  LinuxVirtualMachineRuntimeEngineSession
{
  let target: LinuxVirtualMachineRuntimeTarget
  let console: LinuxVirtualMachineConsole? = nil
  private(set) var saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport =
    .supported
  private(set) var hasInstallationMedia: Bool
  var canForceStop = true
  var eventHandler: LinuxVirtualMachineRuntimeEventHandler?
  private(set) var didStart = false
  private(set) var pauseCount = 0
  private(set) var resumeCount = 0
  private(set) var requestStopCount = 0
  private(set) var forceStopCount = 0
  private(set) var ejectCount = 0
  private(set) var closeCount = 0
  private(set) var saveCount = 0
  private(set) var restoreCount = 0

  private let startWaits: Bool
  private let didBeginStart: () -> Void
  private var startContinuation: CheckedContinuation<Void, Never>?

  init(
    target: LinuxVirtualMachineRuntimeTarget,
    startWaits: Bool,
    hasInstallationMedia: Bool,
    didBeginStart: @escaping () -> Void
  ) {
    self.target = target
    self.startWaits = startWaits
    self.hasInstallationMedia = hasInstallationMedia
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

  func saveState(to url: URL) async throws {
    saveCount += 1
  }

  func restoreState(from url: URL) async throws {
    restoreCount += 1
  }

  func pause() async throws {
    pauseCount += 1
  }

  func resume() async throws {
    resumeCount += 1
  }

  func requestStop() throws {
    requestStopCount += 1
  }

  func forceStop() async throws {
    forceStopCount += 1
  }

  func ejectInstallationMedia() async throws {
    guard hasInstallationMedia else {
      throw LinuxVirtualMachineRuntimeError.installationMediaNotAttached(
        target.machineID
      )
    }
    ejectCount += 1
    hasInstallationMedia = false
    saveRestoreSupport = .unsupported("Restart after installation")
  }

  func close() {
    closeCount += 1
  }

  func completeStart() {
    startContinuation?.resume()
    startContinuation = nil
  }

  func emit(_ event: LinuxVirtualMachineRuntimeEvent) {
    eventHandler?(event)
  }
}

@MainActor
private final class LinuxRuntimeServiceSavedStateService:
  LinuxVirtualMachineSavedStateManaging
{
  var status: LinuxVirtualMachineSavedStateStatus = .none
  private(set) var saveCount = 0
  private(set) var restoreCount = 0
  private(set) var discardCount = 0

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus {
    status
  }

  func saveCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    saveCount += 1
    try await session.saveState(to: URL(filePath: "/tmp/linux-runtime.vzvmsave"))
    let summary = LinuxVirtualMachineSavedStateSummary(
      createdAt: Date(timeIntervalSince1970: 1_000),
      stateSizeBytes: 4_096
    )
    status = .available(summary)
    return summary
  }

  func restoreCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    restoreCount += 1
    let summary =
      status.summary
      ?? LinuxVirtualMachineSavedStateSummary(
        createdAt: Date(timeIntervalSince1970: 1_000),
        stateSizeBytes: 4_096
      )
    try await session.restoreState(
      from: URL(filePath: "/tmp/linux-runtime.vzvmsave")
    )
    status = .none
    return summary
  }

  func discardCheckpoint(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws {
    discardCount += 1
    status = .none
  }
}

private enum LinuxRuntimeServiceTestError: LocalizedError, Equatable {
  case expected

  var errorDescription: String? { "Expected Linux runtime service failure." }
}

private func makeLinuxRuntimeServiceMachine() throws -> ResolvedLinuxVirtualMachine {
  let identifier = UUID()
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Linux Runtime Service",
    guest: .linux,
    installState: .draft,
    resources: resources
  )
  manifest.markReadyToInstallLinux(
    configuration: LinuxVirtualMachineConfiguration(
      efiVariableStorePath: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
      machineIdentifierPath: LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
      installationMediaPath: LinuxPlatformArtifactURLs.installationMediaManifestPath,
      macAddress: "02:00:00:00:00:03"
    )
  )
  let bundle = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedLinuxVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    efiVariableStoreURL: bundle.appending(
      path: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath
    ),
    machineIdentifierURL: bundle.appending(
      path: LinuxPlatformArtifactURLs.machineIdentifierManifestPath
    ),
    installationMediaURL: bundle.appending(
      path: LinuxPlatformArtifactURLs.installationMediaManifestPath
    )
  )
}
