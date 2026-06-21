import Foundation

actor AppleContainerBuildService: ImageBuilding {
  private let contextStager: any BuildContextStaging
  private let secretManager: any ImageBuildSecretManaging
  private let worker: any ContainerBuildWorkerRunning
  private let imageStore: any ImageBuildStoring
  private let artifactManager: any ImageBuildArtifactManaging
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let buildExecutionCoordinator: RuntimeMutationCoordinator

  init(
    contextStager: any BuildContextStaging = BuildContextStager(),
    secretManager: any ImageBuildSecretManaging = ImageBuildSecretVault(),
    worker: any ContainerBuildWorkerRunning = ContainerBuildWorkerProcess(),
    imageStore: any ImageBuildStoring = AppleImageBuildStore(),
    artifactManager: any ImageBuildArtifactManaging = AppleImageBuildArtifactManager(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    buildExecutionCoordinator: RuntimeMutationCoordinator = .imageBuilds
  ) {
    self.contextStager = contextStager
    self.secretManager = secretManager
    self.worker = worker
    self.imageStore = imageStore
    self.artifactManager = artifactManager
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
    self.buildExecutionCoordinator = buildExecutionCoordinator
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    try validate(request)
    let tags = try await imageStore.resolveTagExpectations(request.tags)
    let secretReviewID = request.secrets.isEmpty ? nil : UUID()
    var stagedContext: StagedBuildContext?

    do {
      let secretPreparation: ImageBuildSecretPreparation
      if let secretReviewID {
        await progress(
          ImageBuildProgress(
            phase: .stagingSecrets,
            message: "Pinning private secret sources for review",
            logTail: ""
          )
        )
        secretPreparation = try await secretManager.prepare(
          reviewID: secretReviewID,
          selections: request.secrets,
          contextDirectory: request.contextDirectory
        )
      } else {
        secretPreparation = ImageBuildSecretPreparation(
          reviews: [],
          excludedContextFiles: []
        )
      }

      try Task.checkCancellation()
      await progress(
        ImageBuildProgress(
          phase: .stagingContext,
          message: "Copying the build context into a private review boundary",
          logTail: ""
        )
      )
      let dockerfile = resolvedDockerfile(
        requested: request.dockerfile,
        context: request.contextDirectory
      )
      let staged = try await contextStager.stage(
        sourceDirectory: request.contextDirectory,
        dockerfile: dockerfile,
        dockerignore: dockerignoreSelection(dockerfile: dockerfile),
        excludingFileIdentities: secretPreparation.excludedContextFiles
      )
      stagedContext = staged
      if let secretReviewID {
        try await secretManager.revalidate(reviewID: secretReviewID)
      }
      try Task.checkCancellation()

      return ImageBuildPlan(
        id: staged.id,
        sourceContextDirectory: request.contextDirectory.standardizedFileURL,
        stagedContextDirectory: staged.contextURL,
        stagedDockerfile: staged.dockerfileURL,
        dockerfileSHA256: staged.dockerfileSHA256,
        stagedDockerignore: staged.dockerignoreURL,
        dockerignoreSHA256: staged.dockerignoreSHA256,
        contextFingerprint: staged.fingerprint,
        secretReviewID: secretReviewID,
        secrets: secretPreparation.reviews,
        tags: tags,
        platforms: request.platforms,
        buildArguments: request.buildArguments,
        labels: request.labels,
        targetStage: request.targetStage,
        noCache: request.noCache,
        pullLatest: request.pullLatest,
        builderCPUCount: request.builderCPUCount,
        builderMemoryMiB: request.builderMemoryMiB,
        generatedAt: Date()
      )
    } catch {
      if let secretReviewID {
        await secretManager.discard(reviewID: secretReviewID)
      }
      if let stagedContext {
        try? await contextStager.discard(stagedContext)
      }
      throw error
    }
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    do {
      let result = try await buildExecutionCoordinator.perform { [self] in
        try await executeExclusive(
          plan,
          authorization: authorization,
          progress: progress
        )
      }
      await cleanup(plan: plan)
      return result
    } catch {
      await cleanup(plan: plan)
      let logTail = Self.standardErrorTail(from: error)
      await progress(
        ImageBuildProgress(
          phase: .exportingArtifact,
          message: error.localizedDescription,
          logTail: logTail
        )
      )
      throw error
    }
  }

  func discardBuild(_ plan: ImageBuildPlan) async {
    if let secretReviewID = plan.secretReviewID {
      await secretManager.discard(reviewID: secretReviewID)
    }
    try? await contextStager.discard(stagedContext(from: plan))
  }

  private func executeExclusive(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    let staged = stagedContext(from: plan)
    try await contextStager.validate(staged)
    try await validateTagState(plan: plan, authorization: authorization)
    try Task.checkCancellation()

    let reviewedBuilder = ContainerBuilderConfiguration(
      cpuCount: plan.builderCPUCount,
      memoryMiB: plan.builderMemoryMiB,
      allowsRecreateStoppedBuilder: authorization.allowsRecreateStoppedBuilder,
      allowsStopRunningBuilder: authorization.allowsStopRunningBuilder
    )
    await progress(
      ImageBuildProgress(
        phase: .preparingBuilder,
        message: "Preparing Apple’s shared BuildKit container",
        logTail: ""
      )
    )
    let startOutput = try await runtimeMutationCoordinator.perform { [worker] in
      try await worker.run(
        ContainerBuildWorkerRequest(
          operation: .startBuilder,
          builder: reviewedBuilder
        )
      ) { event in
        await Self.relay(event, logTail: "", to: progress)
      }
    }
    try Task.checkCancellation()

    let buildOutput = try await runReviewedBuildWorker(
      plan,
      authorization: authorization,
      progress: progress
    )
    guard let workerResult = buildOutput.result else {
      throw ImageBuildError.workerArtifactMismatch
    }
    try validateArtifactMetadata(workerResult, for: plan)
    let artifactIdentity = try await artifactManager.validateArtifact(workerResult)
    let logTail: String
    if plan.secrets.isEmpty {
      logTail = Self.mergedLogTail(
        startOutput.standardErrorTail,
        buildOutput.standardErrorTail
      )
    } else {
      guard buildOutput.diagnostics == .suppressed else {
        throw ImageBuildError.secretBuildFailed
      }
      logTail = ContainerBuildWorkerDiagnostics.suppressedMessage
    }

    return try await runtimeMutationCoordinator.perform { [self] in
      try await finalize(
        workerResult,
        artifactIdentity: artifactIdentity,
        plan: plan,
        authorization: authorization,
        logTail: logTail,
        progress: progress
      )
    }
  }

  private func runReviewedBuildWorker(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ContainerBuildWorkerProcessOutput {
    let secretPayload: ContainerBuildSecretSourcePayload
    if plan.secrets.isEmpty {
      guard plan.secretReviewID == nil else {
        throw ImageBuildSecretError.reviewMismatch
      }
      secretPayload = .empty
    } else {
      guard let secretReviewID = plan.secretReviewID else {
        throw ImageBuildSecretError.reviewMismatch
      }
      await progress(
        ImageBuildProgress(
          phase: .stagingSecrets,
          message: "Streaming reviewed secrets to the isolated build worker",
          logTail: ""
        )
      )
      secretPayload = try await secretManager.consume(
        reviewID: secretReviewID,
        reviewedSecrets: plan.secrets
      )
    }
    guard secretPayload.ids == plan.secrets.map(\.id) else {
      throw ImageBuildSecretError.reviewMismatch
    }

    let buildRequest = ContainerBuildWorkerBuildRequest(
      buildID: plan.id,
      contextPath: plan.stagedContextDirectory.path(percentEncoded: false),
      dockerfilePath: plan.stagedDockerfile.path(percentEncoded: false),
      dockerfileSHA256: plan.dockerfileSHA256,
      contextFingerprint: plan.contextFingerprint,
      dockerignorePath: plan.stagedDockerignore?.path(percentEncoded: false),
      dockerignoreSHA256: plan.dockerignoreSHA256,
      tags: plan.tags,
      platforms: plan.platforms,
      buildArguments: plan.buildArguments,
      labels: plan.labels,
      targetStage: plan.targetStage,
      noCache: plan.noCache,
      pullLatest: plan.pullLatest,
      secretIDs: secretPayload.ids,
      allowsTagReplacement: authorization.allowsTagReplacement
    )
    do {
      return try await worker.run(
        ContainerBuildWorkerRequest(
          operation: .build,
          builder: ContainerBuilderConfiguration(
            cpuCount: plan.builderCPUCount,
            memoryMiB: plan.builderMemoryMiB,
            allowsRecreateStoppedBuilder: false,
            allowsStopRunningBuilder: false
          ),
          build: buildRequest
        ),
        secrets: secretPayload
      ) { event in
        await Self.relay(event, logTail: "", to: progress)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard plan.secrets.isEmpty else {
        throw ImageBuildError.secretBuildFailed
      }
      throw error
    }
  }

  private func finalize(
    _ artifact: ContainerBuildWorkerResult,
    artifactIdentity: SecureRegularFileIdentity,
    plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    logTail: String,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    try await validateTagState(plan: plan, authorization: authorization)
    let stagingState = try await imageStore.tagState(for: [artifact.stagingReference])
    guard stagingState.currentDigests[artifact.stagingReference] == nil else {
      throw ImageBuildError.stagingReferenceChanged(artifact.stagingReference)
    }
    try Task.checkCancellation()
    await progress(
      ImageBuildProgress(
        phase: .importingImage,
        message: "Importing the isolated OCI artifact into Apple’s image store",
        logTail: logTail
      )
    )
    try await artifactManager.revalidateArtifact(
      artifact,
      expectedIdentity: artifactIdentity
    )
    let loaded = try await imageStore.loadArchive(
      at: URL(filePath: artifact.archivePath),
      expectedReference: artifact.stagingReference
    )
    if let failureMessage = loaded.reconciledFailureMessage {
      throw ImageBuildImportPartialCompletionError(
        buildID: plan.id,
        importedImages: loaded.images.map {
          ImageBuildImportedImageRecord(reference: $0.reference, digest: $0.digest)
        },
        failureMessage:
          "The archive import committed, but its reply failed: \(failureMessage)"
      )
    }
    guard loaded.rejectedMembers.isEmpty else {
      try throwPostImportFailure(
        ImageBuildError.unsafeArchiveMembers(loaded.rejectedMembers),
        loaded: loaded,
        buildID: plan.id
      )
    }
    guard loaded.images.count == 1, let image = loaded.images.first else {
      try throwPostImportFailure(
        ImageBuildError.ambiguousArchive(loaded.images.count),
        loaded: loaded,
        buildID: plan.id
      )
    }
    guard image.reference == artifact.stagingReference else {
      try throwPostImportFailure(
        ImageBuildError.workerArtifactMismatch,
        loaded: loaded,
        buildID: plan.id
      )
    }

    var appliedTags: [String] = []
    do {
      for platform in plan.platforms {
        try Task.checkCancellation()
        await progress(
          ImageBuildProgress(
            phase: .verifyingPlatforms,
            message: "Verifying \(platform.description) snapshot",
            logTail: logTail
          )
        )
        try await imageStore.verifySnapshot(
          reference: image.reference,
          digest: image.digest,
          platform: platform
        )
      }
      try await validateTagState(plan: plan, authorization: authorization)
      for tag in plan.tags {
        try Task.checkCancellation()
        await progress(
          ImageBuildProgress(
            phase: .taggingImage,
            message: "Applying reviewed tag \(tag.reference)",
            logTail: logTail
          )
        )
        try await imageStore.applyTag(
          sourceReference: image.reference,
          sourceDigest: image.digest,
          target: tag
        )
        appliedTags.append(tag.reference)
      }
    } catch {
      throw ImageBuildPartialCompletionError(
        buildID: plan.id,
        imageDigest: image.digest,
        appliedTags: appliedTags,
        failureMessage: error.localizedDescription
      )
    }

    let removed = try? await imageStore.removeReferenceIfUnchanged(
      reference: image.reference,
      digest: image.digest
    )
    let cleanupMessage =
      removed == true
      ? "Image build completed"
      : "Image build completed; the isolated staging tag was retained for review"
    await progress(
      ImageBuildProgress(
        phase: .completed,
        message: cleanupMessage,
        logTail: logTail
      )
    )
    return ImageBuildResult(
      buildID: plan.id,
      imageDigest: image.digest,
      tags: plan.tags.map(\.reference),
      platforms: plan.platforms,
      durationMilliseconds: artifact.durationMilliseconds,
      logTail: logTail
    )
  }

  private func throwPostImportFailure(
    _ error: ImageBuildError,
    loaded: ImageBuildArchiveLoadResult,
    buildID: UUID
  ) throws -> Never {
    guard !loaded.images.isEmpty else { throw error }
    throw ImageBuildImportPartialCompletionError(
      buildID: buildID,
      importedImages: loaded.images.map {
        ImageBuildImportedImageRecord(reference: $0.reference, digest: $0.digest)
      },
      failureMessage: error.localizedDescription
    )
  }

  private func validateTagState(
    plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization
  ) async throws {
    let state = try await imageStore.tagState(for: plan.tags.map(\.reference))
    try ImageBuildExecutionSafety.validate(
      plan: plan,
      authorization: authorization,
      currentDigests: state.currentDigests,
      infrastructureTags: state.infrastructureTags
    )
  }

  private func validateArtifactMetadata(
    _ artifact: ContainerBuildWorkerResult,
    for plan: ImageBuildPlan
  ) throws {
    guard
      artifact.buildID == plan.id,
      artifact.platforms == plan.platforms,
      artifact.stagingReference == Self.stagingReference(for: plan.id),
      artifact.archiveByteCount > 0,
      artifact.archiveSHA256.count == 64,
      artifact.archiveSHA256.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw ImageBuildError.workerArtifactMismatch
    }
  }

  private func cleanup(plan: ImageBuildPlan) async {
    if let secretReviewID = plan.secretReviewID {
      await secretManager.discard(reviewID: secretReviewID)
    }
    try? await contextStager.discard(stagedContext(from: plan))
    await artifactManager.removeArtifacts(buildID: plan.id)
  }

  private func stagedContext(from plan: ImageBuildPlan) -> StagedBuildContext {
    StagedBuildContext(
      id: plan.id,
      contextURL: plan.stagedContextDirectory,
      dockerfileURL: plan.stagedDockerfile,
      dockerfileSHA256: plan.dockerfileSHA256,
      dockerignoreURL: plan.stagedDockerignore,
      dockerignoreSHA256: plan.dockerignoreSHA256,
      fingerprint: plan.contextFingerprint
    )
  }

  private func validate(_ request: ImageBuildRequest) throws {
    if !request.secrets.isEmpty {
      _ = try ImageBuildSecretPolicy.validate(
        request.secrets,
        contextDirectory: request.contextDirectory
      )
    }
    guard !request.tags.isEmpty else { throw ImageBuildError.emptyTags }
    guard !request.platforms.isEmpty else { throw ImageBuildError.emptyPlatforms }
    guard Set(request.platforms).count == request.platforms.count else {
      throw ImageBuildError.duplicatePlatforms
    }
    let supported = Set([ContainerBuildPlatform.current, .amd64])
    if let unsupported = request.platforms.first(where: { !supported.contains($0) }) {
      throw ImageBuildError.unsupportedPlatform(unsupported.description)
    }
    for value in request.buildArguments + request.labels {
      guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
        throw ImageBuildError.invalidKeyValue(value)
      }
    }
    if let cpu = request.builderCPUCount, !(1...32).contains(cpu) {
      throw ImageBuildError.invalidBuilderCPUCount
    }
    if let memory = request.builderMemoryMiB, !(512...131_072).contains(memory) {
      throw ImageBuildError.invalidBuilderMemory
    }
  }

  private func resolvedDockerfile(requested: URL?, context: URL) -> URL {
    if let requested { return requested }
    let dockerfile = context.appending(path: "Dockerfile", directoryHint: .notDirectory)
    if FileManager.default.fileExists(atPath: dockerfile.path(percentEncoded: false)) {
      return dockerfile
    }
    return context.appending(path: "Containerfile", directoryHint: .notDirectory)
  }

  private func dockerignoreSelection(
    dockerfile: URL
  ) -> BuildContextDockerignoreSelection {
    let sibling = dockerfile.appendingPathExtension("dockerignore")
    if FileManager.default.fileExists(atPath: sibling.path(percentEncoded: false)) {
      return .dockerfileSibling
    }
    return .conventional
  }

  private static func stagingReference(for buildID: UUID) -> String {
    let identifier = buildID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return "nativecontainers.local/nativecontainers-build-\(identifier):staging"
  }

  private static func relay(
    _ event: ContainerBuildWorkerEvent,
    logTail: String,
    to progress: @escaping ImageBuildProgressHandler
  ) async {
    guard let phase = buildPhase(for: event) else { return }
    await progress(
      ImageBuildProgress(
        phase: phase,
        message: event.message,
        logTail: logTail
      )
    )
  }

  private static func buildPhase(
    for event: ContainerBuildWorkerEvent
  ) -> ImageBuildProgress.Phase? {
    switch event.kind {
    case .hello:
      nil
    case .builderReady:
      .preparingBuilder
    case .completed:
      .exportingArtifact
    case .failed:
      .exportingArtifact
    case .progress:
      switch event.phase {
      case .validating, .preparingBuilder:
        .preparingBuilder
      case .connectingBuilder:
        .connectingBuilder
      case .building:
        .building
      case .exportingArtifact:
        .exportingArtifact
      case .importingImage:
        .importingImage
      case .taggingImage:
        .taggingImage
      case .completed:
        .completed
      case nil:
        nil
      }
    }
  }

  private static func mergedLogTail(_ values: String...) -> String {
    let joined = values.filter { !$0.isEmpty }.joined(separator: "\n")
    let bytes = Data(joined.utf8)
    guard bytes.count > 1_024 * 1_024 else { return joined }
    return String(decoding: bytes.suffix(1_024 * 1_024), as: UTF8.self)
  }

  private static func standardErrorTail(from error: any Error) -> String {
    guard let processError = error as? ContainerBuildWorkerProcessError else { return "" }
    return switch processError {
    case .workerFailed(_, _, let tail), .nonzeroExit(_, let tail),
      .missingTerminalEvent(_, let tail):
      tail
    default:
      ""
    }
  }
}
