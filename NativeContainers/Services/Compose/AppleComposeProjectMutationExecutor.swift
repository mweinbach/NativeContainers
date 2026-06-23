import Foundation

struct ComposeProjectMutationRequest: Sendable {
  let plan: ComposeProjectPlan
  let operationID: UUID
  let canonicalConfiguration: Data
  let composeExecutableURL: URL
  let commandEnvironment: ComposeCommandEnvironment
  let reviewedInputs: ComposeReviewedInputPayload

  init(
    plan: ComposeProjectPlan,
    operationID: UUID,
    canonicalConfiguration: Data,
    composeExecutableURL: URL,
    commandEnvironment: ComposeCommandEnvironment,
    reviewedInputs: ComposeReviewedInputPayload = .empty
  ) {
    self.plan = plan
    self.operationID = operationID
    self.canonicalConfiguration = canonicalConfiguration
    self.composeExecutableURL = composeExecutableURL
    self.commandEnvironment = commandEnvironment
    self.reviewedInputs = reviewedInputs
  }
}

protocol ComposeProjectMutationExecuting: Sendable {
  func execute(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult
}

struct AppleComposeProjectMutationExecutor: ComposeProjectMutationExecuting {
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let inventory: any ContainerInventoryLoading
  private let containerActionService: any ComposeContainerActionExecuting
  private let resourceActionService: any ComposeResourceActionExecuting
  private let upCommandService: any ComposeUpCommandExecuting
  private let postconditionVerifier: any ComposePostconditionVerifying
  private let journal: any ComposeOperationJournaling

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
    self.inventory = inventory
    containerActionService = ComposeContainerActionService(
      containers: containers,
      sleeper: sleeper,
      timing: timing
    )
    resourceActionService = ComposeResourceActionService(
      infrastructure: infrastructure,
      inventory: inventory
    )
    upCommandService = ComposeUpCommandService(
      commandExecutor: commandExecutor,
      executionWorkspace: executionWorkspace
    )
    postconditionVerifier = ComposePostconditionVerifier()
    self.journal = journal
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
      try await executeUp(request, completedStepTokens: &completedStepTokens)
    case .start:
      try await executeContainerActions(
        request.plan.containerActions,
        expected: { $0 == .start },
        request: request,
        completedStepTokens: &completedStepTokens
      )
    case .stop:
      try await executeContainerActions(
        request.plan.containerActions,
        expected: { $0 == .stop },
        request: request,
        completedStepTokens: &completedStepTokens
      )
    case .down:
      try await executeDown(request, completedStepTokens: &completedStepTokens)
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
    try postconditionVerifier.verify(plan: request.plan, inventory: finalInventory)
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

  private func executeUp(
    _ request: ComposeProjectMutationRequest,
    completedStepTokens: inout [String]
  ) async throws {
    try validateUpResourceActions(request.plan)
    guard
      request.plan.containerActions.allSatisfy({
        $0.operation == .converge || $0.operation == .create
      })
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    let createActions = request.plan.containerActions.filter { $0.operation == .create }
    if !createActions.isEmpty {
      try await upCommandService.validate(request)
    }

    let resourceContext = ComposeResourceCreationContext(
      projectName: request.plan.options.projectName,
      composeVersion: request.plan.composeReleaseVersion,
      operationID: request.operationID
    )
    for action in request.plan.networkActions where action.operation == .createManaged {
      try await resourceActionService.create(action, context: resourceContext)
      completedStepTokens.append(action.stepID.rawValue)
      try await recordExecutingProgress(
        operationID: request.operationID,
        stepTokens: completedStepTokens
      )
    }
    for action in request.plan.volumeActions where action.operation == .createManaged {
      try await resourceActionService.create(action, context: resourceContext)
      completedStepTokens.append(action.stepID.rawValue)
      try await recordExecutingProgress(
        operationID: request.operationID,
        stepTokens: completedStepTokens
      )
    }

    try await executeContainerActions(
      request.plan.containerActions.filter { $0.operation == .converge },
      expected: { $0 == .converge },
      request: request,
      completedStepTokens: &completedStepTokens
    )

    guard !createActions.isEmpty else { return }
    try Task.checkCancellation()
    try await upCommandService.execute(request)
    completedStepTokens.append(ComposeProjectActionStepID.composeUp().rawValue)
    try await recordExecutingProgress(
      operationID: request.operationID,
      stepTokens: completedStepTokens
    )
  }

  private func validateUpResourceActions(_ plan: ComposeProjectPlan) throws {
    guard
      plan.networkActions.allSatisfy({
        $0.operation == .createManaged
          || $0.operation == .reuseManaged
          || $0.operation == .useExternal
      }),
      plan.volumeActions.allSatisfy({
        $0.operation == .createManaged
          || $0.operation == .reuseManaged
          || $0.operation == .useExternal
      })
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
  }

  private func executeDown(
    _ request: ComposeProjectMutationRequest,
    completedStepTokens: inout [String]
  ) async throws {
    try await executeContainerActions(
      request.plan.containerActions,
      expected: { $0 == .removeDeclared || $0 == .removeOrphan },
      request: request,
      completedStepTokens: &completedStepTokens
    )
    for action in request.plan.networkActions {
      guard action.operation == .removeManaged else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
      try await resourceActionService.delete(action)
      completedStepTokens.append(action.stepID.rawValue)
      try await recordExecutingProgress(
        operationID: request.operationID,
        stepTokens: completedStepTokens
      )
    }
    for action in request.plan.volumeActions {
      guard action.operation == .removeManaged else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
      try await resourceActionService.delete(action)
      completedStepTokens.append(action.stepID.rawValue)
      try await recordExecutingProgress(
        operationID: request.operationID,
        stepTokens: completedStepTokens
      )
    }
  }

  private func executeContainerActions(
    _ actions: [ComposeProjectContainerAction],
    expected: (ComposeProjectContainerOperation) -> Bool,
    request: ComposeProjectMutationRequest,
    completedStepTokens: inout [String]
  ) async throws {
    for action in actions {
      guard expected(action.operation) else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
      try await containerActionService.execute(
        action,
        killStuckContainers: request.plan.options.killStuckContainers
      )
      completedStepTokens.append(action.stepID.rawValue)
      try await recordExecutingProgress(
        operationID: request.operationID,
        stepTokens: completedStepTokens
      )
    }
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
