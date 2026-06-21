import Foundation

protocol ImageBuildExecuting: Sendable {
  func execute(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult
}

struct AppleImageBuildExecutionService: ImageBuildExecuting {
  private let contextStager: any BuildContextStaging
  private let secretManager: any ImageBuildSecretManaging
  private let worker: any ContainerBuildWorkerRunning
  private let imageStore: any ImageBuildStoring
  private let artifactManager: any ImageBuildArtifactManaging
  private let outputManager: any ImageBuildOutputManaging
  private let cacheFinalizer: any ImageBuildCacheFinalizing
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    contextStager: any BuildContextStaging,
    secretManager: any ImageBuildSecretManaging,
    worker: any ContainerBuildWorkerRunning,
    imageStore: any ImageBuildStoring,
    artifactManager: any ImageBuildArtifactManaging,
    outputManager: any ImageBuildOutputManaging,
    cacheFinalizer: any ImageBuildCacheFinalizing,
    runtimeMutationCoordinator: RuntimeMutationCoordinator
  ) {
    self.contextStager = contextStager
    self.secretManager = secretManager
    self.worker = worker
    self.imageStore = imageStore
    self.artifactManager = artifactManager
    self.outputManager = outputManager
    self.cacheFinalizer = cacheFinalizer
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func execute(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    try await contextStager.validate(plan.stagedContext)
    if plan.output.kind == .imageStore {
      try await validateTagState(plan: plan, authorization: authorization)
    }
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
        await ImageBuildProgressBridge.relay(event, logTail: "", to: progress)
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
    try await finalizePreparedCache(
      workerResult.cacheReceipt,
      buildID: plan.id,
      progress: progress
    )
    let logTail: String
    if plan.secrets.isEmpty {
      logTail = ImageBuildProgressBridge.mergedLogTail(
        startOutput.standardErrorTail,
        buildOutput.standardErrorTail
      )
    } else {
      guard buildOutput.diagnostics == .suppressed else {
        throw ImageBuildError.secretBuildFailed
      }
      logTail = ContainerBuildWorkerDiagnostics.suppressedMessage
    }

    if plan.output.kind == .imageStore {
      return try await runtimeMutationCoordinator.perform { [self] in
        try await finalizeImageStore(
          workerResult,
          artifactIdentity: artifactIdentity,
          plan: plan,
          authorization: authorization,
          logTail: logTail,
          progress: progress
        )
      }
    }

    await progress(
      ImageBuildProgress(
        phase: .exportingArtifact,
        message: "Committing the reviewed output destination",
        logTail: logTail
      )
    )
    let completion = try await outputManager.publish(
      workerResult,
      artifactIdentity: artifactIdentity,
      plan: plan.output,
      authorization: authorization
    )
    await progress(
      ImageBuildProgress(
        phase: .completed,
        message: "Build output committed",
        logTail: logTail
      )
    )
    return ImageBuildResult(
      buildID: plan.id,
      output: completion,
      platforms: plan.platforms,
      durationMilliseconds: workerResult.durationMilliseconds,
      logTail: logTail
    )
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
      outputKind: plan.output.kind,
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
      cachePolicy: plan.cachePolicy,
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
        await ImageBuildProgressBridge.relay(event, logTail: "", to: progress)
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

  private func finalizeImageStore(
    _ artifact: ContainerBuildWorkerResult,
    artifactIdentity: ImageBuildArtifactIdentity,
    plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    logTail: String,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    guard
      artifact.artifact.kind == .ociArchive,
      case .regularFile = artifactIdentity,
      let stagingReference = artifact.stagingReference
    else {
      throw ImageBuildError.workerArtifactMismatch
    }
    try await validateTagState(plan: plan, authorization: authorization)
    let stagingState = try await imageStore.tagState(for: [stagingReference])
    guard stagingState.currentDigests[stagingReference] == nil else {
      throw ImageBuildError.stagingReferenceChanged(stagingReference)
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
      at: URL(filePath: artifact.artifact.path),
      expectedReference: stagingReference
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
    guard image.reference == stagingReference else {
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
      output: .imageStore(
        digest: image.digest,
        tags: plan.tags.map(\.reference)
      ),
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
    let expectedKind: ContainerBuildWorkerArtifactKind
    switch plan.output.kind {
    case .imageStore, .ociArchive:
      expectedKind = .ociArchive
    case .rootFilesystemArchive:
      expectedKind = .rootFilesystemArchive
    case .rootFilesystemDirectory:
      expectedKind = .rootFilesystemDirectory
    }
    let expectedStagingReference =
      plan.output.kind == .imageStore
      ? ImageBuildProgressBridge.stagingReference(for: plan.id)
      : nil
    let validEntryCount =
      expectedKind == .rootFilesystemDirectory
      ? (artifact.artifact.entryCount.map { $0 >= 0 } ?? false)
      : artifact.artifact.entryCount == nil
    let validByteCount =
      expectedKind == .rootFilesystemDirectory
      ? artifact.artifact.byteCount >= 0
      : artifact.artifact.byteCount > 0
    let validCacheReceipt: Bool
    switch plan.cachePolicy {
    case .disabled, .builderInternal:
      validCacheReceipt = artifact.cacheReceipt == nil
    case .appOwnedLocalV1:
      validCacheReceipt =
        artifact.cacheReceipt.map {
          $0.mode == .appOwnedLocalV1
            && $0.state == .staged
            && $0.schemaVersion == ContainerBuildWorkerCacheReceipt.currentSchemaVersion
            && $0.fingerprintSHA256.count == 64
            && $0.fingerprintSHA256.utf8.allSatisfy({
              (48...57).contains($0) || (97...102).contains($0)
            })
            && $0.byteCount > 0
            && $0.entryCount > 0
        } ?? false
    }

    guard
      artifact.buildID == plan.id,
      artifact.platforms == plan.platforms,
      artifact.stagingReference == expectedStagingReference,
      artifact.artifact.kind == expectedKind,
      !artifact.artifact.path.isEmpty,
      validByteCount,
      validEntryCount,
      validCacheReceipt,
      artifact.artifact.sha256.count == 64,
      artifact.artifact.sha256.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw ImageBuildError.workerArtifactMismatch
    }
  }

  private func finalizePreparedCache(
    _ receipt: ContainerBuildWorkerCacheReceipt?,
    buildID: UUID,
    progress: @escaping ImageBuildProgressHandler
  ) async throws {
    guard let receipt else { return }
    do {
      let snapshot = try await cacheFinalizer.commitPreparedCache(
        receipt,
        buildID: buildID
      )
      await progress(
        ImageBuildProgress(
          phase: .exportingArtifact,
          message: "Updated app-owned cache (\(snapshot.entryCount) entries)",
          logTail: snapshot.maintenanceWarning ?? ""
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await progress(
        ImageBuildProgress(
          phase: .exportingArtifact,
          message:
            "The build output is valid, but the app-owned cache could not be updated. Review Builder & Cache.",
          logTail: ""
        )
      )
    }
  }
}

enum ImageBuildProgressBridge {
  static func stagingReference(for buildID: UUID) -> String {
    let identifier = buildID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return "nativecontainers.local/nativecontainers-build-\(identifier):staging"
  }

  static func relay(
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

  static func mergedLogTail(_ values: String...) -> String {
    let joined = values.filter { !$0.isEmpty }.joined(separator: "\n")
    let bytes = Data(joined.utf8)
    guard bytes.count > 1_024 * 1_024 else { return joined }
    return String(decoding: bytes.suffix(1_024 * 1_024), as: UTF8.self)
  }

  static func standardErrorTail(from error: any Error) -> String {
    guard let processError = error as? ContainerBuildWorkerProcessError else { return "" }
    return switch processError {
    case .workerFailed(_, _, let tail), .nonzeroExit(_, let tail),
      .missingTerminalEvent(_, let tail):
      tail
    default:
      ""
    }
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
}
