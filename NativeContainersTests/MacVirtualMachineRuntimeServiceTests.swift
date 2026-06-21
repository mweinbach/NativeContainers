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
      engine: RuntimeServiceEngine()
    )

    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(machine.manifest.id)) {
      try await service.start(id: machine.manifest.id)
    }

    let snapshot = service.snapshot(for: machine.manifest.id)
    #expect(snapshot.state == .ownedElsewhere)
    #expect(snapshot.canStart)
    #expect(snapshot.target == nil)
  }
}

@MainActor
private struct RuntimeServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder = RuntimeServiceReleaseRecorder()
  let store: RuntimeServiceLeaseStore
  let engine: RuntimeServiceEngine
  let service: MacVirtualMachineRuntimeService

  var machineID: UUID { machine.manifest.id }

  init(startWaits: Bool = false) throws {
    machine = try makeRuntimeServiceMachine()
    store = RuntimeServiceLeaseStore(machine: machine, releaseRecorder: releaseRecorder)
    engine = RuntimeServiceEngine(startWaits: startWaits)
    service = MacVirtualMachineRuntimeService(leasingStore: store, engine: engine)
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
  private(set) var sessions: [RuntimeServiceSession] = []
  private var firstSessionStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(startWaits: Bool = false) {
    self.startWaits = startWaits
  }

  func makeSession(
    for machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget
  ) -> any MacVirtualMachineRuntimeEngineSession {
    let session = RuntimeServiceSession(target: target, startWaits: startWaits) { [weak self] in
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
  var eventHandler: MacVirtualMachineRuntimeEventHandler?
  var forceStopError: RuntimeServiceTestError?
  private(set) var didStart = false
  private(set) var requestStopCount = 0
  private(set) var forceStopCount = 0

  private let startWaits: Bool
  private let didBeginStart: () -> Void
  private var startContinuation: CheckedContinuation<Void, Never>?

  init(
    target: MacVirtualMachineRuntimeTarget,
    startWaits: Bool,
    didBeginStart: @escaping () -> Void
  ) {
    self.target = target
    self.startWaits = startWaits
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

  func pause() async throws {}
  func resume() async throws {}

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
