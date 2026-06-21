import ContainerAPIClient
import ContainerResource
import Foundation

struct ComposeProjectMutationRequest: Sendable {
  let plan: ComposeProjectPlan
  let operationID: UUID
  let canonicalConfiguration: Data
  let composeExecutableURL: URL
  let commandEnvironment: ComposeCommandEnvironment
}

protocol ComposeProjectMutationExecuting: Sendable {
  func execute(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult
}

struct ComposeRuntimeContainerSnapshot: Equatable, Sendable {
  let record: ContainerRecord
  let imageDigest: String
  let stopSignal: String?
  let hasPublishedSockets: Bool
  let usesSSHAgent: Bool
}

protocol ComposeContainerMutationTransport: Sendable {
  func list() async throws -> [ComposeRuntimeContainerSnapshot]
  func start(id: String) async throws
  func signal(id: String, signal: String) async throws
  func delete(id: String) async throws
}

struct AppleComposeContainerMutationClient: ComposeContainerMutationTransport {
  private let client: ContainerClient

  init(client: ContainerClient = ContainerClient()) {
    self.client = client
  }

  func list() async throws -> [ComposeRuntimeContainerSnapshot] {
    try await client.list().map { snapshot in
      ComposeRuntimeContainerSnapshot(
        record: AppleRuntimeInventoryService.containerRecord(from: snapshot),
        imageDigest: snapshot.configuration.image.digest,
        stopSignal: snapshot.configuration.stopSignal,
        hasPublishedSockets: !snapshot.configuration.publishedSockets.isEmpty,
        usesSSHAgent: snapshot.configuration.ssh
      )
    }
  }

  func start(id: String) async throws {
    let process = try await client.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: [:]
    )
    try await process.start()
  }

  func signal(id: String, signal: String) async throws {
    try await client.kill(id: id, signal: signal)
  }

  func delete(id: String) async throws {
    try await client.delete(id: id)
  }
}

protocol ComposeMutationSleeping: Sendable {
  func sleep(for duration: Duration) async throws
}

struct TaskComposeMutationSleeper: ComposeMutationSleeping {
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

struct ComposeMutationTiming: Equatable, Sendable {
  let gracefulPollAttempts: Int
  let confirmationPollAttempts: Int
  let pollInterval: Duration

  init(
    gracefulPollAttempts: Int = 20,
    confirmationPollAttempts: Int = 20,
    pollInterval: Duration = .milliseconds(250)
  ) {
    precondition(gracefulPollAttempts > 0)
    precondition(confirmationPollAttempts > 0)
    self.gracefulPollAttempts = gracefulPollAttempts
    self.confirmationPollAttempts = confirmationPollAttempts
    self.pollInterval = pollInterval
  }
}

struct AppleComposeProjectMutationExecutor: ComposeProjectMutationExecuting {
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let containers: any ComposeContainerMutationTransport
  private let infrastructure: any AppleInfrastructureTransport
  private let inventory: any ContainerInventoryLoading
  private let commandExecutor: any HostCommandExecuting
  private let executionWorkspace: any ComposeExecutionWorkspaceManaging
  private let journal: any ComposeOperationJournaling
  private let sleeper: any ComposeMutationSleeping
  private let timing: ComposeMutationTiming

  init(
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    containers: any ComposeContainerMutationTransport =
      AppleComposeContainerMutationClient(),
    infrastructure: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    inventory: any ContainerInventoryLoading,
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(
      launcher: FoundationHostProcessLauncher(maximumOutputBytes: 1_024 * 1_024)
    ),
    executionWorkspace: any ComposeExecutionWorkspaceManaging =
      FileComposeExecutionWorkspace(),
    journal: any ComposeOperationJournaling,
    sleeper: any ComposeMutationSleeping = TaskComposeMutationSleeper(),
    timing: ComposeMutationTiming = ComposeMutationTiming()
  ) {
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
    self.containers = containers
    self.infrastructure = infrastructure
    self.inventory = inventory
    self.commandExecutor = commandExecutor
    self.executionWorkspace = executionWorkspace
    self.journal = journal
    self.sleeper = sleeper
    self.timing = timing
  }

