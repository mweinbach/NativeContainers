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
  var saveRestoreSupport: MacVirtualMachineSaveRestoreSupport { get }
  var canForceStop: Bool { get }
  var eventHandler: MacVirtualMachineRuntimeEventHandler? { get set }

  func start() async throws
  func saveState(to url: URL) async throws
  func restoreState(from url: URL) async throws
  func pause() async throws
  func resume() async throws
  func requestStop() throws
  func forceStop() async throws
  func close()
}

extension MacVirtualMachineRuntimeEngineSession {
  func close() {}
}

@MainActor
protocol MacVirtualMachineRuntimeManaging: Sendable {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot
  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot>
  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole?

  func refreshSavedState(id: UUID) async
  func start(id: UUID) async throws
  func startFresh(id: UUID) async throws
  func pause(target: MacVirtualMachineRuntimeTarget) async throws
  func resume(target: MacVirtualMachineRuntimeTarget) async throws
  func suspend(target: MacVirtualMachineRuntimeTarget) async throws
  func requestStop(target: MacVirtualMachineRuntimeTarget) throws
  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws
  func discardSavedState(id: UUID) async throws
}

@MainActor
final class MacVirtualMachineRuntimeService: MacVirtualMachineRuntimeManaging {
  private enum OperationKind: Equatable {
    case inspect
    case discard
    case start
    case restore
    case pause
    case resume
    case suspend
    case forceStop

  }

  private struct InFlightOperation {
    let token: UUID
    var target: MacVirtualMachineRuntimeTarget?
    var kind: OperationKind
    var forceStopRequested = false
    var forceStopTask: Task<Void, any Error>?
    var forceStopCompleted = false
    var terminalEvent: MacVirtualMachineRuntimeEvent?
  }

  private struct SessionRecord {
    let lease: MacVirtualMachineRuntimeLease
    let session: any MacVirtualMachineRuntimeEngineSession
  }

