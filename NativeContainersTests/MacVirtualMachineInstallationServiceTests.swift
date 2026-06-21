import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacVirtualMachineInstallationServiceTests {
  @Test
  func successfulInstallUsesLeaseAndMonotonicProgress() async throws {
    let machine = try makePreparedMachine()
    let store = TestMacInstallationStore(machine: machine)
    let session = TestMacInstallationSession(
      behavior: .succeed,
      fractions: [0.4, 0.2, 0.8]
    )
    let service = MacVirtualMachineInstallationService(
      store: store,
      engine: TestMacInstallationEngine(session: session)
    )
    let recorder = MacInstallationProgressRecorder()

    try await service.install(id: machine.manifest.id) { update in
      recorder.record(update)
    }

    let events = await store.events
    #expect(events.map(\.kind) == [.stage, .begin, .complete])
    #expect(recorder.fractions == [0.4, 0.4, 0.8, 1])
    #expect(recorder.phases.first == .preparing)
    #expect(recorder.phases.last == .finalizing)
  }

  @Test
  func preflightFailureDoesNotTakeInstallationLease() async throws {
    let machine = try makePreparedMachine()
    let store = TestMacInstallationStore(machine: machine)
    let service = MacVirtualMachineInstallationService(
      store: store,
      engine: TestMacInstallationEngine(error: TestMacInstallationError.expected)
    )

    do {
      try await service.install(id: machine.manifest.id)
      Issue.record("Preflight failure must be surfaced.")
    } catch TestMacInstallationError.expected {
      // Expected.
    }

    #expect(await store.events.map(\.kind) == [.stage, .discard])
  }

  @Test
  func installerFailureAbortsStagedLeaseForRetry() async throws {
    let machine = try makePreparedMachine()
    let store = TestMacInstallationStore(machine: machine)
    let session = TestMacInstallationSession(
      behavior: .fail,
      fractions: [0.1]
    )
    let service = MacVirtualMachineInstallationService(
      store: store,
      engine: TestMacInstallationEngine(session: session)
    )

    do {
      try await service.install(id: machine.manifest.id)
      Issue.record("Installation failure must be surfaced.")
    } catch TestMacInstallationError.expected {
      // Expected.
    }

    let events = await store.events
    #expect(events.map(\.kind) == [.stage, .begin, .abort])
    #expect(events.last?.failureKind == .failed)
  }

  @Test
  func durableAbortFailureIsSurfacedInsteadOfSilentlyLeavingInstallingState() async throws {
    let machine = try makePreparedMachine()
    let store = TestMacInstallationStore(
      machine: machine,
      abortError: TestMacInstallationError.persistence
    )
    let session = TestMacInstallationSession(
      behavior: .fail,
      fractions: []
    )
    let service = MacVirtualMachineInstallationService(
      store: store,
      engine: TestMacInstallationEngine(session: session)
    )

    do {
      try await service.install(id: machine.manifest.id)
      Issue.record("A durable-state failure must be surfaced.")
    } catch let error as MacVirtualMachineInstallationError {
      guard case .statePersistenceFailed(let operation, let persistence) = error else {
        Issue.record("Unexpected installation error: \(error)")
        return
      }
      #expect(operation.contains("expected"))
      #expect(persistence.contains("persistence"))
    }
  }

  @Test
  func cancellationAbortsStagedLeaseAndWaitsForSession() async throws {
    let machine = try makePreparedMachine()
    let store = TestMacInstallationStore(machine: machine)
    let signal = MacInstallationSignal()
    let session = TestMacInstallationSession(
      behavior: .waitForCancellation(signal),
      fractions: []
    )
    let service = MacVirtualMachineInstallationService(
      store: store,
      engine: TestMacInstallationEngine(session: session)
    )

    let task = Task {
      try await service.install(id: machine.manifest.id)
    }
    await signal.waitUntilStarted()
    task.cancel()

    do {
      try await task.value
      Issue.record("A cancelled installation must throw CancellationError.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(await signal.didFinish)
    let events = await store.events
    #expect(events.map(\.kind) == [.stage, .begin, .abort])
    #expect(events.last?.failureKind == .cancelled)
  }

  private func makePreparedMachine() throws -> PreparedMacVirtualMachine {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Installation Test",
      guest: .macOS,
      resources: resources
    )
    let root = URL(filePath: "/tmp/Installation-Test")
    manifest.markReadyToInstallMacOS(
      restoreImageURL: root.appending(path: "Restore.ipsw"),
      auxiliaryStoragePath: "MacPlatform/AuxiliaryStorage",
      hardwareModelPath: "MacPlatform/HardwareModel.bin",
      machineIdentifierPath: "MacPlatform/MachineIdentifier.bin"
    )
    return PreparedMacVirtualMachine(
      manifest: manifest,
      bundleURL: root,
      restoreImageURL: root.appending(path: "Restore.ipsw"),
      diskImageURL: root.appending(path: "Disk.img"),
      auxiliaryStorageURL: root.appending(path: "MacPlatform/AuxiliaryStorage"),
      hardwareModelURL: root.appending(path: "MacPlatform/HardwareModel.bin"),
      machineIdentifierURL: root.appending(path: "MacPlatform/MachineIdentifier.bin")
    )
  }
}

private enum TestMacInstallationError: LocalizedError {
  case expected
  case persistence

  var errorDescription: String? {
    switch self {
    case .expected:
      "expected installation failure"
    case .persistence:
      "persistence failure"
    }
  }
}

private enum TestMacInstallationEventKind: Equatable {
  case stage
  case discard
  case begin
  case complete
  case abort
  case recover
}

private struct TestMacInstallationEvent: Equatable {
  let kind: TestMacInstallationEventKind
  let operationID: UUID?
  let failureKind: VirtualMachineInstallationFailureKind?

  init(
    _ kind: TestMacInstallationEventKind,
    operationID: UUID? = nil,
    failureKind: VirtualMachineInstallationFailureKind? = nil
  ) {
    self.kind = kind
    self.operationID = operationID
    self.failureKind = failureKind
  }
}

private actor TestMacInstallationStore: MacVirtualMachineInstallationStoring {
  let machine: PreparedMacVirtualMachine
  let abortError: (any Error)?
  private(set) var events: [TestMacInstallationEvent] = []

  init(machine: PreparedMacVirtualMachine, abortError: (any Error)? = nil) {
    self.machine = machine
    self.abortError = abortError
  }

  func stageMacOSInstallation(
    id: UUID,
    operationID: UUID
  ) -> PreparedMacVirtualMachine {
    events.append(TestMacInstallationEvent(.stage, operationID: operationID))
    return machine
  }

  func discardStagedMacOSInstallation(id: UUID, operationID: UUID) {
    events.append(TestMacInstallationEvent(.discard, operationID: operationID))
  }

  func beginMacOSInstallation(id: UUID, operationID: UUID) {
    events.append(TestMacInstallationEvent(.begin, operationID: operationID))
  }

  func completeMacOSInstallation(id: UUID, operationID: UUID) {
    events.append(TestMacInstallationEvent(.complete, operationID: operationID))
  }

  func abortMacOSInstallation(
    id: UUID,
    operationID: UUID,
    kind: VirtualMachineInstallationFailureKind,
    message: String
  ) throws {
    if let abortError {
      throw abortError
    }
    events.append(
      TestMacInstallationEvent(
        .abort,
        operationID: operationID,
        failureKind: kind
      )
    )
  }

  func recoverInterruptedMacOSInstallations() {
    events.append(TestMacInstallationEvent(.recover))
  }
}

@MainActor
private final class TestMacInstallationEngine: MacVirtualMachineInstallationEngine {
  private let session: (any MacVirtualMachineInstallationSession)?
  private let error: (any Error)?

  init(session: any MacVirtualMachineInstallationSession) {
    self.session = session
    self.error = nil
  }

  init(error: any Error) {
    self.session = nil
    self.error = error
  }

  func makeSession(
    for machine: PreparedMacVirtualMachine
  ) throws -> any MacVirtualMachineInstallationSession {
    if let error {
      throw error
    }
    return session!
  }
}

@MainActor
private final class TestMacInstallationSession: MacVirtualMachineInstallationSession {
  enum Behavior {
    case succeed
    case fail
    case waitForCancellation(MacInstallationSignal)
  }

  private let behavior: Behavior
  private let fractions: [Double]

  init(behavior: Behavior, fractions: [Double]) {
    self.behavior = behavior
    self.fractions = fractions
  }

  func install(
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {
    for fraction in fractions {
      progress(
        MacVirtualMachineInstallationProgress(
          phase: .installing,
          fractionCompleted: fraction
        )
      )
    }

    switch behavior {
    case .succeed:
      return
    case .fail:
      throw TestMacInstallationError.expected
    case .waitForCancellation(let signal):
      await signal.markStarted()
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        await signal.markFinished()
        throw error
      }
    }
  }
}

@MainActor
private final class MacInstallationProgressRecorder {
  private(set) var phases: [MacVirtualMachineInstallationPhase] = []
  private(set) var fractions: [Double] = []

  func record(_ update: MacVirtualMachineInstallationProgress) {
    phases.append(update.phase)
    if let fraction = update.fractionCompleted {
      fractions.append(fraction)
    }
  }
}

private actor MacInstallationSignal {
  private(set) var didStart = false
  private(set) var didFinish = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    didStart = true
    let currentWaiters = waiters
    waiters.removeAll()
    currentWaiters.forEach { $0.resume() }
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func markFinished() {
    didFinish = true
  }
}
