import Foundation

typealias MacVirtualMachineRuntimeEventHandler =
  @MainActor @Sendable (MacVirtualMachineRuntimeEvent) -> Void

@MainActor
protocol MacVirtualMachineRuntimeEngine: Sendable {
  func makeSession(
    for machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget
  ) throws -> any MacVirtualMachineRuntimeEngineSession
}

@MainActor
protocol MacVirtualMachineRuntimeEngineSession: AnyObject {
  var target: MacVirtualMachineRuntimeTarget { get }
  var console: MacVirtualMachineConsole? { get }
  var eventHandler: MacVirtualMachineRuntimeEventHandler? { get set }

  func start() async throws
  func pause() async throws
  func resume() async throws
  func requestStop() throws
  func forceStop() async throws
}

@MainActor
protocol MacVirtualMachineRuntimeManaging: Sendable {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot
  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot>
  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole?

  func start(id: UUID) async throws
  func pause(target: MacVirtualMachineRuntimeTarget) async throws
  func resume(target: MacVirtualMachineRuntimeTarget) async throws
  func requestStop(target: MacVirtualMachineRuntimeTarget) throws
  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws
}

@MainActor
final class MacVirtualMachineRuntimeService: MacVirtualMachineRuntimeManaging {
  private struct SessionRecord {
    let lease: MacVirtualMachineRuntimeLease
    let session: any MacVirtualMachineRuntimeEngineSession
  }

  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let engine: any MacVirtualMachineRuntimeEngine
  private var sessions: [UUID: SessionRecord] = [:]
  private var operationTokens: [UUID: UUID] = [:]
  private var snapshots: [UUID: MacVirtualMachineRuntimeSnapshot] = [:]
  private var subscribers:
    [UUID: [UUID: AsyncStream<MacVirtualMachineRuntimeSnapshot>.Continuation]] = [:]

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    engine: any MacVirtualMachineRuntimeEngine
  ) {
    self.leasingStore = leasingStore
    self.engine = engine
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    snapshots[machineID] ?? MacVirtualMachineRuntimeSnapshot(machineID: machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    let subscriptionID = UUID()
    let pair = AsyncStream.makeStream(
      of: MacVirtualMachineRuntimeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    subscribers[machineID, default: [:]][subscriptionID] = pair.continuation
    _ = pair.continuation.yield(snapshot(for: machineID))
    pair.continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeSubscriber(subscriptionID, for: machineID)
      }
    }
    return pair.stream
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? {
    guard let record = sessions[target.machineID], record.lease.target == target else {
      return nil
    }
    return record.session.console
  }

  func start(id: UUID) async throws {
    guard sessions[id] == nil else {
      throw MacVirtualMachineRuntimeError.duplicateSession(id)
    }
    guard operationTokens[id] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(id)
    }

    let operationToken = UUID()
    operationTokens[id] = operationToken
    publish(machineID: id, state: .starting)

    do {
      let lease = try await leasingStore.acquireMacOSRuntime(id: id)
      guard operationTokens[id] == operationToken else {
        lease.release()
        throw MacVirtualMachineRuntimeError.operationInProgress(id)
      }

      let session: any MacVirtualMachineRuntimeEngineSession
      do {
        session = try engine.makeSession(for: lease.machine, target: lease.target)
      } catch {
        lease.release()
        throw error
      }
      session.eventHandler = { [weak self] event in
        self?.receive(event, from: lease.target)
      }
      sessions[id] = SessionRecord(lease: lease, session: session)
      publish(machineID: id, target: lease.target, state: .starting)

      do {
        try await session.start()
      } catch {
        if isCurrent(lease.target) {
          finishSession(lease.target, errorMessage: error.localizedDescription)
        }
        throw error
      }

      guard isCurrent(lease.target), operationTokens[id] == operationToken else { return }
      operationTokens[id] = nil
      publish(machineID: id, target: lease.target, state: .running)
    } catch {
      if operationTokens[id] == operationToken {
        operationTokens[id] = nil
        publish(
          machineID: id,
          state: idleState(after: error),
          errorMessage: error.localizedDescription
        )
      }
      throw error
    }
  }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    let record = try beginOperation(target: target, expected: .running, transition: .pausing)
    let operationToken = operationTokens[target.machineID]!
    do {
      try await record.session.pause()
      guard isCurrent(target), operationTokens[target.machineID] == operationToken else { return }
      operationTokens[target.machineID] = nil
      publish(machineID: target.machineID, target: target, state: .paused)
    } catch {
      restoreAfterFailedOperation(
        target: target,
        token: operationToken,
        state: .running,
        error: error
      )
      throw error
    }
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    let record = try beginOperation(target: target, expected: .paused, transition: .resuming)
    let operationToken = operationTokens[target.machineID]!
    do {
      try await record.session.resume()
      guard isCurrent(target), operationTokens[target.machineID] == operationToken else { return }
      operationTokens[target.machineID] = nil
      publish(machineID: target.machineID, target: target, state: .running)
    } catch {
      restoreAfterFailedOperation(
        target: target,
        token: operationToken,
        state: .paused,
        error: error
      )
      throw error
    }
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canRequestStop else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operationTokens[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    do {
      try record.session.requestStop()
      publish(machineID: target.machineID, target: target, state: .stopping)
    } catch {
      publish(
        machineID: target.machineID,
        target: target,
        state: current.state,
        errorMessage: error.localizedDescription
      )
      throw error
    }
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canForceStop else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operationTokens[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    let operationToken = UUID()
    operationTokens[target.machineID] = operationToken
    publish(machineID: target.machineID, target: target, state: .stopping)
    do {
      try await record.session.forceStop()
      guard isCurrent(target), operationTokens[target.machineID] == operationToken else { return }
      finishSession(target)
    } catch {
      restoreAfterFailedOperation(
        target: target,
        token: operationToken,
        state: current.state,
        error: error
      )
      throw error
    }
  }

  private func beginOperation(
    target: MacVirtualMachineRuntimeTarget,
    expected: MacVirtualMachineRuntimeState,
    transition: MacVirtualMachineRuntimeState
  ) throws -> SessionRecord {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.state == expected else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operationTokens[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }
    operationTokens[target.machineID] = UUID()
    publish(machineID: target.machineID, target: target, state: transition)
    return record
  }

  private func currentRecord(
    for target: MacVirtualMachineRuntimeTarget
  ) throws -> SessionRecord {
    guard let record = sessions[target.machineID] else {
      throw MacVirtualMachineRuntimeError.noActiveSession(target.machineID)
    }
    guard record.lease.target == target else {
      throw MacVirtualMachineRuntimeError.staleTarget(target)
    }
    return record
  }

  private func restoreAfterFailedOperation(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID,
    state: MacVirtualMachineRuntimeState,
    error: any Error
  ) {
    guard isCurrent(target), operationTokens[target.machineID] == token else { return }
    operationTokens[target.machineID] = nil
    publish(
      machineID: target.machineID,
      target: target,
      state: state,
      errorMessage: error.localizedDescription
    )
  }

  private func receive(
    _ event: MacVirtualMachineRuntimeEvent,
    from target: MacVirtualMachineRuntimeTarget
  ) {
    guard isCurrent(target) else { return }
    switch event {
    case .guestStopped:
      finishSession(target)
    case .stoppedWithError(let message):
      finishSession(target, errorMessage: message)
    }
  }

  private func finishSession(
    _ target: MacVirtualMachineRuntimeTarget,
    errorMessage: String? = nil
  ) {
    guard let record = sessions[target.machineID], record.lease.target == target else { return }
    sessions[target.machineID] = nil
    operationTokens[target.machineID] = nil
    record.session.eventHandler = nil
    record.lease.release()
    publish(
      machineID: target.machineID,
      state: .stopped,
      errorMessage: errorMessage
    )
  }

  private func isCurrent(_ target: MacVirtualMachineRuntimeTarget) -> Bool {
    sessions[target.machineID]?.lease.target == target
  }

  private func idleState(after error: any Error) -> MacVirtualMachineRuntimeState {
    guard let runtimeError = error as? MacVirtualMachineRuntimeError else { return .stopped }
    if case .ownedElsewhere = runtimeError { return .ownedElsewhere }
    return .stopped
  }

  private func publish(
    machineID: UUID,
    target: MacVirtualMachineRuntimeTarget? = nil,
    state: MacVirtualMachineRuntimeState,
    errorMessage: String? = nil
  ) {
    let value = MacVirtualMachineRuntimeSnapshot(
      machineID: machineID,
      revision: (snapshots[machineID]?.revision ?? 0) + 1,
      target: target,
      state: state,
      errorMessage: errorMessage
    )
    snapshots[machineID] = value
    if let continuations = subscribers[machineID]?.values {
      for continuation in continuations {
        _ = continuation.yield(value)
      }
    }
  }

  private func removeSubscriber(_ subscriptionID: UUID, for machineID: UUID) {
    subscribers[machineID]?[subscriptionID] = nil
    if subscribers[machineID]?.isEmpty == true {
      subscribers[machineID] = nil
    }
  }
}

@MainActor
struct UnavailableMacVirtualMachineRuntimeService: MacVirtualMachineRuntimeManaging {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    MacVirtualMachineRuntimeSnapshot(machineID: machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot(for: machineID))
      continuation.finish()
    }
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? { nil }

  func start(id: UUID) async throws { throw MacVirtualMachineRuntimeError.unavailable }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }
}