  private struct ShutdownFallback {
    let target: MacVirtualMachineRuntimeTarget
    let token: UUID
    let scheduledShutdown: MacVirtualMachineScheduledShutdown
  }

  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let engine: any MacVirtualMachineRuntimeEngine
  private let savedStateService: any MacVirtualMachineSavedStateManaging
  private let shutdownPolicy: MacVirtualMachineShutdownPolicy
  private let shutdownScheduler: any MacVirtualMachineShutdownScheduling
  private var sessions: [UUID: SessionRecord] = [:]
  private var operations: [UUID: InFlightOperation] = [:]
  private var shutdownFallbacks: [UUID: ShutdownFallback] = [:]
  private var snapshots: [UUID: MacVirtualMachineRuntimeSnapshot] = [:]
  private var subscribers:
    [UUID: [UUID: AsyncStream<MacVirtualMachineRuntimeSnapshot>.Continuation]] = [:]

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    engine: any MacVirtualMachineRuntimeEngine,
    savedStateService: any MacVirtualMachineSavedStateManaging,
    shutdownPolicy: MacVirtualMachineShutdownPolicy = .standard,
    shutdownScheduler: any MacVirtualMachineShutdownScheduling =
      ContinuousClockMacVirtualMachineShutdownScheduler()
  ) {
    self.leasingStore = leasingStore
    self.engine = engine
    self.savedStateService = savedStateService
    self.shutdownPolicy = shutdownPolicy
    self.shutdownScheduler = shutdownScheduler
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    snapshots[machineID]
      ?? MacVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        state: .inspectingSavedState
      )
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

  func refreshSavedState(id: UUID) async {
    guard sessions[id] == nil, operations[id] == nil else { return }
    let token = UUID()
    operations[id] = InFlightOperation(
      token: token,
      target: nil,
      kind: .inspect
    )
    publish(machineID: id, state: .inspectingSavedState)
    do {
      let lease = try await leasingStore.acquireMacOSRuntime(id: id)
      defer { lease.release() }
      let status = try await savedStateService.inspect(for: lease)
      guard sessions[id] == nil, isCurrentOperation(token, for: id) else {
        return
      }
      operations[id] = nil
      publish(
        machineID: id,
        state: .stopped,
        savedStateStatus: status
      )
    } catch {
      guard sessions[id] == nil, isCurrentOperation(token, for: id) else {
        return
      }
      operations[id] = nil
      publish(
        machineID: id,
        state: idleState(after: error),
        errorMessage: error.localizedDescription
      )
    }
  }

  func start(id: UUID) async throws {
    try await launch(id: id, discardingCheckpoint: false)
  }

  func startFresh(id: UUID) async throws {
    try await launch(id: id, discardingCheckpoint: true)
  }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    let (record, token) = try beginOperation(
      target: target,
      expected: .running,
      transition: .pausing,
      kind: .pause
    )
    do {
      try await record.session.pause()
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      operations[target.machineID] = nil
      publish(machineID: target.machineID, target: target, state: .paused)
    } catch {
      let operationError = error
      let forceStopped: Bool
      do {
        forceStopped = try await finishIfForceStopWasQueued(
          record: record,
          target: target,
          token: token
        )
      } catch {
        restoreAfterFailedOperation(
          target: target,
          token: token,
          state: .running,
          error: error
        )
        throw error
      }
      if forceStopped { throw operationError }
      restoreAfterFailedOperation(
        target: target,
        token: token,
        state: .running,
        error: operationError
      )
      throw operationError
    }
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    let (record, token) = try beginOperation(
      target: target,
      expected: .paused,
      transition: .resuming,
      kind: .resume
    )
    do {
      try await savedStateService.discardCheckpoint(for: record.lease)
      publish(
        machineID: target.machineID,
        target: target,
        state: .resuming,
        savedStateStatus: MacVirtualMachineSavedStateStatus.none
      )
      try await record.session.resume()
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      operations[target.machineID] = nil
      publish(machineID: target.machineID, target: target, state: .running)
    } catch {
      let operationError = error
      let forceStopped: Bool
      do {
        forceStopped = try await finishIfForceStopWasQueued(
          record: record,
          target: target,
          token: token
        )
      } catch {
        restoreAfterFailedOperation(
          target: target,
          token: token,
          state: .paused,
          error: error
        )
        throw error
      }
      if forceStopped { throw operationError }
      restoreAfterFailedOperation(
        target: target,
        token: token,
        state: .paused,
        error: operationError
      )
      throw operationError
    }
  }

  func suspend(target: MacVirtualMachineRuntimeTarget) async throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.state == .running || current.state == .paused,
      record.session.saveRestoreSupport.isSupported
    else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operations[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    let token = UUID()
    operations[target.machineID] = InFlightOperation(
      token: token,
      target: target,
      kind: .suspend
    )
    publish(machineID: target.machineID, target: target, state: .saving)

    var isPaused = current.state == .paused
    do {
      if current.state == .running {
        try await record.session.pause()
        isPaused = true
      }
      let summary = try await savedStateService.saveCheckpoint(
        session: record.session,
        lease: record.lease
      )
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      publish(
        machineID: target.machineID,
        target: target,
        state: .stopping,
        savedStateStatus: .available(summary),
        isForceStopQueued: operations[target.machineID]?.forceStopRequested == true
      )
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      try await record.session.forceStop()
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      finishSession(
        target,
        savedStateStatus: .available(summary)
      )
    } catch {
      let operationError = error
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        throw operationError
      }
      if finishDeferredTerminalEvent(target: target, token: token) {
        throw operationError
      }
      let forceStopped: Bool
      do {
        forceStopped = try await finishIfForceStopWasQueued(
          record: record,
          target: target,
          token: token
        )
      } catch {
        operations[target.machineID] = nil
        publish(
          machineID: target.machineID,
          target: target,
          state: isPaused ? .paused : current.state,
          errorMessage: error.localizedDescription
        )
        throw error
      }
      if forceStopped { throw operationError }
      operations[target.machineID] = nil
      publish(
        machineID: target.machineID,
        target: target,
        state: isPaused ? .paused : current.state,
        errorMessage: operationError.localizedDescription
      )
      throw operationError
    }
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canRequestStop else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operations[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    do {
      try record.session.requestStop()
      guard isCurrent(target) else { return }
      publish(machineID: target.machineID, target: target, state: .stopping)
      scheduleShutdownFallback(for: target)
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
    cancelShutdownFallback(for: target)

    if var operation = operations[target.machineID] {
      guard operation.target == target else {
        throw MacVirtualMachineRuntimeError.staleTarget(target)
      }
      guard operation.kind != .forceStop else {
        throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
      }
      operation.forceStopRequested = true
      if operation.forceStopTask == nil {
        operation.forceStopTask = makeForceStopTask(for: record.session)
      }
      let task = operation.forceStopTask!
      operations[target.machineID] = operation
      publish(
        machineID: target.machineID,
        target: target,
        state: current.state,
        isForceStopQueued: true
      )
      do {
        try await task.value
      } catch {
        guard isCurrent(target) else { return }
        clearFailedQueuedForceStop(
          target: target,
          token: operation.token,
          error: error
        )
        throw error
      }
      guard var currentOperation = operations[target.machineID],
        currentOperation.token == operation.token,
        isCurrent(target)
      else {
        return
      }
      currentOperation.forceStopCompleted = true
      operations[target.machineID] = currentOperation
      publish(
        machineID: target.machineID,
        target: target,
        state: .stopping,
        isForceStopQueued: true,
        isForceStopCompleteAwaitingCleanup: true
      )
      return
    }

    let token = UUID()
    var operation = InFlightOperation(
      token: token,
      target: target,
      kind: .forceStop
    )
    operation.forceStopRequested = true
    operation.forceStopTask = makeForceStopTask(for: record.session)
    operations[target.machineID] = operation
    publish(
      machineID: target.machineID,
      target: target,
      state: .stopping,
      isForceStopQueued: true
    )
    do {
      try await operation.forceStopTask!.value
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      finishSession(target)
    } catch {
      restoreAfterFailedOperation(
        target: target,
        token: token,
        state: current.state,
        error: error
      )
      throw error
    }
  }

  func discardSavedState(id: UUID) async throws {
    guard sessions[id] == nil, operations[id] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(id)
    }
    let token = UUID()
    operations[id] = InFlightOperation(
      token: token,
      target: nil,
      kind: .discard
    )
    publish(machineID: id, state: .discardingSavedState)
    do {
      let lease = try await leasingStore.acquireMacOSRuntime(id: id)
      defer { lease.release() }
      try await savedStateService.discardCheckpoint(for: lease)
      guard sessions[id] == nil, isCurrentOperation(token, for: id) else {
        return
      }
      operations[id] = nil
      publish(
        machineID: id,
        state: .stopped,
        savedStateStatus: MacVirtualMachineSavedStateStatus.none
      )
    } catch {
      guard sessions[id] == nil, isCurrentOperation(token, for: id) else {
        throw error
      }
      operations[id] = nil
      publish(
        machineID: id,
        state: .stopped,
        errorMessage: error.localizedDescription
      )
      throw error
    }
  }

  private func launch(id: UUID, discardingCheckpoint: Bool) async throws {
    guard sessions[id] == nil else {
      throw MacVirtualMachineRuntimeError.duplicateSession(id)
    }
    guard operations[id] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(id)
    }

    let token = UUID()
    operations[id] = InFlightOperation(token: token, target: nil, kind: .start)
    publish(machineID: id, state: .starting)
    var pendingLease: MacVirtualMachineRuntimeLease?

    do {
      let lease = try await leasingStore.acquireMacOSRuntime(id: id)
      pendingLease = lease
      guard isCurrentOperation(token, for: id), sessions[id] == nil else {
        throw MacVirtualMachineRuntimeError.operationInProgress(id)
      }

      if discardingCheckpoint {
        try await savedStateService.discardCheckpoint(for: lease)
      }
      let savedStateStatus = try await savedStateService.inspect(for: lease)
      if case .incompatible(let reason) = savedStateStatus {
        throw MacVirtualMachineSavedStateError.incompatible(id, reason)
      }

      let session = try engine.makeSession(for: lease.machine, target: lease.target)
      if case .available = savedStateStatus,
        case .unsupported(let reason) = session.saveRestoreSupport
      {
        throw MacVirtualMachineSavedStateError.incompatible(id, reason)
      }
      session.eventHandler = { [weak self] event in
        self?.receive(event, from: lease.target)
      }
      sessions[id] = SessionRecord(lease: lease, session: session)
      pendingLease = nil

      var operation = operations[id]!
      operation.target = lease.target
      operation.kind = savedStateStatus.summary == nil ? .start : .restore
      operations[id] = operation
      publish(
        machineID: id,
        target: lease.target,
        state: savedStateStatus.summary == nil ? .starting : .restoring,
        savedStateStatus: savedStateStatus,
        saveRestoreSupport: session.saveRestoreSupport
      )

      if savedStateStatus.summary != nil {
        try await restoreAndResume(
          record: sessions[id]!,
          token: token
        )
      } else {
        try await startCold(record: sessions[id]!, token: token)
      }
    } catch {
      pendingLease?.release()
      if sessions[id] == nil, isCurrentOperation(token, for: id) {
        operations[id] = nil
        let status: MacVirtualMachineSavedStateStatus?
        if case MacVirtualMachineSavedStateError.incompatible(_, let reason) = error {
          status = .incompatible(reason)
        } else {
          status = nil
        }
        publish(
          machineID: id,
          state: idleState(after: error),
          savedStateStatus: status,
          errorMessage: error.localizedDescription
        )
      }
      throw error
    }
  }

  private func startCold(record: SessionRecord, token: UUID) async throws {
    let target = record.lease.target
    do {
      try await record.session.start()
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      operations[target.machineID] = nil
      publish(
        machineID: target.machineID,
        target: target,
        state: .running,
        savedStateStatus: MacVirtualMachineSavedStateStatus.none
      )
    } catch {
      let operationError = error
      let forceStopped: Bool
      do {
        forceStopped = try await finishIfForceStopWasQueued(
          record: record,
          target: target,
          token: token
        )
      } catch {
        finishFailedLaunch(target: target, token: token, error: error)
        throw error
      }
      if !forceStopped {
        finishFailedLaunch(target: target, token: token, error: operationError)
      }
      throw operationError
    }
  }

  private func restoreAndResume(record: SessionRecord, token: UUID) async throws {
    let target = record.lease.target
    do {
      _ = try await savedStateService.restoreCheckpoint(
        session: record.session,
        lease: record.lease
      )
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      publish(
        machineID: target.machineID,
        target: target,
        state: .resuming,
        savedStateStatus: MacVirtualMachineSavedStateStatus.none
      )
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      try await record.session.resume()
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return
      }
      if finishDeferredTerminalEvent(target: target, token: token) { return }
      operations[target.machineID] = nil
      publish(
        machineID: target.machineID,
        target: target,
        state: .running,
        savedStateStatus: MacVirtualMachineSavedStateStatus.none
      )
    } catch {
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        throw error
      }
      if snapshot(for: target.machineID).savedStateStatus == .none {
        let operationError = error
        let forceStopped: Bool
        do {
          forceStopped = try await finishIfForceStopWasQueued(
            record: record,
            target: target,
            token: token
          )
        } catch {
          operations[target.machineID] = nil
          publish(
            machineID: target.machineID,
            target: target,
            state: .paused,
            savedStateStatus: MacVirtualMachineSavedStateStatus.none,
            errorMessage: error.localizedDescription
          )
          throw error
        }
        if !forceStopped {
          operations[target.machineID] = nil
          publish(
            machineID: target.machineID,
            target: target,
            state: .paused,
            savedStateStatus: MacVirtualMachineSavedStateStatus.none,
            errorMessage: operationError.localizedDescription
          )
        }
        throw operationError
      } else {
        let status =
          (try? await savedStateService.inspect(for: record.lease)) ?? .unknown
        if finishDeferredTerminalEvent(target: target, token: token) {
          throw error
        }
        finishSession(
          target,
          savedStateStatus: status,
          errorMessage: error.localizedDescription
        )
      }
      throw error
    }
  }

  private func beginOperation(
    target: MacVirtualMachineRuntimeTarget,
    expected: MacVirtualMachineRuntimeState,
    transition: MacVirtualMachineRuntimeState,
    kind: OperationKind
  ) throws -> (SessionRecord, UUID) {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.state == expected else {
      throw MacVirtualMachineRuntimeError.invalidState(target.machineID, current.state)
    }
    guard operations[target.machineID] == nil else {
      throw MacVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }
    let token = UUID()
    operations[target.machineID] = InFlightOperation(
      token: token,
      target: target,
      kind: kind
    )
    publish(machineID: target.machineID, target: target, state: transition)
    return (record, token)
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

  private func finishIfForceStopWasQueued(
    record: SessionRecord,
    target: MacVirtualMachineRuntimeTarget,
    token: UUID
  ) async throws -> Bool {
    guard var operation = operations[target.machineID],
      operation.token == token,
      operation.forceStopRequested
    else {
      return false
    }
    if let event = operation.terminalEvent {
      finishSession(target, errorMessage: event.errorMessage)
      return true
    }
    if operation.forceStopTask == nil {
      operation.forceStopTask = makeForceStopTask(for: record.session)
      operations[target.machineID] = operation
    }
    try await operation.forceStopTask!.value
    guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
      return true
    }
    finishSession(target)
    return true
  }

  private func makeForceStopTask(
    for session: any MacVirtualMachineRuntimeEngineSession
  ) -> Task<Void, any Error> {
    Task { @MainActor in
      while !session.canForceStop {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(100))
      }
      try await session.forceStop()
    }
  }

  private func scheduleShutdownFallback(
    for target: MacVirtualMachineRuntimeTarget
  ) {
    cancelShutdownFallback(machineID: target.machineID)
    let token = UUID()
    let scheduledShutdown = shutdownScheduler.schedule(
      after: shutdownPolicy.gracefulStopTimeout
    ) { [weak self] in
      await self?.performAutomaticForceStop(target: target, token: token)
    }
    shutdownFallbacks[target.machineID] = ShutdownFallback(
      target: target,
      token: token,
      scheduledShutdown: scheduledShutdown
    )
  }

  private func performAutomaticForceStop(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID
  ) async {
    guard let fallback = shutdownFallbacks[target.machineID],
      fallback.target == target,
      fallback.token == token,
      isCurrent(target),
      snapshot(for: target.machineID).state == .stopping
    else {
      return
    }
    shutdownFallbacks[target.machineID] = nil
    do {
      try await forceStop(target: target)
    } catch {
      // forceStop publishes the failure while preserving the live session so a
      // user can retry explicitly. Automatic shutdown never loops.
    }
  }

  private func cancelShutdownFallback(
    for target: MacVirtualMachineRuntimeTarget
  ) {
    guard shutdownFallbacks[target.machineID]?.target == target else { return }
    cancelShutdownFallback(machineID: target.machineID)
  }

  private func cancelShutdownFallback(machineID: UUID) {
    shutdownFallbacks.removeValue(forKey: machineID)?.scheduledShutdown.cancel()
  }

  private func clearFailedQueuedForceStop(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID,
    error: any Error
  ) {
    guard var operation = operations[target.machineID], operation.token == token else {
      return
    }
    operation.forceStopTask = nil
    operation.forceStopRequested = false
    operation.forceStopCompleted = false
    operations[target.machineID] = operation
    let current = snapshot(for: target.machineID)
    publish(
      machineID: target.machineID,
      target: target,
      state: current.state,
      errorMessage: error.localizedDescription
    )
  }

  private func restoreAfterFailedOperation(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID,
    state: MacVirtualMachineRuntimeState,
    error: any Error
  ) {
    guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
      return
    }
    if finishDeferredTerminalEvent(target: target, token: token) { return }
    operations[target.machineID] = nil
    publish(
      machineID: target.machineID,
      target: target,
      state: state,
      errorMessage: error.localizedDescription
    )
  }

  private func finishFailedLaunch(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID,
    error: any Error
  ) {
    guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
      return
    }
    if finishDeferredTerminalEvent(target: target, token: token) { return }
    finishSession(target, errorMessage: error.localizedDescription)
  }

  private func receive(
    _ event: MacVirtualMachineRuntimeEvent,
    from target: MacVirtualMachineRuntimeTarget
  ) {
    guard isCurrent(target) else { return }
    if var operation = operations[target.machineID], operation.target == target {
      if operation.terminalEvent == nil {
        operation.terminalEvent = event
        operations[target.machineID] = operation
      }
      return
    }
    finishSession(target, errorMessage: event.errorMessage)
  }

  @discardableResult
  private func finishDeferredTerminalEvent(
    target: MacVirtualMachineRuntimeTarget,
    token: UUID
  ) -> Bool {
    guard let operation = operations[target.machineID],
      operation.token == token,
      let event = operation.terminalEvent
    else {
      return false
    }
    finishSession(target, errorMessage: event.errorMessage)
    return true
  }

  private func finishSession(
    _ target: MacVirtualMachineRuntimeTarget,
    savedStateStatus: MacVirtualMachineSavedStateStatus? = nil,
    errorMessage: String? = nil
  ) {
    guard let record = sessions[target.machineID], record.lease.target == target else {
      return
    }
    cancelShutdownFallback(for: target)
    sessions[target.machineID] = nil
    operations[target.machineID]?.forceStopTask?.cancel()
    operations[target.machineID] = nil
    record.session.eventHandler = nil
    record.session.close()
    record.lease.release()
    publish(
      machineID: target.machineID,
      state: .stopped,
      savedStateStatus: savedStateStatus,
      errorMessage: errorMessage
    )
  }

  private func isCurrent(_ target: MacVirtualMachineRuntimeTarget) -> Bool {
    sessions[target.machineID]?.lease.target == target
  }

  private func isCurrentOperation(_ token: UUID, for machineID: UUID) -> Bool {
    operations[machineID]?.token == token
  }

  private func idleState(after error: any Error) -> MacVirtualMachineRuntimeState {
    guard let runtimeError = error as? MacVirtualMachineRuntimeError else {
      return .stopped
    }
    if case .ownedElsewhere = runtimeError { return .ownedElsewhere }
    return .stopped
  }

  private func publish(
    machineID: UUID,
    target: MacVirtualMachineRuntimeTarget? = nil,
    state: MacVirtualMachineRuntimeState,
    savedStateStatus: MacVirtualMachineSavedStateStatus? = nil,
    saveRestoreSupport: MacVirtualMachineSaveRestoreSupport? = nil,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    let current = snapshot(for: machineID)
    let value = MacVirtualMachineRuntimeSnapshot(
      machineID: machineID,
      revision: current.revision + 1,
      target: target,
      state: state,
      savedStateStatus: savedStateStatus ?? current.savedStateStatus,
      saveRestoreSupport: saveRestoreSupport ?? current.saveRestoreSupport,
      isForceStopQueued: isForceStopQueued,
      isForceStopCompleteAwaitingCleanup:
        isForceStopCompleteAwaitingCleanup,
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

extension MacVirtualMachineRuntimeEvent {
  fileprivate var errorMessage: String? {
    switch self {
    case .guestStopped:
      nil
    case .stoppedWithError(let message):
      message
    }
  }
}

@MainActor
struct UnavailableMacVirtualMachineRuntimeService: MacVirtualMachineRuntimeManaging {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    MacVirtualMachineRuntimeSnapshot(
      machineID: machineID,
      savedStateStatus: .none
    )
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot(for: machineID))
      continuation.finish()
    }
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? { nil }
  func refreshSavedState(id: UUID) async {}
  func start(id: UUID) async throws { throw MacVirtualMachineRuntimeError.unavailable }
  func startFresh(id: UUID) async throws { throw MacVirtualMachineRuntimeError.unavailable }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func suspend(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func discardSavedState(id: UUID) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }
}
