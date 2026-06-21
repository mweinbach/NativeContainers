import Foundation

actor AppleContainerBuildService: ImageBuilding {
  private let planningService: any ImageBuildPlanning
  private let executionService: any ImageBuildExecuting
  private let lifecycleService: any ImageBuildLifecycleManaging
  private let buildExecutionCoordinator: RuntimeMutationCoordinator

  init(
    planningService: any ImageBuildPlanning,
    executionService: any ImageBuildExecuting,
    lifecycleService: any ImageBuildLifecycleManaging,
    buildExecutionCoordinator: RuntimeMutationCoordinator = .imageBuilds
  ) {
    self.planningService = planningService
    self.executionService = executionService
    self.lifecycleService = lifecycleService
    self.buildExecutionCoordinator = buildExecutionCoordinator
  }

  init(
    contextStager: any BuildContextStaging = BuildContextStager(),
    secretManager: any ImageBuildSecretManaging = ImageBuildSecretVault(),
    worker: any ContainerBuildWorkerRunning = ContainerBuildWorkerProcess(),
    imageStore: any ImageBuildStoring = AppleImageBuildStore(),
    artifactManager: any ImageBuildArtifactManaging = AppleImageBuildArtifactManager(),
    outputManager: any ImageBuildOutputManaging = AppleImageBuildOutputService(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    buildExecutionCoordinator: RuntimeMutationCoordinator = .imageBuilds
  ) {
    planningService = AppleImageBuildPlanningService(
      contextStager: contextStager,
      secretManager: secretManager,
      imageStore: imageStore,
      outputManager: outputManager
    )
    executionService = AppleImageBuildExecutionService(
      contextStager: contextStager,
      secretManager: secretManager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager,
      outputManager: outputManager,
      runtimeMutationCoordinator: runtimeMutationCoordinator
    )
    lifecycleService = AppleImageBuildLifecycleService(
      contextStager: contextStager,
      secretManager: secretManager,
      artifactManager: artifactManager,
      outputManager: outputManager
    )
    self.buildExecutionCoordinator = buildExecutionCoordinator
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    try await planningService.prepare(request, progress: progress)
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    do {
      let result = try await buildExecutionCoordinator.perform { [executionService] in
        try await executionService.execute(
          plan,
          authorization: authorization,
          progress: progress
        )
      }
      await lifecycleService.cleanup(plan)
      return result
    } catch {
      await lifecycleService.cleanup(plan)
      await progress(
        ImageBuildProgress(
          phase: .exportingArtifact,
          message: error.localizedDescription,
          logTail: ImageBuildProgressBridge.standardErrorTail(from: error)
        )
      )
      throw error
    }
  }

  func discardBuild(_ plan: ImageBuildPlan) async {
    await lifecycleService.discard(plan)
  }
}