  func execute(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult {
    try await runtimeMutationCoordinator.perform {
      do {
        return try await executeWhileLocked(request)
      } catch {
        _ = try? await inventory.loadInventory()
        throw error
      }
    }
  }

  private func executeWhileLocked(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult {
    try Task.checkCancellation()
    try await assertObservedIdentity(request.plan)
    try await journal.updatePending(
      operationID: request.operationID,
      expectedPhase: .prepared,
      progress: ComposeOperationJournalProgress(phase: .executing)
    )

    var completedStepTokens: [String] = []

    switch request.plan.options.action {
    case .up:
      if request.plan.containerActions.contains(where: { $0.operation == .converge }) {
        guard request.plan.containerActions.allSatisfy({ $0.operation == .converge }) else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
        for action in request.plan.containerActions {
          let identity = try requiredIdentity(for: action)
          try await start(identity)
          completedStepTokens.append(action.stepID.rawValue)
          try await recordExecutingProgress(
            operationID: request.operationID,
            stepTokens: completedStepTokens
          )
        }
      } else {
        guard request.plan.containerActions.allSatisfy({ $0.operation == .create }) else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
        try await executeFreshUp(request)
        completedStepTokens.append(ComposeProjectActionStepID.composeUp().rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }

    case .start:
      for action in request.plan.containerActions {
        guard action.operation == .start else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
        let identity = try requiredIdentity(for: action)
        try await start(identity)
        completedStepTokens.append(action.stepID.rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }

    case .stop:
      for action in request.plan.containerActions {
        guard action.operation == .stop else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
        let identity = try requiredIdentity(for: action)
        try await stop(
          identity,
          killStuckContainers: request.plan.options.killStuckContainers
        )
        completedStepTokens.append(action.stepID.rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }

    case .down:
      for action in request.plan.containerActions {
        guard action.removesContainer else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
        let identity = try requiredIdentity(for: action)
        try await stop(
          identity,
          killStuckContainers: request.plan.options.killStuckContainers
        )
        try await delete(identity)
        completedStepTokens.append(action.stepID.rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }
      for action in request.plan.networkActions {
        guard action.operation == .removeManaged else { continue }
        try await deleteNetwork(action)
        completedStepTokens.append(action.stepID.rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }
      for action in request.plan.volumeActions {
        guard action.operation == .removeManaged else { continue }
        try await deleteVolume(action)
        completedStepTokens.append(action.stepID.rawValue)
        try await recordExecutingProgress(
          operationID: request.operationID,
          stepTokens: completedStepTokens
        )
      }
    }

    try await journal.updatePending(
      operationID: request.operationID,
      expectedPhase: .executing,
      progress: ComposeOperationJournalProgress(
        phase: .verifying,
        completedStepTokens: completedStepTokens
      )
    )
    let finalInventory = try await inventory.loadInventory()
    try verifyPostconditions(plan: request.plan, inventory: finalInventory)
    try await journal.updatePending(
      operationID: request.operationID,
      expectedPhase: .verifying,
      progress: ComposeOperationJournalProgress(
        phase: .finished,
        completedStepTokens: completedStepTokens
      )
    )
    return executionResult(plan: request.plan, inventory: finalInventory)
  }

  private func executeFreshUp(_ request: ComposeProjectMutationRequest) async throws {
    let lease = try executionWorkspace.prepare(
      operationID: request.operationID,
      canonicalConfiguration: request.canonicalConfiguration,
      expectedSHA256: request.plan.fullConfigurationSHA256
    )
    var arguments = [
      "--context", DockerContextService.contextName,
      "--project-name", request.plan.options.projectName,
      "--project-directory", lease.directoryURL.nativeContainersPOSIXPath,
      "--file", lease.configurationURL.nativeContainersPOSIXPath,
    ]
    for profile in request.plan.options.profiles {
      arguments.append(contentsOf: ["--profile", profile])
    }
    arguments.append(contentsOf: [
      "up",
      "--detach",
      "--no-build",
      "--pull", request.plan.options.pullPolicy.rawValue,
      "--no-recreate",
    ])

    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: request.composeExecutableURL,
        arguments: arguments,
        environment: request.commandEnvironment.values,
        timeout: .seconds(600)
      )
    } catch {
      let commandError = error
      do {
        try executionWorkspace.remove(lease)
      } catch {
        throw ComposeProjectLifecycleError.partialCompletion(
          "Compose execution failed and its private workspace also could not be removed: \(error.localizedDescription)"
        )
      }
      throw commandError
    }
    try executionWorkspace.remove(lease)
    guard result.exitCode == 0, !result.outputWasTruncated else {
      throw ComposeProjectLifecycleError.commandFailed(
        action: .up,
        exitCode: result.exitCode,
        output: result.outputWasTruncated
          ? "Compose output exceeded the bounded execution log."
          : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }

  private func start(_ identity: ComposeProjectContainerIdentity) async throws {
    let snapshot = try await requireContainer(identity)
    if snapshot.record.state == .running { return }
    guard
      snapshot.record.ports.isEmpty,
      !snapshot.hasPublishedSockets,
      !snapshot.usesSSHAgent
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await containers.start(id: identity.id)
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state == .running
      {
        return
      }
      throw error
    }
    guard
      try await waitForContainer(identity, running: true)
        != nil
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) did not confirm Running after start."
      )
    }
  }

  private func stop(
    _ identity: ComposeProjectContainerIdentity,
    killStuckContainers: Bool
  ) async throws {
    let snapshot = try await requireContainer(identity)
    guard snapshot.record.state == .running || snapshot.record.state == .stopping else {
      return
    }

    do {
      try await containers.signal(
        id: identity.id,
        signal: snapshot.stopSignal ?? "TERM"
      )
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state != .running,
        reconciled.record.state != .stopping
      {
        return
      }
      throw error
    }

    if try await waitForContainer(identity, running: false) != nil {
      return
    }
    guard killStuckContainers else {
      throw ComposeProjectLifecycleError.partialCompletion(
        "Container \(identity.id) remained running after its graceful stop timeout; automatic KILL was disabled."
      )
    }

    let beforeKill = try await requireContainer(identity)
    guard beforeKill.record.state == .running || beforeKill.record.state == .stopping else {
      return
    }
    do {
      try await containers.signal(id: identity.id, signal: "KILL")
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state != .running,
        reconciled.record.state != .stopping
      {
        return
      }
      throw error
    }
    guard
      try await waitForContainer(
        identity,
        running: false,
        attempts: timing.confirmationPollAttempts
      ) != nil
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) did not confirm exit after KILL."
      )
    }
  }

