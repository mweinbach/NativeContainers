import Foundation

@MainActor
final class LinuxVirtualMachineRuntimeService: LinuxVirtualMachineRuntimeManaging {
  private enum OperationKind: Equatable {
    case start
    case pause
    case resume
    case ejectInstallationMedia
    case forceStop
  }

  private struct InFlightOperation {
    let token: UUID
    var target: LinuxVirtualMachineRuntimeTarget?
    let kind: OperationKind
    var forceStopRequested = false
    var forceStopTask: Task<Void, any Error>?
    var forceStopCompleted = false
    var terminalEvent: LinuxVirtualMachineRuntimeEvent?
  }

  private struct SessionRecord {
    let lease: LinuxVirtualMachineRuntimeLease
    let session: any LinuxVirtualMachineRuntimeEngineSession
  }

  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let installationStore: any LinuxVirtualMachineInstallationCompleting
  private let engine: any LinuxVirtualMachineRuntimeEngine
  private let shutdownPolicy: VirtualMachineShutdownPolicy
  private let observations = LinuxVirtualMachineRuntimeObservations()
  private let shutdownFallbacks: VirtualMachineShutdownFallbackRegistry
  private var sessions: [UUID: SessionRecord] = [:]
  private var operations: [UUID: InFlightOperation] = [:]

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    installationStore: any LinuxVirtualMachineInstallationCompleting,
    engine: any LinuxVirtualMachineRuntimeEngine,
    shutdownPolicy: VirtualMachineShutdownPolicy = .standard,
    shutdownScheduler: any VirtualMachineShutdownScheduling =
      ContinuousClockVirtualMachineShutdownScheduler()
  ) {
    self.leasingStore = leasingStore
    self.installationStore = installationStore
    self.engine = engine
    self.shutdownPolicy = shutdownPolicy
    shutdownFallbacks = VirtualMachineShutdownFallbackRegistry(
      timeout: shutdownPolicy.gracefulStopTimeout,
      scheduler: shutdownScheduler
    )
  }

  func snapshot(for machineID: UUID) -> LinuxVirtualMachineRuntimeSnapshot {
    observations.snapshot(for: machineID)
  }

  func updates(
    for machineID: UUID
  ) -> AsyncStream<LinuxVirtualMachineRuntimeSnapshot> {
    observations.updates(for: machineID)
  }

  func console(
    for target: LinuxVirtualMachineRuntimeTarget
  ) -> LinuxVirtualMachineConsole? {
    guard let record = sessions[target.machineID], record.lease.target == target else {
      return nil
    }
    return record.session.console
  }

  func start(id: UUID) async throws {
    guard sessions[id] == nil else {
      throw LinuxVirtualMachineRuntimeError.duplicateSession(id)
    }
    guard operations[id] == nil else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(id)
    }

    let token = UUID()
    operations[id] = InFlightOperation(
      token: token,
      target: nil,
      kind: .start
    )
    publish(machineID: id, state: .starting)
    var pendingLease: LinuxVirtualMachineRuntimeLease?

    do {
      let lease = try await leasingStore.acquireLinuxRuntime(id: id)
      pendingLease = lease
      guard isCurrentOperation(token, for: id), sessions[id] == nil else {
        throw LinuxVirtualMachineRuntimeError.operationInProgress(id)
      }

      let session = try engine.makeSession(
        for: lease.machine,
        target: lease.target
      )
      session.eventHandler = { [weak self] event in
        self?.receive(event, from: lease.target)
      }
      sessions[id] = SessionRecord(lease: lease, session: session)
      pendingLease = nil

      var operation = try requireOperation(token: token, machineID: id)
      operation.target = lease.target
      operations[id] = operation
      publish(
        machineID: id,
        target: lease.target,
        state: .starting,
        hasInstallationMedia: session.hasInstallationMedia
      )

      try await session.start()
      guard isCurrent(lease.target), isCurrentOperation(token, for: id) else {
        return
      }
      if try await finishIfForceStopWasQueued(
        record: sessions[id]!,
        target: lease.target,
        token: token
      ) {
        return
      }
      if finishDeferredTerminalEvent(target: lease.target, token: token) {
        return
      }
      operations[id] = nil
      publish(
        machineID: id,
        target: lease.target,
        state: .running,
        hasInstallationMedia: session.hasInstallationMedia
      )
    } catch {
      let operationError = error
      pendingLease?.release()
      guard isCurrentOperation(token, for: id) else {
        throw operationError
      }
      if let record = sessions[id], let target = operations[id]?.target {
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
          finishFailedLaunch(
            target: target,
            token: token,
            error: operationError
          )
        }
      } else {
        operations[id] = nil
        publish(
          machineID: id,
          state: idleState(after: operationError),
          errorMessage: operationError.localizedDescription
        )
      }
      throw operationError
    }
  }

  func pause(target: LinuxVirtualMachineRuntimeTarget) async throws {
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
      publish(
        machineID: target.machineID,
        target: target,
        state: .paused,
        hasInstallationMedia: record.session.hasInstallationMedia
      )
    } catch {
      try await recover(
        record: record,
        target: target,
        token: token,
        state: .running,
        operationError: error
      )
    }
  }

  func resume(target: LinuxVirtualMachineRuntimeTarget) async throws {
    let (record, token) = try beginOperation(
      target: target,
      expected: .paused,
      transition: .resuming,
      kind: .resume
    )
    do {
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
        hasInstallationMedia: record.session.hasInstallationMedia
      )
    } catch {
      try await recover(
        record: record,
        target: target,
        token: token,
        state: .paused,
        operationError: error
      )
    }
  }

  func ejectInstallationMedia(
    target: LinuxVirtualMachineRuntimeTarget
  ) async throws -> VirtualMachineManifest {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canEjectInstallationMedia else {
      throw LinuxVirtualMachineRuntimeError.invalidState(
        target.machineID,
        current.state
      )
    }
    guard operations[target.machineID] == nil else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    let token = UUID()
    operations[target.machineID] = InFlightOperation(
      token: token,
      target: target,
      kind: .ejectInstallationMedia
    )
    publish(
      machineID: target.machineID,
      target: target,
      state: .ejectingInstallationMedia,
      hasInstallationMedia: true
    )

    do {
      if record.session.hasInstallationMedia {
        try await record.session.ejectInstallationMedia()
      }
      let manifest = try await installationStore.completeLinuxInstallation(
        lease: record.lease
      )
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return manifest
      }
      if try await finishIfForceStopWasQueued(
        record: record,
        target: target,
        token: token
      ) {
        return manifest
      }
      if finishDeferredTerminalEvent(target: target, token: token) {
        return manifest
      }
      operations[target.machineID] = nil
      publish(
        machineID: target.machineID,
        target: target,
        state: current.state,
        hasInstallationMedia: false
      )
      return manifest
    } catch {
      try await recover(
        record: record,
        target: target,
        token: token,
        state: current.state,
        hasInstallationMedia: true,
        operationError: error
      )
    }
  }

  func requestStop(target: LinuxVirtualMachineRuntimeTarget) throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canRequestStop else {
      throw LinuxVirtualMachineRuntimeError.invalidState(
        target.machineID,
        current.state
      )
    }
    guard operations[target.machineID] == nil else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }

    do {
      try record.session.requestStop()
      guard isCurrent(target) else { return }
      publish(
        machineID: target.machineID,
        target: target,
        state: .stopping,
        hasInstallationMedia: current.hasInstallationMedia
      )
      scheduleShutdownFallback(for: target)
    } catch {
      publish(
        machineID: target.machineID,
        target: target,
        state: current.state,
        hasInstallationMedia: current.hasInstallationMedia,
        errorMessage: error.localizedDescription
      )
      throw error
    }
  }

  func forceStop(target: LinuxVirtualMachineRuntimeTarget) async throws {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.canForceStop else {
      throw LinuxVirtualMachineRuntimeError.invalidState(
        target.machineID,
        current.state
      )
    }
    cancelShutdownFallback(for: target)

    if var operation = operations[target.machineID] {
      guard operation.target == target else {
        throw LinuxVirtualMachineRuntimeError.staleTarget(target)
      }
      guard operation.kind != .forceStop else {
        throw LinuxVirtualMachineRuntimeError.operationInProgress(target.machineID)
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
        hasInstallationMedia: current.hasInstallationMedia,
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
        hasInstallationMedia: current.hasInstallationMedia,
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
      hasInstallationMedia: current.hasInstallationMedia,
      isForceStopQueued: true
    )
    do {
      try await operation.forceStopTask!.value
      guard isCurrent(target), isCurrentOperation(token, for: target.machineID) else {
        return
      }
      finishSession(target)
    } catch {
      guard isCurrent(target) else { return }
      restoreAfterFailedOperation(
        target: target,
        token: token,
        state: current.state,
        hasInstallationMedia: current.hasInstallationMedia,
        error: error
      )
      throw error
    }
  }

  private func beginOperation(
    target: LinuxVirtualMachineRuntimeTarget,
    expected: LinuxVirtualMachineRuntimeState,
    transition: LinuxVirtualMachineRuntimeState,
    kind: OperationKind
  ) throws -> (SessionRecord, UUID) {
    let record = try currentRecord(for: target)
    let current = snapshot(for: target.machineID)
    guard current.state == expected else {
      throw LinuxVirtualMachineRuntimeError.invalidState(
        target.machineID,
        current.state
      )
    }
    guard operations[target.machineID] == nil else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }
    let token = UUID()
    operations[target.machineID] = InFlightOperation(
      token: token,
      target: target,
      kind: kind
    )
    publish(
      machineID: target.machineID,
      target: target,
      state: transition,
      hasInstallationMedia: current.hasInstallationMedia
    )
    return (record, token)
  }

  private func currentRecord(
    for target: LinuxVirtualMachineRuntimeTarget
  ) throws -> SessionRecord {
    guard let record = sessions[target.machineID] else {
      throw LinuxVirtualMachineRuntimeError.noActiveSession(target.machineID)
    }
    guard record.lease.target == target else {
      throw LinuxVirtualMachineRuntimeError.staleTarget(target)
    }
    return record
  }

  private func requireOperation(
    token: UUID,
    machineID: UUID
  ) throws -> InFlightOperation {
    guard let operation = operations[machineID], operation.token == token else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(machineID)
    }
    return operation
  }

  private func recover(
    record: SessionRecord,
    target: LinuxVirtualMachineRuntimeTarget,
    token: UUID,
    state: LinuxVirtualMachineRuntimeState,
    hasInstallationMedia: Bool? = nil,
    operationError: any Error
  ) async throws -> Never {
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
        state: state,
        hasInstallationMedia: hasInstallationMedia,
        error: error
      )
      throw error
    }
    if !forceStopped {
      restoreAfterFailedOperation(
        target: target,
        token: token,
        state: state,
        hasInstallationMedia: hasInstallationMedia,
        error: operationError
      )
    }
    throw operationError
  }

  private func finishIfForceStopWasQueued(
    record: SessionRecord,
    target: LinuxVirtualMachineRuntimeTarget,
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
    for session: any LinuxVirtualMachineRuntimeEngineSession
  ) -> Task<Void, any Error> {
    let capabilityTimeout = shutdownPolicy.forceStopCapabilityTimeout
    let pollInterval = shutdownPolicy.forceStopPollInterval
    return Task { @MainActor in
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: capabilityTimeout)
      while !session.canForceStop {
        try Task.checkCancellation()
        guard clock.now < deadline else {
          throw LinuxVirtualMachineRuntimeError.operationUnavailable(
            "force stop before Virtualization.framework’s capability window closed"
          )
        }
        try await clock.sleep(for: pollInterval)
      }
      try await session.forceStop()
    }
  }

  private func scheduleShutdownFallback(
    for target: LinuxVirtualMachineRuntimeTarget
  ) {
    shutdownFallbacks.schedule(for: target) { [weak self] token in
      await self?.performAutomaticForceStop(target: target, token: token)
    }
  }

  private func performAutomaticForceStop(
    target: LinuxVirtualMachineRuntimeTarget,
    token: UUID
  ) async {
    guard shutdownFallbacks.isScheduled(for: target, token: token),
      isCurrent(target),
      snapshot(for: target.machineID).state == .stopping
    else {
      return
    }
    shutdownFallbacks.consume(target: target, token: token)
    do {
      try await forceStop(target: target)
    } catch {
      // The failure is published while the live generation stays owned, which
      // leaves explicit Force Stop available for a bounded retry.
    }
  }

  private func cancelShutdownFallback(
    for target: LinuxVirtualMachineRuntimeTarget
  ) {
    shutdownFallbacks.cancel(for: target)
  }

  private func clearFailedQueuedForceStop(
    target: LinuxVirtualMachineRuntimeTarget,
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
      hasInstallationMedia: current.hasInstallationMedia,
      errorMessage: error.localizedDescription
    )
  }

  private func restoreAfterFailedOperation(
    target: LinuxVirtualMachineRuntimeTarget,
    token: UUID,
    state: LinuxVirtualMachineRuntimeState,
    hasInstallationMedia: Bool? = nil,
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
      hasInstallationMedia: hasInstallationMedia,
      errorMessage: error.localizedDescription
    )
  }

  private func finishFailedLaunch(
    target: LinuxVirtualMachineRuntimeTarget,
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
    _ event: LinuxVirtualMachineRuntimeEvent,
    from target: LinuxVirtualMachineRuntimeTarget
  ) {
    guard isCurrent(target) else { return }
    if var operation = operations[target.machineID], operation.target == target {
      if operation.kind == .forceStop {
        finishSession(target, errorMessage: event.errorMessage)
        return
      }
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
    target: LinuxVirtualMachineRuntimeTarget,
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
    _ target: LinuxVirtualMachineRuntimeTarget,
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
      hasInstallationMedia: snapshot(
        for: target.machineID
      ).hasInstallationMedia,
      errorMessage: errorMessage
    )
  }

  private func isCurrent(_ target: LinuxVirtualMachineRuntimeTarget) -> Bool {
    sessions[target.machineID]?.lease.target == target
  }

  private func isCurrentOperation(_ token: UUID, for machineID: UUID) -> Bool {
    operations[machineID]?.token == token
  }

  private func idleState(
    after error: any Error
  ) -> LinuxVirtualMachineRuntimeState {
    guard let runtimeError = error as? LinuxVirtualMachineRuntimeError else {
      return .stopped
    }
    if case .ownedElsewhere = runtimeError { return .ownedElsewhere }
    return .stopped
  }

  private func publish(
    machineID: UUID,
    target: LinuxVirtualMachineRuntimeTarget? = nil,
    state: LinuxVirtualMachineRuntimeState,
    hasInstallationMedia: Bool? = nil,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    observations.publish(
      machineID: machineID,
      target: target,
      state: state,
      hasInstallationMedia: hasInstallationMedia,
      isForceStopQueued: isForceStopQueued,
      isForceStopCompleteAwaitingCleanup:
        isForceStopCompleteAwaitingCleanup,
      errorMessage: errorMessage
    )
  }
}
