import Foundation

@MainActor
final class LinuxBoxRuntimeCoordinator {
  typealias FailureHandler =
    @MainActor @Sendable (LinuxVirtualMachineRuntimeTarget, any Error) -> Void

  private struct ActiveSession {
    let connectionID: UUID
    let target: LinuxVirtualMachineRuntimeTarget
    let engineSession: any LinuxVirtualMachineRuntimeEngineSession
    let client: LinuxVirtualMachineAgentClient
    let profile: LinuxBoxProfile
    let preflight: LinuxBoxResidentialPreflightResult?
    var verification: LinuxBoxVerification
  }

  private let residentialPolicy: LinuxBoxResidentialPolicy
  private var sessions: [UUID: ActiveSession] = [:]

  private var activeOperations: [UUID: LinuxBoxGuestOperation] = [:]
  private var failureHandler: FailureHandler?
  init(residentialPolicy: LinuxBoxResidentialPolicy = LinuxBoxResidentialPolicy()) {
    self.residentialPolicy = residentialPolicy
  }

  func setFailureHandler(_ handler: @escaping FailureHandler) {
    failureHandler = handler
  }

  func start(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    machine: ResolvedLinuxVirtualMachine,
    timeoutSeconds: Int = 300
  ) async throws -> LinuxBoxVerification {
    guard session.isManagedLinuxBox,
      let descriptor = machine.manifest.linuxConfiguration?.linuxBoxDescriptor
    else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant(
        "the managed image descriptor is absent"
      )
    }
    let preflightTask = descriptor.profile == .residential
      ? detachedPreflight(vmID: machine.manifest.id, timeoutSeconds: timeoutSeconds)
      : nil
    do {
      try await session.start()
      let client = try await connectAndEstablish(session: session, descriptor: descriptor)
      let initial = try await client.status()
      do {
        let preflight = try await preflightTask?.value
        let verification = try await configureAndVerify(
          client: client, profile: descriptor.profile, preflight: preflight,
          timeoutSeconds: timeoutSeconds
        )
        await activate(machineID: machine.manifest.id, session: session, client: client,
          profile: descriptor.profile, preflight: preflight, verification: verification)
        return verification
      } catch {
        if descriptor.profile == .residential { try requireFailClosed(initial) }
        await client.close()
        throw error
      }
    } catch {
      preflightTask?.cancel()
      if let active = sessions.removeValue(forKey: machine.manifest.id) { await active.client.close() }
      throw error
    }
  }

  func resume(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    machine: ResolvedLinuxVirtualMachine,
    timeoutSeconds: Int = 300
  ) async throws -> LinuxBoxVerification {
    guard session.isManagedLinuxBox,
      let descriptor = machine.manifest.linuxConfiguration?.linuxBoxDescriptor
    else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant(
        "the managed image descriptor is absent"
      )
    }
    sessions.removeValue(forKey: machine.manifest.id)
    let preflightTask = descriptor.profile == .residential
      ? detachedPreflight(vmID: machine.manifest.id, timeoutSeconds: timeoutSeconds)
      : nil
    do {
      try await session.resume()
      let client = try await connectAndEstablish(session: session, descriptor: descriptor)
      let preflight = try await preflightTask?.value
      let verification = try await configureAndVerify(
        client: client, profile: descriptor.profile, preflight: preflight,
        timeoutSeconds: timeoutSeconds
      )
      await activate(machineID: machine.manifest.id, session: session, client: client,
        profile: descriptor.profile, preflight: preflight, verification: verification)
      return verification
    } catch {
      preflightTask?.cancel()
      if let active = sessions.removeValue(forKey: machine.manifest.id) { await active.client.close() }
      throw error
    }
  }

  func verify(
    target: LinuxVirtualMachineRuntimeTarget,
    timeoutSeconds: Int = 300
  ) async throws -> LinuxBoxVerification {
    try beginOperation(.verify, target: target)
    defer { endOperation(target: target) }
    guard var active = sessions[target.machineID], active.target == target else {
      throw LinuxVirtualMachineAgentClientError.connectionClosed
    }
    do {
      let verification = try await verify(
        client: active.client,
        profile: active.profile,
        preflight: active.preflight,
        timeoutSeconds: timeoutSeconds
      )
      return verification
    } catch {
      sessions[target.machineID] = nil
      await active.client.close()
      throw error
    }
  }

  func refresh(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    machine: ResolvedLinuxVirtualMachine,
    timeoutSeconds: Int = 300
  ) async throws -> LinuxBoxVerification {
    try beginOperation(.configure, target: session.target)
    defer { endOperation(target: session.target) }
    let id = machine.manifest.id
    guard session.isManagedLinuxBox,
      let descriptor = machine.manifest.linuxConfiguration?.linuxBoxDescriptor
    else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant(
        "the managed image descriptor is absent"
      )
    }
    if let active = sessions.removeValue(forKey: id) {
      do {
        _ = try await active.client.quiesce(reason: .refresh)
        await active.client.close()
      } catch {
        await active.client.close()
        throw error
      }
    }
    let preflightTask = descriptor.profile == .residential
      ? detachedPreflight(vmID: id, timeoutSeconds: timeoutSeconds) : nil
    do {
      let client = try await connectAndEstablish(session: session, descriptor: descriptor)
      let preflight = try await preflightTask?.value
      let verification = try await configureAndVerify(
        client: client, profile: descriptor.profile, preflight: preflight,
        timeoutSeconds: timeoutSeconds
      )
      await activate(machineID: id, session: session, client: client,
        profile: descriptor.profile, preflight: preflight, verification: verification)
      return verification
    } catch {
      preflightTask?.cancel()
      if let active = sessions.removeValue(forKey: id) { await active.client.close() }
      throw error
    }
  }

  func execute(
    target: LinuxVirtualMachineRuntimeTarget,
    argv: [String],
    timeoutSeconds: Int
  ) async throws -> LinuxBoxGuestExecResult {
    try beginOperation(.exec, target: target)
    defer { endOperation(target: target) }
    guard let active = sessions[target.machineID], active.target == target else {
      throw LinuxVirtualMachineAgentClientError.connectionClosed
    }
    return try await active.client.execute(
      argv: argv,
      timeoutSeconds: timeoutSeconds
    )
  }

  func quiesce(target: LinuxVirtualMachineRuntimeTarget,
    reason: LinuxBoxGuestQuiesceReason) async throws {
    guard let active = sessions.removeValue(forKey: target.machineID),
      active.target == target else { return }
    do {
      let result = try await active.client.quiesce(reason: reason)
      if active.profile == .residential {
        guard result.state == .quiesced, result.singBoxStopped,
          result.networkClientsStopped, result.runtimeSecretsRemoved,
          result.baselineActive else {
          throw LinuxVirtualMachineAgentClientError.securityInvariant(
            "destructive quiesce did not prove every postcondition")
        }
      }
      await active.client.close()
    } catch {
      await active.client.close()
      throw error
    }
  }

  func isBusy(target: LinuxVirtualMachineRuntimeTarget) -> Bool {
    activeOperations[target.machineID] != nil
  }

  func lastVerification(
    target: LinuxVirtualMachineRuntimeTarget
  ) -> LinuxBoxVerification? {
    guard let active = sessions[target.machineID], active.target == target else {
      return nil
    }
    return active.verification
  }

  func status(target: LinuxVirtualMachineRuntimeTarget) async throws -> LinuxBoxGuestStatusResult {
    guard let active = sessions[target.machineID], active.target == target else {
      throw LinuxVirtualMachineAgentClientError.connectionClosed
    }
    return try await active.client.status()
  }

  func close(target: LinuxVirtualMachineRuntimeTarget) async {
    guard let active = sessions.removeValue(forKey: target.machineID),
      active.target == target
    else { return }
    await active.client.close()
  }

  func closeAll() async {
    let active = Array(sessions.values)
    sessions.removeAll()
    for session in active {
      await session.client.close()
    }
  }
  private func beginOperation(_ operation: LinuxBoxGuestOperation,
    target: LinuxVirtualMachineRuntimeTarget) throws {
    guard activeOperations[target.machineID] == nil else {
      throw LinuxVirtualMachineRuntimeError.operationInProgress(target.machineID)
    }
    activeOperations[target.machineID] = operation
  }

  private func endOperation(target: LinuxVirtualMachineRuntimeTarget) {
    activeOperations[target.machineID] = nil
  }

  private func activate(
    machineID: UUID,
    session: any LinuxVirtualMachineRuntimeEngineSession,
    client: LinuxVirtualMachineAgentClient,
    profile: LinuxBoxProfile,
    preflight: LinuxBoxResidentialPreflightResult?,
    verification: LinuxBoxVerification
  ) async {
    let connectionID = UUID()
    sessions[machineID] = ActiveSession(connectionID: connectionID, target: session.target,
      engineSession: session, client: client, profile: profile, preflight: preflight,
      verification: verification)
    await client.setFailureHandler { [weak self] error in
      await self?.handleUnexpectedConnectionFailure(
        machineID: machineID,
        connectionID: connectionID,
        error: error
      )
    }
  }
  private func handleUnexpectedConnectionFailure(
    machineID: UUID, connectionID: UUID, error: any Error
  ) async {
    guard let active = sessions[machineID], active.connectionID == connectionID else { return }
    sessions[machineID] = nil
    activeOperations[machineID] = nil
    failureHandler?(active.target, error)
    await active.client.close()
    if active.profile == .residential {
      do { try await active.engineSession.forceStop() }
      catch { failureHandler?(active.target, error) }
    }
  }

  private func detachedPreflight(
    vmID: UUID,
    timeoutSeconds: Int
  ) -> Task<LinuxBoxResidentialPreflightResult, any Error> {
    let policy = residentialPolicy
    return Task.detached(priority: .userInitiated) {
      try await policy.prepare(vmID: vmID, timeoutSeconds: timeoutSeconds)
    }
  }

  private func connectAndEstablish(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    descriptor: LinuxBoxDescriptor
  ) async throws -> LinuxVirtualMachineAgentClient {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(60))
    var lastError: (any Error)?
    while clock.now < deadline {
      try Task.checkCancellation()
      var client: LinuxVirtualMachineAgentClient?
        let remainingSeconds = try Self.remainingSeconds(
          until: deadline,
          clock: clock
        )
      do {
        let transport = try await session.connectAgent(
          port: LinuxBoxGuestProtocol.socketPort
        )
        let candidate = LinuxVirtualMachineAgentClient(transport: transport)
        client = candidate
        _ = try await candidate.establish(
          descriptor: descriptor,
          timeoutSeconds: remainingSeconds
        )
        return candidate
      } catch {
        if let client {
          await client.close()
        }
        try Task.checkCancellation()
        if let clientError = error as? LinuxVirtualMachineAgentClientError {
          switch clientError {
          case .identityMismatch, .protocolViolation, .guest, .securityInvariant:
            throw clientError
          case .connectionClosed, .timedOut:
            break
          }
        }
        lastError = error
        try await clock.sleep(for: .milliseconds(250))
      }
    }
    throw lastError ?? LinuxVirtualMachineAgentClientError.timedOut
  }
  private static func remainingSeconds(
    until deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> Int {
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw LinuxVirtualMachineAgentClientError.timedOut
    }
    let components = remaining.components
    let rounded = components.seconds + (components.attoseconds > 0 ? 1 : 0)
    guard rounded > 0 else {
      throw LinuxVirtualMachineAgentClientError.timedOut
    }
    return Int(rounded)
  }


  private func configureAndVerify(
    client: LinuxVirtualMachineAgentClient,
    profile: LinuxBoxProfile,
    preflight: LinuxBoxResidentialPreflightResult?,
    timeoutSeconds: Int
  ) async throws -> LinuxBoxVerification {
    let configured = try await client.configure(profile: profile,
      configuration: preflight?.configuration, expectedProxyIP: preflight?.hostProxyIP,
      timeoutSeconds: timeoutSeconds)
    guard configured.profile == profile else { throw LinuxVirtualMachineAgentClientError.identityMismatch }
    let healthy = try await client.status()
    guard configured.state == .authorizing, configured.authorizationPublished,
      healthy.baselineActive else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant("guest did not authorize")
    }
    if profile == .residential {
      guard healthy.state == .healthy, healthy.authorizationActive, healthy.networkdActive,
        healthy.singBoxActive, !healthy.ready else {
        throw LinuxVirtualMachineAgentClientError.securityInvariant("tunnel did not become healthy")
      }
    } else {
      guard healthy.profile == .standard else {
        throw LinuxVirtualMachineAgentClientError.identityMismatch
      }
    }
    return try await verify(client: client, profile: profile, preflight: preflight,
      timeoutSeconds: timeoutSeconds)
  }

  private func verify(
    client: LinuxVirtualMachineAgentClient,
    profile: LinuxBoxProfile,
    preflight: LinuxBoxResidentialPreflightResult?,
    timeoutSeconds: Int
  ) async throws -> LinuxBoxVerification {
    let result = try await client.verify(profile: profile,
      expectedProxyIP: preflight?.hostProxyIP, hostDirectIP: preflight?.hostDirectIP,
      timeoutSeconds: timeoutSeconds)
    if profile == .standard {
      guard result.egress == nil, result.doh == nil, result.checks.allSatisfy(\.ok) else {
        throw LinuxVirtualMachineAgentClientError.securityInvariant("standard verification failed")
      }
      let ready = try await client.status()
      guard ready.profile == .standard, ready.state == .ready, ready.ready else {
        throw LinuxVirtualMachineAgentClientError.securityInvariant("standard readiness was not published")
      }
      return LinuxBoxVerification(verifiedAt: Date(), profile: .standard,
        checks: result.checks.map { LinuxBoxVerificationCheck(name: $0.name, ok: $0.ok, details: $0.details) })
    }
    guard let preflight, let egress = result.egress, let doh = result.doh else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant("residential evidence is incomplete")
    }
    let expectedDoH = preflight.configuration.endpoints.doh
    guard egress.curlIP == preflight.hostProxyIP, egress.chromiumIP == preflight.hostProxyIP,
      egress.curlIP != preflight.hostDirectIP, egress.isp == preflight.isp,
      egress.country == preflight.country, doh.address == expectedDoH.address,
      doh.serverName == expectedDoH.serverName, result.checks.allSatisfy(\.ok) else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant("residential proofs do not agree")
    }
    let ready = try await client.status()
    guard ready.state == .ready, ready.ready, ready.authorizationActive,
      ready.networkdActive, ready.singBoxActive, ready.baselineActive else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant("readiness was not published")
    }
    return LinuxBoxVerification(verifiedAt: Date(), profile: .residential,
      egress: .init(hostDirectIP: preflight.hostDirectIP, hostProxyIP: preflight.hostProxyIP,
        curlIP: egress.curlIP, chromiumIP: egress.chromiumIP, isp: egress.isp, country: egress.country),
      doh: .init(address: doh.address, serverName: doh.serverName),
      checks: result.checks.map { LinuxBoxVerificationCheck(name: $0.name, ok: $0.ok, details: $0.details) })
  }

  private func requireFailClosed(_ status: LinuxBoxGuestStatusResult) throws {
    guard status.baselineActive,
      !status.authorizationActive,
      !status.networkdActive,
      !status.singBoxActive,
      !status.ready,
      status.state == .awaitingConfiguration || status.state == .quiesced
    else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant(
        "credential preflight failed without a fail-closed guest"
      )
    }
  }
}
