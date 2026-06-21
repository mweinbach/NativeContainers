import Foundation

protocol ComposeProjectLifecycleManaging: Sendable {
  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult
  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot]
  func discardRecoveryAfterReview(operationID: UUID) async throws
}

extension ComposeProjectLifecycleManaging {
  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] { [] }
  func discardRecoveryAfterReview(operationID: UUID) async throws {}
}

actor ComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let sourceAccess: any ComposeProjectSourceAccessing
  private let configRenderer: any ComposeConfigRendering
  private let desiredStateDecoder: any ComposeDesiredStateDecoding
  private let planner: any ComposeLifecyclePlanning
  private let inventory: any ContainerInventoryLoading
  private let executionTool: any ComposeExecutionToolResolving
  private let preparedPlans: any ComposePreparedPlanStoring
  private let mutationExecutor: any ComposeProjectMutationExecuting
  private let journal: any ComposeOperationJournaling
  private var executionInProgress = false

  init(
    sourceAccess: any ComposeProjectSourceAccessing = FileComposeProjectSourceService(),
    configRenderer: any ComposeConfigRendering,
    desiredStateDecoder: any ComposeDesiredStateDecoding = ComposeDesiredStateDecoder(),
    planner: any ComposeLifecyclePlanning = ComposeLifecyclePlanner(),
    inventory: any ContainerInventoryLoading,
    executionTool: any ComposeExecutionToolResolving =
      UnavailableComposeExecutionToolResolver(),
    preparedPlans: any ComposePreparedPlanStoring = ComposePreparedPlanStore(),
    mutationExecutor: any ComposeProjectMutationExecuting =
      UnavailableComposeProjectMutationExecutor(),
    journal: any ComposeOperationJournaling = UnavailableComposeOperationJournal()
  ) {
    self.sourceAccess = sourceAccess
    self.configRenderer = configRenderer
    self.desiredStateDecoder = desiredStateDecoder
    self.planner = planner
    self.inventory = inventory
    self.executionTool = executionTool
    self.preparedPlans = preparedPlans
    self.mutationExecutor = mutationExecutor
    self.journal = journal
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    try validate(options)
    let lease = try await sourceAccess.acquire(directoryURL: directoryURL)
    let rendered: ComposeRenderedConfiguration
    let desiredReview: ComposeDesiredStateReview

    do {
      try await sourceAccess.revalidate(lease)
      let first = try await configRenderer.render(source: lease, options: options)
      try await sourceAccess.revalidate(lease)
      let second = try await configRenderer.render(source: lease, options: options)
      try await sourceAccess.revalidate(lease)
      guard first == second else {
        throw ComposeProjectLifecycleError.configChangedDuringReview
      }
      rendered = second
      desiredReview = try desiredStateDecoder.decode(
        rendered: second,
        expectedProjectName: options.projectName
      )
      await sourceAccess.release(lease)
    } catch {
      await sourceAccess.release(lease)
      throw error
    }

    try Task.checkCancellation()
    let currentInventory = try await inventory.loadInventory()
    let plan = planner.plan(
      source: lease.summary,
      rendered: rendered,
      review: desiredReview,
      options: options,
      inventory: currentInventory
    )
    await preparedPlans.store(plan: plan, directoryURL: directoryURL)
    return plan
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    guard plan.canExecute else {
      throw ComposeProjectLifecycleError.reviewBlocked(plan.blockers.count)
    }
    guard !executionInProgress else {
      throw ComposeProjectLifecycleError.unavailable(
        "Another reviewed Compose mutation is already being prepared."
      )
    }
    executionInProgress = true
    defer { executionInProgress = false }

    if let pending = try await journal.pendingRecoverySnapshots().first {
      throw ComposeProjectLifecycleError.journalRecoveryRequired(pending.operationID)
    }

    let prepared = try await preparedPlans.consume(plan)
    let request = try await prepareMutation(
      plan: prepared.plan,
      directoryURL: prepared.directoryURL
    )
    try await journal.persistPending(
      ComposeOperationJournalEntry(
        operationID: request.operationID,
        plan: request.plan
      )
    )
    let result = try await mutationExecutor.execute(request)
    try await journal.discardPendingAfterReview(operationID: request.operationID)
    return result
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] {
    try await journal.pendingRecoverySnapshots()
  }

  func discardRecoveryAfterReview(operationID: UUID) async throws {
    try await journal.discardPendingAfterReview(operationID: operationID)
  }

  private func prepareMutation(
    plan: ComposeProjectPlan,
    directoryURL: URL
  ) async throws -> ComposeProjectMutationRequest {
    let lease = try await sourceAccess.acquire(directoryURL: directoryURL)
    let rendered: ComposeRenderedConfiguration
    let desiredReview: ComposeDesiredStateReview
    do {
      guard lease.summary == plan.source else {
        throw ComposeProjectLifecycleError.sourceChanged
      }
      try await sourceAccess.revalidate(lease)
      let first = try await configRenderer.render(source: lease, options: plan.options)
      try await sourceAccess.revalidate(lease)
      let second = try await configRenderer.render(source: lease, options: plan.options)
      try await sourceAccess.revalidate(lease)
      guard first == second else {
        throw ComposeProjectLifecycleError.configChangedDuringReview
      }
      try requireReviewedConfiguration(second, matches: plan)
      desiredReview = try desiredStateDecoder.decode(
        rendered: second,
        expectedProjectName: plan.options.projectName
      )
      guard desiredReview.desiredState == plan.desiredState else {
        throw ComposeProjectLifecycleError.stalePlan
      }
      rendered = second
      await sourceAccess.release(lease)
    } catch {
      await sourceAccess.release(lease)
      throw error
    }

    let currentInventory = try await inventory.loadInventory()
    let currentPlan = planner.plan(
      source: plan.source,
      rendered: rendered,
      review: desiredReview,
      options: plan.options,
      inventory: currentInventory
    )
    guard currentPlan.matchesExecutionContract(of: plan), currentPlan.canExecute else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    guard executionTool.commandEnvironment.sha256 == plan.environmentSHA256 else {
      throw ComposeProjectLifecycleError.stalePlan
    }
    let executableURL = try await executionTool.verifiedExecutableURL()
    return ComposeProjectMutationRequest(
      plan: plan,
      operationID: UUID(),
      canonicalConfiguration: rendered.fullConfiguration,
      composeExecutableURL: executableURL,
      commandEnvironment: executionTool.commandEnvironment
    )
  }

  private func requireReviewedConfiguration(
    _ rendered: ComposeRenderedConfiguration,
    matches plan: ComposeProjectPlan
  ) throws {
    guard
      rendered.fullConfigurationSHA256 == plan.fullConfigurationSHA256,
      rendered.activeConfigurationSHA256 == plan.activeConfigurationSHA256,
      rendered.composeReleaseVersion == plan.composeReleaseVersion,
      rendered.composeBinarySHA256 == plan.composeBinarySHA256,
      rendered.composeSourceRevision == plan.composeSourceRevision,
      rendered.environmentSHA256 == plan.environmentSHA256,
      rendered.serviceConfigurationHashes == plan.serviceConfigurationHashes
    else {
      throw ComposeProjectLifecycleError.stalePlan
    }
  }

  private func validate(_ options: ComposeProjectReviewOptions) throws {
    guard isValidComposeProjectName(options.projectName) else {
      throw ComposeProjectLifecycleError.invalidProjectName(options.projectName)
    }
    for profile in options.profiles where !isValidComposeProfileName(profile) {
      throw ComposeProjectLifecycleError.invalidProfileName(profile)
    }
    if options.action != .down, options.removeVolumes {
      throw ComposeProjectLifecycleError.unavailable(
        "Remove Volumes is only valid for a reviewed down operation."
      )
    }
  }
}

