import Foundation

protocol ImageBuildLifecycleManaging: Sendable {
  func discard(_ plan: ImageBuildPlan) async
  func cleanup(_ plan: ImageBuildPlan) async
}

struct AppleImageBuildLifecycleService: ImageBuildLifecycleManaging {
  private let contextStager: any BuildContextStaging
  private let secretManager: any ImageBuildSecretManaging
  private let artifactManager: any ImageBuildArtifactManaging
  private let outputManager: any ImageBuildOutputManaging

  init(
    contextStager: any BuildContextStaging,
    secretManager: any ImageBuildSecretManaging,
    artifactManager: any ImageBuildArtifactManaging,
    outputManager: any ImageBuildOutputManaging
  ) {
    self.contextStager = contextStager
    self.secretManager = secretManager
    self.artifactManager = artifactManager
    self.outputManager = outputManager
  }

  func discard(_ plan: ImageBuildPlan) async {
    if let secretReviewID = plan.secretReviewID {
      await secretManager.discard(reviewID: secretReviewID)
    }
    await outputManager.discard(plan.output)
    try? await contextStager.discard(plan.stagedContext)
  }

  func cleanup(_ plan: ImageBuildPlan) async {
    await discard(plan)
    await artifactManager.removeArtifacts(buildID: plan.id)
  }
}

extension ImageBuildPlan {
  var stagedContext: StagedBuildContext {
    StagedBuildContext(
      id: id,
      contextURL: stagedContextDirectory,
      dockerfileURL: stagedDockerfile,
      dockerfileSHA256: dockerfileSHA256,
      dockerignoreURL: stagedDockerignore,
      dockerignoreSHA256: dockerignoreSHA256,
      fingerprint: contextFingerprint
    )
  }
}
