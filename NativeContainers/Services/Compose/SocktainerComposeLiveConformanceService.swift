import Foundation

protocol ComposeBridgeLiveConformanceRunning: Sendable {
  func run(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws -> SocktainerComposeLiveFixtureResult
}

actor SocktainerComposeLiveConformanceService:
  ComposeBridgeLiveConformanceRunning
{
  private struct Observation {
    let project: ComposeProjectRecord
    let container: ContainerRecord
    let volume: VolumeRecord
    let network: NetworkRecord
  }

  private let commandExecutor: any HostCommandExecuting
  private let inventory: any ContainerInventoryLoading
  private let topology: any ComposeTopologyDeriving
  private let workspace: any SocktainerComposeFixtureWorkspaceManaging
  private let cleanupPlanner: any SocktainerComposeFixtureCleanupPlanning
  private let nativeCleanup: any SocktainerComposeFixtureNativeCleaning
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    commandExecutor: any HostCommandExecuting,
    inventory: any ContainerInventoryLoading,
    topology: any ComposeTopologyDeriving = ComposeTopologyService(),
    workspace: any SocktainerComposeFixtureWorkspaceManaging =
      FileSocktainerComposeFixtureWorkspace(),
    cleanupPlanner: any SocktainerComposeFixtureCleanupPlanning =
      SocktainerComposeFixtureCleanupPlanner(),
    nativeCleanup: any SocktainerComposeFixtureNativeCleaning =
      AppleSocktainerComposeFixtureNativeCleanup(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.commandExecutor = commandExecutor
    self.inventory = inventory
    self.topology = topology
    self.workspace = workspace
    self.cleanupPlanner = cleanupPlanner
    self.nativeCleanup = nativeCleanup
    self.sleep = sleep
  }

  func run(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws -> SocktainerComposeLiveFixtureResult {
    let composeFileURL = try workspace.prepareFixture(configuration: configuration)
    defer { workspace.removeFixture(at: composeFileURL) }

    var observation: Observation?
    var operationFailure: String?
    var operationWasCancelled = false
    do {
      _ = try await executeCompose(
        ["config", "--quiet"],
        operation: "Compose config validation",
        timeout: .seconds(20),
        configuration: configuration,
        composeFileURL: composeFileURL
      )
      _ = try await executeCompose(
        ["up", "--detach", "--no-build", "--pull", "never"],
        operation: "Compose fixture start",
        timeout: .seconds(90),
        configuration: configuration,
        composeFileURL: composeFileURL
      )
      observation = try await observeProject(configuration: configuration)
    } catch is CancellationError {
      operationWasCancelled = true
      operationFailure = "The fixture operation was cancelled."
    } catch {
      operationFailure = error.localizedDescription
    }

    let cleanupResult: Result<Bool, SocktainerComposeLiveFixtureError> =
      await Task.detached { [self] in
        do {
          return .success(
            try await cleanup(
              configuration: configuration,
              composeFileURL: composeFileURL
            )
          )
        } catch let error as SocktainerComposeLiveFixtureError {
          return .failure(error)
        } catch {
          return .failure(.cleanupFailed(error.localizedDescription))
        }
      }.value

    let usedFallbackCleanup: Bool
    switch cleanupResult {
    case .success(let usedFallback):
      usedFallbackCleanup = usedFallback
    case .failure(let error):
      let cleanupFailure = error.localizedDescription
      if let operationFailure {
        throw SocktainerComposeLiveFixtureError.operationAndCleanupFailed(
          operation: operationFailure,
          cleanup: cleanupFailure
        )
      }
      throw SocktainerComposeLiveFixtureError.cleanupFailed(cleanupFailure)
    }

    if operationWasCancelled {
      throw CancellationError()
    }
    if let operationFailure {
      throw SocktainerComposeLiveFixtureError.operationFailed(operationFailure)
    }
    guard let observation else {
      throw SocktainerComposeLiveFixtureError.operationFailed(
        "No observation was retained."
      )
    }

    return SocktainerComposeLiveFixtureResult(
      projectName: observation.project.name,
      observedState: observation.project.observedState,
      containerID: observation.container.id,
      volumeID: observation.volume.id,
      networkID: observation.network.id,
      usedFallbackCleanup: usedFallbackCleanup
    )
  }

  private func observeProject(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws -> Observation {
    var lastReason = "No matching inventory snapshot was returned."
    for attempt in 0..<configuration.observationAttempts {
      do {
        let snapshot = try await inventory.loadInventory()
        let derived = topology.derive(from: snapshot)
        if let observation = validatedObservation(
          snapshot: snapshot,
          topology: derived,
          configuration: configuration
        ) {
          return observation
        }
        lastReason = "The latest inventory did not contain the complete canonical fixture."
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastReason = error.localizedDescription
      }

      if attempt + 1 < configuration.observationAttempts {
        try await sleep(configuration.pollInterval)
      }
    }
    throw SocktainerComposeLiveFixtureError.projectNotObserved(lastReason)
  }

  private func validatedObservation(
    snapshot: ContainerInventory,
    topology: ComposeTopologySnapshot,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) -> Observation? {
    guard
      let project = topology.project(named: configuration.projectName),
      project.services.count == 1,
      let service = project.services.first,
      service.name == "probe",
      service.instances.count == 1,
      let container = snapshot.containers.first(where: {
        $0.id == configuration.containerName
      }),
      container.state == .running,
      let volume = snapshot.volumes.first(where: {
        $0.name == configuration.volumeName
      }),
      let network = snapshot.networks.first(where: {
        $0.name == configuration.networkName
      }),
      project.volumes.contains(where: {
        $0.logicalName == "data" && $0.volume.id == volume.id
      }),
      project.networks.contains(where: {
        $0.logicalName == "default" && $0.network.id == network.id
      })
    else {
      return nil
    }
    return Observation(
      project: project,
      container: container,
      volume: volume,
      network: network
    )
  }

  private func cleanup(
    configuration: SocktainerComposeLiveFixtureConfiguration,
    composeFileURL: URL
  ) async throws -> Bool {
    do {
      _ = try await executeCompose(
        ["down", "--volumes", "--remove-orphans", "--timeout", "3"],
        operation: "Compose fixture teardown",
        timeout: .seconds(30),
        configuration: configuration,
        composeFileURL: composeFileURL
      )
      try await confirmFixtureAbsent(configuration: configuration)
      return false
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let gracefulFailure = error.localizedDescription
      do {
        let plan = try cleanupPlanner.plan(
          from: try await inventory.loadInventory(),
          configuration: configuration
        )
        try await executeFallbackCleanup(
          plan: plan,
          configuration: configuration
        )
        try await confirmFixtureAbsent(configuration: configuration)
        return true
      } catch {
        throw SocktainerComposeLiveFixtureError.cleanupFailed(
          "Graceful teardown: \(gracefulFailure) Fallback: \(error.localizedDescription)"
        )
      }
    }
  }

  private func executeFallbackCleanup(
    plan: SocktainerComposeFixtureCleanupPlan,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws {
    if let identity = plan.container {
      let current = try await inventory.loadInventory()
      if let container = current.containers.first(where: { $0.id == identity.id }) {
        guard identity.matches(container) else {
          throw SocktainerComposeLiveFixtureError.cleanupResourceChanged(
            "container \(identity.id)"
          )
        }
        try await nativeCleanup.removeContainer(container)
        try await confirmContainerAbsent(
          id: identity.id,
          configuration: configuration
        )
      }
    }

    if let identity = plan.network {
      let current = try await inventory.loadInventory()
      if let network = current.networks.first(where: { $0.id == identity.id }) {
        guard identity.matches(network) else {
          throw SocktainerComposeLiveFixtureError.cleanupResourceChanged(
            "network \(configuration.networkName)"
          )
        }
        try await nativeCleanup.removeNetwork(network)
      }
    }

    if let identity = plan.volume {
      let current = try await inventory.loadInventory()
      if let volume = current.volumes.first(where: { $0.id == identity.id }) {
        guard identity.matches(volume) else {
          throw SocktainerComposeLiveFixtureError.cleanupResourceChanged(
            "volume \(configuration.volumeName)"
          )
        }
        try await nativeCleanup.removeVolume(volume)
      }
    }
  }

  private func confirmContainerAbsent(
    id: String,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws {
    for attempt in 0..<configuration.observationAttempts {
      let snapshot = try await inventory.loadInventory()
      if !snapshot.containers.contains(where: { $0.id == id }) { return }
      if attempt + 1 < configuration.observationAttempts {
        try await sleep(configuration.pollInterval)
      }
    }
    throw SocktainerComposeLiveFixtureError.cleanupResourcesRemain([
      "container \(id)"
    ])
  }

  private func confirmFixtureAbsent(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws {
    var remaining: [String] = []
    for attempt in 0..<configuration.observationAttempts {
      let snapshot = try await inventory.loadInventory()
      remaining = []
      if snapshot.containers.contains(where: { $0.id == configuration.containerName }) {
        remaining.append("container \(configuration.containerName)")
      }
      if snapshot.volumes.contains(where: { $0.name == configuration.volumeName }) {
        remaining.append("volume \(configuration.volumeName)")
      }
      if snapshot.networks.contains(where: { $0.name == configuration.networkName }) {
        remaining.append("network \(configuration.networkName)")
      }
      if remaining.isEmpty { return }
      if attempt + 1 < configuration.observationAttempts {
        try await sleep(configuration.pollInterval)
      }
    }
    throw SocktainerComposeLiveFixtureError.cleanupResourcesRemain(remaining)
  }

  private func executeCompose(
    _ arguments: [String],
    operation: String,
    timeout: Duration,
    configuration: SocktainerComposeLiveFixtureConfiguration,
    composeFileURL: URL
  ) async throws -> HostCommandResult {
    try await execute(
      executableURL: configuration.composeExecutableURL,
      arguments: [
        "--context", configuration.dockerContextName,
        "--project-name", configuration.projectName,
        "--file", composeFileURL.nativeContainersPOSIXPath,
      ] + arguments,
      operation: operation,
      timeout: timeout,
      configuration: configuration
    )
  }

  private func execute(
    executableURL: URL,
    arguments: [String],
    operation: String,
    timeout: Duration,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) async throws -> HostCommandResult {
    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: executableURL,
        arguments: arguments,
        environment: configuration.environment,
        timeout: timeout
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SocktainerComposeLiveFixtureError.commandExecutionFailed(
        operation: operation,
        reason: error.localizedDescription
      )
    }

    guard result.exitCode == 0 else {
      throw SocktainerComposeLiveFixtureError.commandFailed(
        operation: operation,
        exitCode: result.exitCode,
        output: resultOutput(result)
      )
    }
    return result
  }

  private func resultOutput(_ result: HostCommandResult) -> String {
    let output = [result.standardError, result.standardOutput]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(output.suffix(2_000))
  }
}