extension ComposeProjectPlan {
  fileprivate func matchesExecutionContract(of reviewed: ComposeProjectPlan) -> Bool {
    options == reviewed.options
      && source == reviewed.source
      && desiredState == reviewed.desiredState
      && fullConfigurationSHA256 == reviewed.fullConfigurationSHA256
      && activeConfigurationSHA256 == reviewed.activeConfigurationSHA256
      && composeReleaseVersion == reviewed.composeReleaseVersion
      && composeBinarySHA256 == reviewed.composeBinarySHA256
      && composeSourceRevision == reviewed.composeSourceRevision
      && environmentSHA256 == reviewed.environmentSHA256
      && serviceConfigurationHashes == reviewed.serviceConfigurationHashes
      && observedIdentity == reviewed.observedIdentity
      && issues == reviewed.issues
      && containerActions == reviewed.containerActions
      && volumeActions == reviewed.volumeActions
      && networkActions == reviewed.networkActions
      && orphanContainers == reviewed.orphanContainers
      && preservedResources == reviewed.preservedResources
  }
}

struct UnavailableComposeProjectMutationExecutor: ComposeProjectMutationExecuting {
  func execute(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult {
    throw ComposeProjectLifecycleError.unavailable(
      "No exact-ID Compose mutation executor is configured."
    )
  }
}

actor UnavailableComposeOperationJournal: ComposeOperationJournaling {
  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {
    throw ComposeProjectLifecycleError.unavailable(
      "No crash-safe Compose operation journal is configured."
    )
  }

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {
    throw ComposeProjectLifecycleError.unavailable(
      "No crash-safe Compose operation journal is configured."
    )
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] { [] }
  func discardPendingAfterReview(operationID: UUID) async throws {}
}

actor UnavailableComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let reason: String

  init(reason: String = "Compose desired-state review is unavailable.") {
    self.reason = reason
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }
}
