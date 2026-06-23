import Foundation

protocol ComposeProjectLifecycleManaging: Sendable {
  func discoverInputRequirements(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectInputRequirements

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputs: ComposeProjectReviewInputs
  ) async throws -> ComposeProjectPlan

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult
  func discardInputRequirements(_ requirementsID: UUID) async
  func discardReview(planID: UUID) async
  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot]
  func discardRecoveryAfterReview(operationID: UUID) async throws
}

extension ComposeProjectLifecycleManaging {
  func discoverInputRequirements(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectInputRequirements {
    throw ComposeProjectLifecycleError.unavailable(
      "Compose input discovery is not configured."
    )
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputs: ComposeProjectReviewInputs
  ) async throws -> ComposeProjectPlan {
    throw ComposeProjectLifecycleError.unavailable(
      "Compose environment-backed input review is not configured."
    )
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] { [] }
  func discardInputRequirements(_ requirementsID: UUID) async {}
  func discardReview(planID: UUID) async {}
  func discardRecoveryAfterReview(operationID: UUID) async throws {}
}

actor ComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let sourceAccess: any ComposeProjectSourceAccessing
  private let configRenderer: any ComposeConfigRendering
  private let desiredStateDecoder: any ComposeDesiredStateDecoding
  private let inputVault: any ComposeProjectInputManaging
  private let executionWorkspace: any ComposeExecutionWorkspaceManaging
  private let executionOverlay: any ComposeExecutionOverlayPreparing
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
    inputVault: any ComposeProjectInputManaging = ComposeProjectInputVault(),
    executionWorkspace: any ComposeExecutionWorkspaceManaging = FileComposeExecutionWorkspace(),
    executionOverlay: any ComposeExecutionOverlayPreparing = ComposeExecutionOverlayService(),
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
    self.inputVault = inputVault
    self.executionWorkspace = executionWorkspace
    self.executionOverlay = executionOverlay
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
    try await review(
      directoryURL: directoryURL,
      options: options,
      suppliedInputs: nil
    )
  }

  func discoverInputRequirements(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectInputRequirements {
    try validate(options)
    let lease = try await sourceAccess.acquire(directoryURL: directoryURL)
    let rendered: ComposeRenderedConfiguration

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
      let requirements = try await inputVault.discover(
        source: lease,
        options: options,
        rendered: rendered
      )
      await sourceAccess.release(lease)
      return requirements
    } catch {
      await sourceAccess.release(lease)
      throw error
    }

  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputs: ComposeProjectReviewInputs
  ) async throws -> ComposeProjectPlan {
    try await review(
      directoryURL: directoryURL,
      options: options,
      suppliedInputs: inputs
    )
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

    let prepared: ComposePreparedProjectPlan
    do {
      prepared = try await preparedPlans.consume(plan)
    } catch {
      await inputVault.discard(planID: plan.id)
      throw error
    }
    let request: ComposeProjectMutationRequest
    do {
      request = try await prepareMutation(
        plan: prepared.plan,
        directoryURL: prepared.directoryURL
      )
    } catch {
      await inputVault.discard(planID: plan.id)
      throw error
    }
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

  func discardInputRequirements(_ requirementsID: UUID) async {
    await inputVault.discard(requirementsID: requirementsID)
  }

  func discardReview(planID: UUID) async {
    await preparedPlans.discard(planID: planID)
    await inputVault.discard(planID: planID)
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
      let decoded = try desiredStateDecoder.decode(
        rendered: second,
        expectedProjectName: plan.options.projectName,
        serviceInputSeals: Dictionary(
          uniqueKeysWithValues: plan.desiredState.activeServices.compactMap { service in
            service.inputSeal.map { (service.name, $0) }
          }
        )
      )
      desiredReview = ComposeDesiredStateReview(
        desiredState: decoded.desiredState,
        issues: decoded.issues + (try await inputVault.reviewIssues(for: plan))
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
    let reviewedInputs = try await inputVault.consume(for: plan)
    return ComposeProjectMutationRequest(
      plan: plan,
      operationID: UUID(),
      canonicalConfiguration: rendered.fullConfiguration,
      composeExecutableURL: executableURL,
      commandEnvironment: executionTool.commandEnvironment,
      reviewedInputs: reviewedInputs
    )
  }

  private func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    suppliedInputs: ComposeProjectReviewInputs?
  ) async throws -> ComposeProjectPlan {
    try validate(options)
    let lease = try await sourceAccess.acquire(directoryURL: directoryURL)
    let rendered: ComposeRenderedConfiguration
    let desiredReview: ComposeDesiredStateReview
    let preparedInputs: ComposePreparedProjectInputs
    var preparedInputToken: UUID?

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
      if let suppliedInputs {
        preparedInputs = try await inputVault.prepare(
          requirementsID: suppliedInputs.requirementsID,
          inputs: suppliedInputs,
          source: lease,
          options: options,
          rendered: second
        )
      } else {
        preparedInputs = try await inputVault.prepareImmediate(
          source: lease,
          options: options,
          rendered: second
        )
      }
      preparedInputToken = preparedInputs.token
      let decoded = try desiredStateDecoder.decode(
        rendered: second,
        expectedProjectName: options.projectName,
        serviceInputSeals: preparedInputs.serviceSeals
      )
      desiredReview = ComposeDesiredStateReview(
        desiredState: decoded.desiredState,
        issues: decoded.issues + preparedInputs.issues
      )
      await sourceAccess.release(lease)
    } catch {
      await inputVault.discard(token: preparedInputToken)
      await sourceAccess.release(lease)
      throw error
    }

    do {
      try Task.checkCancellation()
      let currentInventory = try await inventory.loadInventory()
      let provisionalPlan = planner.plan(
        source: lease.summary,
        rendered: rendered,
        review: desiredReview,
        options: options,
        inventory: currentInventory
      )
      let plan = try await planWithExecutionHashes(
        provisionalPlan,
        rendered: rendered,
        inputToken: preparedInputs.token
      )
      if plan.canExecute {
        try await inputVault.bind(token: preparedInputs.token, to: plan.id)
      } else {
        await inputVault.discard(token: preparedInputs.token)
      }
      await preparedPlans.store(plan: plan, directoryURL: directoryURL)
      return plan
    } catch {
      await inputVault.discard(token: preparedInputs.token)
      throw error
    }
  }

  private func planWithExecutionHashes(
    _ plan: ComposeProjectPlan,
    rendered: ComposeRenderedConfiguration,
    inputToken: UUID?
  ) async throws -> ComposeProjectPlan {
    let activeNames = Set(plan.desiredState.activeServiceNames)
    guard plan.canExecute,
      plan.options.action == .up,
      plan.desiredState.activeServices.contains(where: { $0.inputSeal != nil })
    else {
      return plan.replacingExecutionServiceConfigurationHashes(
        rendered.serviceConfigurationHashes.filter { activeNames.contains($0.key) }
      )
    }
    guard let hashRenderer = configRenderer as? any ComposeExecutionServiceHashRendering,
      let inputStager = executionWorkspace as? any ComposeExecutionInputStaging
    else {
      throw ComposeProjectLifecycleError.unavailable(
        "The configured Compose review services cannot hash the final input overlay."
      )
    }
    let payload = try await inputVault.payload(for: inputToken)
    let stagedURLs = try inputStager.stageInputs(
      projectName: plan.options.projectName,
      files: payload.files
    )
    let configuration = try executionOverlay.prepare(
      canonicalConfiguration: rendered.fullConfiguration,
      plan: plan,
      reviewedInputs: payload,
      stagedFileURLs: stagedURLs
    )
    let lease = try executionWorkspace.prepare(
      operationID: plan.id,
      projectName: plan.options.projectName,
      canonicalConfiguration: configuration.data,
      expectedSHA256: configuration.sha256
    )
    let hashes: [String: String]
    do {
      hashes = try await hashRenderer.renderExecutionServiceHashes(
        configurationURL: lease.configurationURL,
        projectDirectoryURL: lease.directoryURL,
        options: plan.options,
        inputEnvironment: payload.environmentValues
      )
      try executionWorkspace.release(lease)
    } catch {
      _ = try? executionWorkspace.release(lease)
      throw error
    }
    guard Set(hashes.keys) == activeNames,
      hashes.values.allSatisfy({ hash in
        hash.count == 64
          && hash.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
          }
      })
    else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The execution overlay hashes did not match the active service set."
      )
    }
    return plan.replacingExecutionServiceConfigurationHashes(hashes)
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
  fileprivate func replacingExecutionServiceConfigurationHashes(
    _ hashes: [String: String]
  ) -> ComposeProjectPlan {
    ComposeProjectPlan(
      id: id,
      generatedAt: generatedAt,
      options: options,
      source: source,
      desiredState: desiredState,
      fullConfigurationSHA256: fullConfigurationSHA256,
      activeConfigurationSHA256: activeConfigurationSHA256,
      composeReleaseVersion: composeReleaseVersion,
      composeBinarySHA256: composeBinarySHA256,
      composeSourceRevision: composeSourceRevision,
      environmentSHA256: environmentSHA256,
      serviceConfigurationHashes: serviceConfigurationHashes,
      executionServiceConfigurationHashes: hashes,
      observedIdentity: observedIdentity,
      issues: issues,
      containerActions: containerActions,
      volumeActions: volumeActions,
      networkActions: networkActions,
      orphanContainers: orphanContainers,
      preservedResources: preservedResources
    )
  }

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

  func discoverInputRequirements(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectInputRequirements {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputs: ComposeProjectReviewInputs
  ) async throws -> ComposeProjectPlan {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }
}
