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

    var completedContainerIDs: [String] = []
    var completedNetworkNames: [String] = []

    switch request.plan.options.action {
    case .up:
      try await executeFreshUp(request)

    case .start:
      for identity in orderedContainerIdentities(
        in: request.plan,
        reverseDependencies: false
      ) {
        try await start(identity)
        completedContainerIDs.append(identity.id)
        try await recordExecutingProgress(
          operationID: request.operationID,
          containerIDs: completedContainerIDs,
          networkNames: completedNetworkNames
        )
      }

    case .stop:
      for identity in orderedContainerIdentities(
        in: request.plan,
        reverseDependencies: true
      ) {
        try await stop(
          identity,
          killStuckContainers: request.plan.options.killStuckContainers
        )
        completedContainerIDs.append(identity.id)
        try await recordExecutingProgress(
          operationID: request.operationID,
          containerIDs: completedContainerIDs,
          networkNames: completedNetworkNames
        )
      }

    case .down:
      for identity in orderedContainerIdentities(
        in: request.plan,
        reverseDependencies: true
      ) {
        try await stop(
          identity,
          killStuckContainers: request.plan.options.killStuckContainers
        )
        try await delete(identity)
        completedContainerIDs.append(identity.id)
        try await recordExecutingProgress(
          operationID: request.operationID,
          containerIDs: completedContainerIDs,
          networkNames: completedNetworkNames
        )
      }
      for networkName in request.plan.affectedNetworkNames {
        try await deleteNetwork(
          named: networkName,
          plan: request.plan
        )
        completedNetworkNames.append(networkName)
        try await recordExecutingProgress(
          operationID: request.operationID,
          containerIDs: completedContainerIDs,
          networkNames: completedNetworkNames
        )
      }
    }

    try await journal.updatePending(
      operationID: request.operationID,
      expectedPhase: .executing,
      progress: ComposeOperationJournalProgress(
        phase: .verifying,
        completedContainerIDs: completedContainerIDs,
        completedNetworkNames: completedNetworkNames
      )
    )
    let finalInventory = try await inventory.loadInventory()
    try verifyPostconditions(plan: request.plan, inventory: finalInventory)
    try await journal.updatePending(
      operationID: request.operationID,
      expectedPhase: .verifying,
      progress: ComposeOperationJournalProgress(
        phase: .finished,
        completedContainerIDs: completedContainerIDs,
        completedNetworkNames: completedNetworkNames
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
    named name: String,
    plan: ComposeProjectPlan
  ) async throws {
    guard
      let expected = plan.observedIdentity.networks.first(
        where: { $0.configuration.name == name }
      )
    else {
      return
    }
    let before = try await inventory.loadInventory()
    guard
      let record = before.networks.first(where: { $0.name == name }),
      expected.matches(record),
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
        "Network \(name) remained present after deletion."
      )
    }
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
      if let digest = identity.imageDigest {
        guard
          current.images.first(where: { $0.reference == identity.imageReference })?.digest
            == digest
        else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
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
  }

  private func orderedContainerIdentities(
    in plan: ComposeProjectPlan,
    reverseDependencies: Bool
  ) -> [ComposeProjectContainerIdentity] {
    let affected = Set(plan.affectedContainerIDs)
    let serviceOrder = topologicalServiceOrder(plan.desiredState)
    let serviceIndexes = Dictionary(
      uniqueKeysWithValues: serviceOrder.enumerated().map { ($1, $0) }
    )
    let sorted = plan.observedIdentity.containers.filter {
      affected.contains($0.id)
    }.sorted { lhs, rhs in
      let lhsService = lhs.labels[ComposeLabelKey.service] ?? ""
      let rhsService = rhs.labels[ComposeLabelKey.service] ?? ""
      let lhsIndex = serviceIndexes[lhsService] ?? Int.max
      let rhsIndex = serviceIndexes[rhsService] ?? Int.max
      if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
      let lhsReplica = Int(lhs.labels[ComposeLabelKey.containerNumber] ?? "") ?? Int.max
      let rhsReplica = Int(rhs.labels[ComposeLabelKey.containerNumber] ?? "") ?? Int.max
      if lhsReplica != rhsReplica { return lhsReplica < rhsReplica }
      return composeStringOrder(lhs.id, rhs.id)
    }
    return reverseDependencies ? Array(sorted.reversed()) : sorted
  }

  private func topologicalServiceOrder(_ desired: ComposeDesiredState) -> [String] {
    var visited: Set<String> = []
    var order: [String] = []

    func visit(_ service: String) {
      guard visited.insert(service).inserted else { return }
      for dependency in desired.serviceDependencies[service, default: []].sorted(
        by: composeStringOrder
      ) {
        visit(dependency)
      }
      order.append(service)
    }

    for service in desired.declaredServiceNames.sorted(by: composeStringOrder) {
      visit(service)
    }
    return order
  }

  private func recordExecutingProgress(
    operationID: UUID,
    containerIDs: [String],
    networkNames: [String]
  ) async throws {
    try await journal.updatePending(
      operationID: operationID,
      expectedPhase: .executing,
      progress: ComposeOperationJournalProgress(
        phase: .executing,
        completedContainerIDs: containerIDs,
        completedNetworkNames: networkNames
      )
    )
  }

  private func verifyPostconditions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    let projectContainers = inventory.containers.filter {
      $0.labels[ComposeLabelKey.project] == plan.options.projectName
        && $0.labels[ComposeLabelKey.oneOff]?.lowercased() != "true"
    }

    switch plan.options.action {
    case .up:
      for service in plan.desiredState.activeServices {
        let instances = projectContainers.filter {
          $0.labels[ComposeLabelKey.service] == service.name
        }
        guard
          instances.count == service.replicaCount,
          instances.allSatisfy({ $0.state == .running }),
          instances.allSatisfy({ $0.imageReference == service.imageReference }),
          instances.allSatisfy({
            service.configurationHash == nil
              || $0.labels[ComposeLabelKey.configHash] == service.configurationHash
          })
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Service \(service.name) did not reach its reviewed running replica count."
          )
        }
      }
      guard
        Set(projectContainers.compactMap { $0.labels[ComposeLabelKey.service] })
          == Set(plan.desiredState.activeServiceNames)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Unexpected project containers appeared during Up."
        )
      }

    case .start:
      try requireAffectedContainers(
        plan: plan,
        inventory: inventory,
        stateMatches: { $0 == .running }
      )

    case .stop:
      try requireAffectedContainers(
        plan: plan,
        inventory: inventory,
        stateMatches: { $0 != .running && $0 != .stopping }
      )

    case .down:
      let remainingIDs = Set(inventory.containers.map(\.id))
      guard remainingIDs.isDisjoint(with: plan.affectedContainerIDs) else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "One or more reviewed containers remained after Down."
        )
      }
      let remainingNetworkNames = Set(inventory.networks.map(\.name))
      guard remainingNetworkNames.isDisjoint(with: plan.affectedNetworkNames) else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "One or more reviewed networks remained after Down."
        )
      }
    }

    try verifyPreservedIdentities(plan: plan, inventory: inventory)
  }

  private func requireAffectedContainers(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory,
    stateMatches: (RuntimeState) -> Bool
  ) throws {
    let recordsByID = Dictionary(
      uniqueKeysWithValues: inventory.containers.map { ($0.id, $0) }
    )
    for identity in plan.observedIdentity.containers
    where plan.affectedContainerIDs.contains(identity.id) {
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
    let affectedContainers = Set(plan.affectedContainerIDs)
    for identity in plan.observedIdentity.containers
    where !affectedContainers.contains(identity.id) {
      guard
        let record = inventory.containers.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Preserved container \(identity.id) changed during the operation."
        )
      }
    }

    let affectedNetworks = Set(plan.affectedNetworkNames)
    for identity in plan.observedIdentity.networks
    where !affectedNetworks.contains(identity.configuration.name) {
      guard
        let record = inventory.networks.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Preserved network \(identity.configuration.name) changed during the operation."
        )
      }
    }

    for identity in plan.observedIdentity.volumes {
      guard
        let record = inventory.volumes.first(where: { $0.id == identity.id }),
        identity.matches(record)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Preserved volume \(identity.configuration.name) changed during the operation."
        )
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
