import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ImageBuildServiceCompositionTests {
  @Test
  func facadeDelegatesEachLifecyclePhaseToItsFocusedService() async throws {
    let plan = compositionPlan()
    let request = compositionRequest()
    let result = compositionResult(for: plan)
    let planning = CompositionPlanningService(plan: plan)
    let execution = CompositionExecutionService(result: .success(result))
    let lifecycle = CompositionLifecycleService()
    let service = AppleContainerBuildService(
      planningService: planning,
      executionService: execution,
      lifecycleService: lifecycle,
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )

    let prepared = try await service.prepareBuild(request) { _ in }
    let completed = try await service.build(prepared, authorization: .none) { _ in }
    await service.discardBuild(prepared)

    #expect(prepared == plan)
    #expect(completed == result)
    #expect(await planning.requests == [request])
    #expect(await execution.plans == [plan])
    #expect(await execution.authorizations == [.none])
    #expect(await lifecycle.cleanedPlans == [plan])
    #expect(await lifecycle.discardedPlans == [plan])
  }

  @Test
  func facadeAlwaysRunsLifecycleCleanupWhenExecutionFails() async {
    let plan = compositionPlan()
    let execution = CompositionExecutionService(
      result: .failure(CompositionExecutionError.failed)
    )
    let lifecycle = CompositionLifecycleService()
    let progress = CompositionProgressRecorder()
    let service = AppleContainerBuildService(
      planningService: CompositionPlanningService(plan: plan),
      executionService: execution,
      lifecycleService: lifecycle,
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )

    await #expect(throws: CompositionExecutionError.failed) {
      _ = try await service.build(plan, authorization: .none) { update in
        await progress.record(update)
      }
    }

    #expect(await lifecycle.cleanedPlans == [plan])
    #expect(await lifecycle.discardedPlans.isEmpty)
    #expect(await progress.values.last?.phase == .exportingArtifact)
  }

  @Test
  func requestValidatorCanBeUsedWithoutStagingOrRuntimeServices() throws {
    let validator = ImageBuildRequestValidator()

    #expect(throws: ImageBuildError.emptyTags) {
      try validator.validate(
        ImageBuildRequest(
          contextDirectory: URL(filePath: "/tmp/context", directoryHint: .isDirectory),
          dockerfile: nil,
          secrets: [],
          tags: [],
          platforms: [.current],
          buildArguments: [],
          labels: [],
          targetStage: "",
          cachePolicy: .builderInternal,
          pullLatest: false,
          builderCPUCount: nil,
          builderMemoryMiB: nil
        )
      )
    }

    try validator.validate(compositionRequest())
  }
}

private actor CompositionPlanningService: ImageBuildPlanning {
  private let plan: ImageBuildPlan
  private(set) var requests: [ImageBuildRequest] = []

  init(plan: ImageBuildPlan) {
    self.plan = plan
  }

  func prepare(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    requests.append(request)
    return plan
  }
}

private actor CompositionExecutionService: ImageBuildExecuting {
  private let result: Result<ImageBuildResult, CompositionExecutionError>
  private(set) var plans: [ImageBuildPlan] = []
  private(set) var authorizations: [ImageBuildAuthorization] = []

  init(result: Result<ImageBuildResult, CompositionExecutionError>) {
    self.result = result
  }

  func execute(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    plans.append(plan)
    authorizations.append(authorization)
    return try result.get()
  }
}

private actor CompositionLifecycleService: ImageBuildLifecycleManaging {
  private(set) var discardedPlans: [ImageBuildPlan] = []
  private(set) var cleanedPlans: [ImageBuildPlan] = []

  func discard(_ plan: ImageBuildPlan) {
    discardedPlans.append(plan)
  }

  func cleanup(_ plan: ImageBuildPlan) {
    cleanedPlans.append(plan)
  }
}

private actor CompositionProgressRecorder {
  private(set) var values: [ImageBuildProgress] = []

  func record(_ progress: ImageBuildProgress) {
    values.append(progress)
  }
}

private enum CompositionExecutionError: Error {
  case failed
}

private func compositionRequest() -> ImageBuildRequest {
  ImageBuildRequest(
    contextDirectory: URL(filePath: "/tmp/context", directoryHint: .isDirectory),
    dockerfile: nil,
    secrets: [],
    tags: ["example.test/app:latest"],
    platforms: [.current],
    buildArguments: [],
    labels: [],
    targetStage: "",
    cachePolicy: .builderInternal,
    pullLatest: false,
    builderCPUCount: nil,
    builderMemoryMiB: nil
  )
}

private func compositionPlan() -> ImageBuildPlan {
  let id = UUID(uuidString: "A4D9730A-2F56-4C5E-A3B0-19E6C6246E26")!
  let context = URL(
    filePath: "/tmp/nativecontainers-composition/\(id.uuidString)/context",
    directoryHint: .isDirectory
  )
  return ImageBuildPlan(
    id: id,
    sourceContextDirectory: context,
    stagedContextDirectory: context,
    stagedDockerfile: context.appending(path: "Dockerfile", directoryHint: .notDirectory),
    dockerfileSHA256: String(repeating: "a", count: 64),
    stagedDockerignore: nil,
    dockerignoreSHA256: nil,
    contextFingerprint: String(repeating: "b", count: 64),
    secretReviewID: nil,
    secrets: [],
    tags: [
      ContainerBuildTagExpectation(
        reference: "example.test/app:latest",
        existingDigest: nil
      )
    ],
    platforms: [.current],
    buildArguments: [],
    labels: [],
    targetStage: "",
    cachePolicy: .builderInternal,
    pullLatest: false,
    builderCPUCount: nil,
    builderMemoryMiB: nil,
    output: .imageStore,
    generatedAt: Date(timeIntervalSince1970: 1)
  )
}

private func compositionResult(for plan: ImageBuildPlan) -> ImageBuildResult {
  ImageBuildResult(
    buildID: plan.id,
    output: .imageStore(
      digest: "sha256:built",
      tags: plan.tags.map(\.reference)
    ),
    platforms: plan.platforms,
    durationMilliseconds: 10,
    logTail: ""
  )
}