  private func delete(_ identity: ComposeProjectContainerIdentity) async throws {
    let snapshot = try await requireContainer(identity)
    guard snapshot.record.state != .running, snapshot.record.state != .stopping else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    do {
      try await containers.delete(id: identity.id)
    } catch {
      if try await currentContainer(identity) == nil {
        return
      }
      throw error
    }
    guard
      try await waitForContainerAbsence(
        identity,
        attempts: timing.confirmationPollAttempts
      )
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) remained present after deletion."
      )
    }
  }

  private func deleteNetwork(
    _ action: ComposeProjectNetworkAction
  ) async throws {
    guard let expected = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let before = try await inventory.loadInventory()
    guard
      let record = before.networks.first(where: { $0.id == expected.id }),
      expected.matches(record),
      record.name == action.runtimeName,
      record.usedByContainerIDs.isEmpty,
      !record.isBuiltin
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await infrastructure.deleteNetwork(id: record.id)
    } catch {
      let reconciled = try await inventory.loadInventory()
      if !reconciled.networks.contains(where: { $0.id == expected.id }) {
        return
      }
      throw error
    }

    let confirmed = try await inventory.loadInventory()
    guard
      !confirmed.networks.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      })
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Network \(action.runtimeName) remained present after deletion."
      )
    }
  }

  private func deleteVolume(
    _ action: ComposeProjectVolumeAction
  ) async throws {
    guard let expected = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let before = try await inventory.loadInventory()
    guard
      let record = before.volumes.first(where: { $0.id == expected.id }),
      expected.matches(record),
      record.name == action.runtimeName,
      record.usedByContainerIDs.isEmpty
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await infrastructure.deleteVolume(name: record.name)
    } catch {
      let reconciled = try await inventory.loadInventory()
      if !reconciled.volumes.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      }) {
        return
      }
      throw error
    }

    let confirmed = try await inventory.loadInventory()
    guard
      !confirmed.volumes.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      })
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Volume \(action.runtimeName) remained present after deletion."
      )
    }
  }

  private func requiredIdentity(
    for action: ComposeProjectContainerAction
  ) throws -> ComposeProjectContainerIdentity {
    guard let identity = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return identity
  }

  private func requireContainer(
    _ identity: ComposeProjectContainerIdentity
  ) async throws -> ComposeRuntimeContainerSnapshot {
    guard let snapshot = try await currentContainer(identity) else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return snapshot
  }

  private func currentContainer(
    _ identity: ComposeProjectContainerIdentity
  ) async throws -> ComposeRuntimeContainerSnapshot? {
    let matches = try await containers.list().filter { $0.record.id == identity.id }
    guard matches.count <= 1 else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    guard let snapshot = matches.first else { return nil }
    guard
      identity.matches(snapshot.record),
      identity.imageDigest == nil || identity.imageDigest == snapshot.imageDigest
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return snapshot
  }

  private func waitForContainer(
    _ identity: ComposeProjectContainerIdentity,
    running: Bool,
    attempts: Int? = nil
  ) async throws -> ComposeRuntimeContainerSnapshot? {
    let maximumAttempts = attempts ?? timing.gracefulPollAttempts
    for attempt in 0..<maximumAttempts {
      guard let snapshot = try await currentContainer(identity) else {
        return running ? nil : nil
      }
      let isRunning =
        snapshot.record.state == .running || snapshot.record.state == .stopping
      if isRunning == running {
        return snapshot
      }
      if attempt + 1 < maximumAttempts {
        try await sleeper.sleep(for: timing.pollInterval)
      }
    }
    return nil
  }

  private func waitForContainerAbsence(
    _ identity: ComposeProjectContainerIdentity,
    attempts: Int
  ) async throws -> Bool {
    for attempt in 0..<attempts {
      if try await currentContainer(identity) == nil {
        return true
      }
      if attempt + 1 < attempts {
        try await sleeper.sleep(for: timing.pollInterval)
      }
    }
    return false
  }

  private func assertObservedIdentity(_ plan: ComposeProjectPlan) async throws {
    let current = try await inventory.loadInventory()
    for identity in plan.observedIdentity.containers {
      guard
        let record = current.containers.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    for identity in plan.observedIdentity.volumes {
      guard
        let record = current.volumes.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    for identity in plan.observedIdentity.networks {
      guard
        let record = current.networks.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }

    let expectedContainerIDs = Set(plan.observedIdentity.containers.map(\.id))
    let currentProjectIDs = Set(
      current.containers.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard expectedContainerIDs == currentProjectIDs else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    let expectedProjectVolumeIDs = Set(
      plan.observedIdentity.volumes.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    let currentProjectVolumeIDs = Set(
      current.volumes.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard expectedProjectVolumeIDs == currentProjectVolumeIDs else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    let expectedProjectNetworkIDs = Set(
      plan.observedIdentity.networks.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    let currentProjectNetworkIDs = Set(
      current.networks.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard expectedProjectNetworkIDs == currentProjectNetworkIDs else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
  }

  private func recordExecutingProgress(
    operationID: UUID,
    stepTokens: [String]
  ) async throws {
    try await journal.updatePending(
      operationID: operationID,
      expectedPhase: .executing,
      progress: ComposeOperationJournalProgress(
        phase: .executing,
        completedStepTokens: stepTokens
      )
    )
  }

  private func verifyPostconditions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    switch plan.options.action {
    case .up:
      try verifyUpPostconditions(plan: plan, inventory: inventory)

    case .start:
      try requireActionContainers(
        actions: plan.containerActions,
        inventory: inventory,
        stateMatches: { $0 == .running }
      )

    case .stop:
      try requireActionContainers(
        actions: plan.containerActions,
        inventory: inventory,
        stateMatches: { $0 != .running && $0 != .stopping }
      )

    case .down:
      let remainingIDs = Set(inventory.containers.map(\.id))
      let removedContainerIDs = Set(
        plan.containerActions.filter(\.removesContainer).compactMap(\.existingContainerID)
      )
      guard remainingIDs.isDisjoint(with: removedContainerIDs) else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "One or more reviewed containers remained after Down."
        )
      }
      let remainingNetworkNames = Set(inventory.networks.map(\.name))
      let removedNetworkNames = Set(
        plan.networkActions.filter { $0.operation == .removeManaged }.map(\.runtimeName)
      )
      guard remainingNetworkNames.isDisjoint(with: removedNetworkNames) else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "One or more reviewed networks remained after Down."
        )
      }
      let remainingVolumeNames = Set(inventory.volumes.map(\.name))
      let removedVolumeNames = Set(
        plan.volumeActions.filter { $0.operation == .removeManaged }.map(\.runtimeName)
      )
      guard remainingVolumeNames.isDisjoint(with: removedVolumeNames) else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "One or more reviewed volumes remained after Down."
        )
      }
    }

    try verifyPreservedIdentities(plan: plan, inventory: inventory)
  }

  private func verifyUpPostconditions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    let projectContainers = inventory.containers.filter {
      $0.labels[ComposeLabelKey.project] == plan.options.projectName
    }
    let observedIDs = Set(plan.observedIdentity.containers.map(\.id))
    let createActions = plan.containerActions.filter { $0.operation == .create }
    let newContainers = projectContainers.filter { !observedIDs.contains($0.id) }

    guard newContainers.count == createActions.count else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Up produced an unexpected number of new project containers."
      )
    }
    for action in createActions {
      let matches = newContainers.filter {
        $0.labels[ComposeLabelKey.service] == action.serviceName
          && Int($0.labels[ComposeLabelKey.containerNumber] ?? "")
            == action.replicaNumber
          && $0.labels[ComposeLabelKey.oneOff]?.lowercased() != "true"
      }
      guard matches.count == 1 else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Up did not create exactly one reviewed \(action.serviceName) replica."
        )
      }
    }

    let imagesByReference = Dictionary(
      inventory.images.map { ($0.reference, $0.digest) },
      uniquingKeysWith: { first, _ in first }
    )
    for service in plan.desiredState.activeServices {
      let instances = projectContainers.filter {
        $0.labels[ComposeLabelKey.service] == service.name
          && $0.labels[ComposeLabelKey.oneOff]?.lowercased() != "true"
      }
      let expectedReplicas = Set(1...service.replicaCount)
      guard
        instances.count == service.replicaCount,
        Set(
          instances.compactMap {
            Int($0.labels[ComposeLabelKey.containerNumber] ?? "")
          }) == expectedReplicas,
        instances.allSatisfy({ $0.state == .running }),
        instances.allSatisfy({ $0.imageReference == service.imageReference }),
        instances.allSatisfy({
          $0.imageDigest != nil
            && $0.imageDigest == imagesByReference[service.imageReference]
        }),
        instances.allSatisfy({
          service.configurationHash == nil
            || $0.labels[ComposeLabelKey.configHash] == service.configurationHash
        })
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Service \(service.name) did not reach its exact reviewed running replica set."
        )
      }
    }

    try requireActionContainers(
      actions: plan.containerActions.filter { $0.operation == .converge },
      inventory: inventory,
      stateMatches: { $0 == .running }
    )
    try verifyUpVolumeActions(plan: plan, inventory: inventory)
    try verifyUpNetworkActions(plan: plan, inventory: inventory)
  }

  private func verifyUpVolumeActions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    var allowedProjectIDs = Set(
      plan.observedIdentity.volumes.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    for action in plan.volumeActions {
      let matches = inventory.volumes.filter { $0.name == action.runtimeName }
      guard matches.count == 1, let record = matches.first else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Volume \(action.runtimeName) did not reach its reviewed disposition."
        )
      }
      switch action.operation {
      case .createManaged:
        guard
          action.expectedIdentity == nil,
          record.labels[ComposeLabelKey.project] == plan.options.projectName,
          record.labels[ComposeLabelKey.volume] == action.logicalName
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Managed volume \(action.runtimeName) has unexpected ownership."
          )
        }
        allowedProjectIDs.insert(record.id)
      case .reuseManaged, .useExternal:
        guard let expected = action.expectedIdentity, expected.matches(record) else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Volume \(action.runtimeName) changed during Up."
          )
        }
      case .removeManaged:
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    let currentProjectIDs = Set(
      inventory.volumes.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard currentProjectIDs == allowedProjectIDs else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Unexpected project volumes appeared during Up."
      )
    }
  }

  private func verifyUpNetworkActions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    var allowedProjectIDs = Set(
      plan.observedIdentity.networks.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    for action in plan.networkActions {
      let matches = inventory.networks.filter { $0.name == action.runtimeName }
      guard matches.count == 1, let record = matches.first else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Network \(action.runtimeName) did not reach its reviewed disposition."
        )
      }
      switch action.operation {
      case .createManaged:
        guard
          action.expectedIdentity == nil,
          record.labels[ComposeLabelKey.project] == plan.options.projectName,
          record.labels[ComposeLabelKey.network] == action.logicalName
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Managed network \(action.runtimeName) has unexpected ownership."
          )
        }
        allowedProjectIDs.insert(record.id)
      case .reuseManaged, .useExternal:
        guard let expected = action.expectedIdentity, expected.matches(record) else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Network \(action.runtimeName) changed during Up."
          )
        }
      case .removeManaged:
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    let currentProjectIDs = Set(
      inventory.networks.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard currentProjectIDs == allowedProjectIDs else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Unexpected project networks appeared during Up."
      )
    }
  }

  private func requireActionContainers(
    actions: [ComposeProjectContainerAction],
    inventory: ContainerInventory,
    stateMatches: (RuntimeState) -> Bool
  ) throws {
    let recordsByID = Dictionary(
      uniqueKeysWithValues: inventory.containers.map { ($0.id, $0) }
    )
    for action in actions {
      guard let identity = action.expectedIdentity else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "A reviewed container action lost its exact identity."
        )
      }
      guard
        let record = recordsByID[identity.id],
        identity.matches(record),
        stateMatches(record.state)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Container \(identity.id) did not reach the reviewed state."
        )
      }
    }
  }

  private func verifyPreservedIdentities(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    for resource in plan.preservedResources {
      switch resource {
      case .container(let identity):
        guard
          let record = inventory.containers.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved container \(identity.id) changed during the operation."
          )
        }
      case .volume(let identity):
        guard
          let record = inventory.volumes.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved volume \(identity.configuration.name) changed during the operation."
          )
        }
      case .network(let identity):
        guard
          let record = inventory.networks.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved network \(identity.configuration.name) changed during the operation."
          )
        }
      case .external(let kind, let name), .absent(let kind, let name):
        let isPresent =
          switch kind {
          case .volume: inventory.volumes.contains { $0.name == name }
          case .network: inventory.networks.contains { $0.name == name }
          }
        guard !isPresent else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved absent \(kind.rawValue) \(name) appeared during the operation."
          )
        }
      }
    }
  }

  private func executionResult(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) -> ComposeProjectExecutionResult {
    ComposeProjectExecutionResult(
      action: plan.options.action,
      projectName: plan.options.projectName,
      observedState: nil,
      remainingContainerCount: inventory.containers.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.count,
      remainingVolumeCount: inventory.volumes.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.count,
      remainingNetworkCount: inventory.networks.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.count
    )
  }
}
