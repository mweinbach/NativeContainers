import Foundation

actor AppleMachineManagementService: MachineManaging {
  private static let provisioningTimeoutSeconds = 30
  private static let statePollAttempts = 25

  private enum CreationReconciliation {
    case absent
    case present
    case unknown
  }

  private let runtime: any LinuxMachineRuntime
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    runtime: any LinuxMachineRuntime = AppleMachineRuntimeClient(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.runtime = runtime
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
    self.sleep = sleep
  }

  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    try await runtimeMutationCoordinator.perform {
      try await self.createMachineWhileLocked(request: request, progress: progress)
    }
  }

  func startMachine(_ target: LinuxMachineIdentity) async throws {
    try await runtimeMutationCoordinator.perform {
      let current = try await self.requireCurrent(target)
      if current.state.isRunning, current.isInitialized {
        return
      }

      var recoveryIsAuthorized = current.state.isRunning && !current.isInitialized
      do {
        let running: LinuxMachineRuntimeSnapshot
        if current.state.isRunning {
          running = current
        } else {
          do {
            running = try await self.runtime.boot(id: target.id)
            try self.validate(running, matches: target)
            recoveryIsAuthorized = true
          } catch {
            if let reconciled = try? await self.runtime.snapshot(id: target.id),
              reconciled.identity == target,
              reconciled.state.isRunning
            {
              recoveryIsAuthorized = true
            }
            throw error
          }
        }

        if !running.isInitialized {
          recoveryIsAuthorized = true
          try await self.runtime.provisionUser(
            id: target.id,
            timeoutSeconds: Self.provisioningTimeoutSeconds
          )
        }

        let ready = try await self.requireCurrent(target)
        guard ready.state.isRunning, ready.isInitialized else {
          throw LinuxMachineManagementError.initializationNotConfirmed(target.id)
        }
      } catch {
        guard recoveryIsAuthorized else {
          throw error
        }
        let recovery = await self.recoverMachineIgnoringCancellation(target)
        if case .failed(let recoveryMessage) = recovery {
          throw LinuxMachineManagementError.startRecoveryFailed(
            id: target.id,
            operation: error.localizedDescription,
            recovery: recoveryMessage
          )
        }
        throw error
      }
    }
  }

  func stopMachine(_ target: LinuxMachineIdentity) async throws {
    try await runtimeMutationCoordinator.perform {
      let current = try await self.requireCurrent(target)
      guard current.state != .stopped else { return }

      do {
        try await self.runtime.stop(id: target.id)
      } catch {
        let operationError = error
        do {
          _ = try await self.waitUntilStopped(target)
          return
        } catch LinuxMachineManagementError.staleTarget {
          throw LinuxMachineManagementError.staleTarget(target.id)
        } catch {
          throw operationError
        }
      }
      _ = try await self.waitUntilStopped(target)
    }
  }

  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws {
    try await runtimeMutationCoordinator.perform {
      guard authorization.allowsKill, authorization.target == target else {
        throw LinuxMachineManagementError.forceStopNotAuthorized(target.id)
      }
      try self.requireStableIdentity(target)
      let current = try await self.requireCurrent(target)
      guard current.state != .stopped else { return }
      guard current.state == .running || current.state == .stopping else {
        throw LinuxMachineManagementError.notRunning(target.id)
      }
      guard let backingContainerID = current.backingContainerID else {
        throw LinuxMachineManagementError.backingContainerMissing(target.id)
      }

      do {
        try await self.runtime.forceStop(backingContainerID: backingContainerID)
      } catch {
        let operationError = error
        do {
          _ = try await self.waitUntilStopped(target, afterForce: true)
          return
        } catch LinuxMachineManagementError.staleTarget {
          throw LinuxMachineManagementError.staleTarget(target.id)
        } catch {
          throw operationError
        }
      }
      _ = try await self.waitUntilStopped(target, afterForce: true)
    }
  }

  func deleteMachine(_ target: LinuxMachineIdentity) async throws {
    try await runtimeMutationCoordinator.perform {
      try self.requireStableIdentity(target)
      let current = try await self.requireCurrent(target)
      guard current.state == .stopped else {
        throw LinuxMachineManagementError.stopBeforeDeleting(target.id)
      }

      do {
        try await self.runtime.delete(target)
      } catch {
        let operationError = error
        do {
          guard let remaining = try await self.runtime.snapshot(id: target.id) else {
            return
          }
          try self.validate(remaining, matches: target)
        } catch LinuxMachineManagementError.staleTarget {
          throw LinuxMachineManagementError.staleTarget(target.id)
        } catch {
          throw operationError
        }
        throw operationError
      }

      for attempt in 0..<Self.statePollAttempts {
        guard let remaining = try await self.runtime.snapshot(id: target.id) else {
          return
        }
        try self.validate(remaining, matches: target)
        if attempt + 1 < Self.statePollAttempts {
          try await self.sleep(.milliseconds(200))
        }
      }
      throw LinuxMachineManagementError.deletionNotConfirmed(target.id)
    }
  }

  private func createMachineWhileLocked(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    guard try await runtime.snapshot(id: request.name) == nil else {
      throw LinuxMachineManagementError.alreadyExists(request.name)
    }

    var creationAttempted = false
    var created: LinuxMachineRuntimeSnapshot?
    do {
      creationAttempted = true
      let createdSnapshot = try await runtime.create(request: request, progress: progress)
      created = createdSnapshot

      guard request.startAfterCreation else {
        let result = Self.result(from: createdSnapshot)
        await progress(
          ContainerOperationProgress(phase: .completed, message: "Linux machine created")
        )
        return result
      }

      try Task.checkCancellation()
      await progress(
        ContainerOperationProgress(phase: .starting, message: "Starting Linux machine")
      )
      let running = try await runtime.boot(id: request.name)
      try validate(running, matches: createdSnapshot.identity)

      if !running.isInitialized {
        await progress(
          ContainerOperationProgress(
            phase: .starting,
            message: "Configuring the host user inside the machine"
          )
        )
        try await runtime.provisionUser(
          id: request.name,
          timeoutSeconds: Self.provisioningTimeoutSeconds
        )
      }

      let ready = try await requireCurrent(createdSnapshot.identity)
      guard ready.state.isRunning, ready.isInitialized else {
        throw LinuxMachineManagementError.initializationNotConfirmed(request.name)
      }
      await progress(
        ContainerOperationProgress(phase: .completed, message: "Linux machine ready")
      )
      return Self.result(from: ready)
    } catch {
      guard let created else {
        if creationAttempted {
          switch await reconcileCreationIgnoringCancellation(id: request.name) {
          case .absent:
            break
          case .present, .unknown:
            throw LinuxMachineManagementError.creationOutcomeUnknown(request.name)
          }
        }
        throw error
      }

      let recovery = await recoverMachineIgnoringCancellation(created.identity)
      throw LinuxMachinePartialCompletionError(
        result: Self.result(from: created),
        operationMessage: error.localizedDescription,
        recovery: recovery
      )
    }
  }

  private func requireCurrent(
    _ target: LinuxMachineIdentity
  ) async throws -> LinuxMachineRuntimeSnapshot {
    guard let current = try await runtime.snapshot(id: target.id) else {
      throw LinuxMachineManagementError.missing(target.id)
    }
    try validate(current, matches: target)
    return current
  }

  nonisolated private func validate(
    _ snapshot: LinuxMachineRuntimeSnapshot,
    matches target: LinuxMachineIdentity
  ) throws {
    guard snapshot.identity == target else {
      throw LinuxMachineManagementError.staleTarget(target.id)
    }
  }

  nonisolated private func requireStableIdentity(
    _ target: LinuxMachineIdentity
  ) throws {
    guard target.hasStableCreationIdentity else {
      throw LinuxMachineManagementError.stableIdentityRequired(target.id)
    }
  }

  @discardableResult
  private func waitUntilStopped(
    _ target: LinuxMachineIdentity,
    afterForce: Bool = false
  ) async throws -> LinuxMachineRuntimeSnapshot? {
    for attempt in 0..<Self.statePollAttempts {
      guard let current = try await runtime.snapshot(id: target.id) else {
        return nil
      }
      try validate(current, matches: target)
      if current.state == .stopped {
        return current
      }
      if attempt + 1 < Self.statePollAttempts {
        try await sleep(.milliseconds(200))
      }
    }
    throw afterForce
      ? LinuxMachineManagementError.forceStopNotConfirmed(target.id)
      : LinuxMachineManagementError.stopNotConfirmed(target.id)
  }

  private func reconcileCreationIgnoringCancellation(
    id: String
  ) async -> CreationReconciliation {
    let runtime = self.runtime
    return await Task.detached {
      do {
        return try await runtime.snapshot(id: id) == nil ? .absent : .present
      } catch {
        return .unknown
      }
    }.value
  }

  private func recoverMachineIgnoringCancellation(
    _ target: LinuxMachineIdentity
  ) async -> LinuxMachineRecoveryOutcome {
    let runtime = self.runtime
    let sleep = self.sleep
    return await Task.detached {
      do {
        guard let current = try await runtime.snapshot(id: target.id) else {
          return .missing
        }
        guard current.identity == target else {
          return .failed(LinuxMachineManagementError.staleTarget(target.id).localizedDescription)
        }
        guard current.state != .stopped else {
          return .alreadyStopped
        }

        try? await runtime.stop(id: target.id)
        for attempt in 0..<Self.statePollAttempts {
          guard let refreshed = try await runtime.snapshot(id: target.id) else {
            return .missing
          }
          guard refreshed.identity == target else {
            return .failed(
              LinuxMachineManagementError.staleTarget(target.id).localizedDescription
            )
          }
          if refreshed.state == .stopped {
            return .gracefullyStopped
          }
          if attempt + 1 < Self.statePollAttempts {
            try await sleep(.milliseconds(200))
          }
        }

        guard let refreshed = try await runtime.snapshot(id: target.id) else {
          return .missing
        }
        guard refreshed.identity == target else {
          return .failed(
            LinuxMachineManagementError.staleTarget(target.id).localizedDescription
          )
        }
        if refreshed.state == .stopped {
          return .gracefullyStopped
        }
        guard let backingContainerID = refreshed.backingContainerID else {
          return .failed(
            LinuxMachineManagementError.backingContainerMissing(target.id)
              .localizedDescription
          )
        }
        let forceStopError: (any Error)?
        do {
          try await runtime.forceStop(backingContainerID: backingContainerID)
          forceStopError = nil
        } catch {
          forceStopError = error
        }

        for attempt in 0..<Self.statePollAttempts {
          guard let stopped = try await runtime.snapshot(id: target.id) else {
            return .missing
          }
          guard stopped.identity == target else {
            return .failed(
              LinuxMachineManagementError.staleTarget(target.id).localizedDescription
            )
          }
          if stopped.state == .stopped {
            return .forceStopped
          }
          if attempt + 1 < Self.statePollAttempts {
            try await sleep(.milliseconds(200))
          }
        }
        if let forceStopError {
          return .failed(forceStopError.localizedDescription)
        }
        return .failed(
          LinuxMachineManagementError.forceStopNotConfirmed(target.id).localizedDescription
        )
      } catch {
        return .failed(error.localizedDescription)
      }
    }.value
  }

  private static func result(
    from snapshot: LinuxMachineRuntimeSnapshot
  ) -> LinuxMachineCreationResult {
    LinuxMachineCreationResult(
      identity: snapshot.identity,
      state: snapshot.state,
      isInitialized: snapshot.isInitialized
    )
  }
}
