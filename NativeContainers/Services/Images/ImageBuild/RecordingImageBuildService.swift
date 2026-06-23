import Foundation

struct RecordingImageBuildService: ImageBuilding, Sendable {
  private static let maximumDisplayNameBytes = 128

  private let base: any ImageBuilding
  private let history: any ImageBuildHistoryStoring
  private let launchID: UUID
  private let now: @Sendable () -> Date
  private let makeIdentifier: @Sendable () -> UUID

  init(
    base: any ImageBuilding,
    history: any ImageBuildHistoryStoring,
    launchID: UUID,
    now: @escaping @Sendable () -> Date = Date.init,
    makeIdentifier: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.base = base
    self.history = history
    self.launchID = launchID
    self.now = now
    self.makeIdentifier = makeIdentifier
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    try await base.prepareBuild(request, progress: progress)
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    let running = makeRunningRecord(for: plan)
    try? await history.record(running)

    do {
      let result = try await base.build(
        plan,
        authorization: authorization,
        progress: progress
      )
      await recordTerminal(
        running.finishing(
          at: now(),
          status: .succeeded,
          imageDigest: result.imageDigest,
          completedTags: result.tags,
          failureKind: nil
        )
      )
      return result
    } catch let error as CancellationError {
      await recordTerminal(
        running.finishing(
          at: now(),
          status: .cancelled,
          imageDigest: nil,
          completedTags: [],
          failureKind: nil
        )
      )
      throw error
    } catch {
      let details = Self.failureDetails(for: error)
      await recordTerminal(
        running.finishing(
          at: now(),
          status: details.status,
          imageDigest: details.imageDigest,
          completedTags: details.completedTags,
          failureKind: details.failureKind,
          retainedImages: details.retainedImages
        )
      )
      throw error
    }
  }

  func discardBuild(_ plan: ImageBuildPlan) async {
    await base.discardBuild(plan)
  }

  private func recordTerminal(_ record: ImageBuildHistoryRecord) async {
    do {
      try await history.record(record)
    } catch let error as ImageBuildHistoryStoreError
      where error.recordWasCommitted
    {
      return
    } catch {
      try? await history.remove(id: record.id)
    }
  }

  private func makeRunningRecord(for plan: ImageBuildPlan) -> ImageBuildHistoryRecord {
    ImageBuildHistoryRecord(
      id: makeIdentifier(),
      buildID: plan.id,
      launchID: launchID,
      contextDisplayName: Self.contextDisplayName(for: plan.sourceContextDirectory),
      contextFingerprint: plan.contextFingerprint,
      dockerfileSHA256: plan.dockerfileSHA256,
      outputKind: plan.output.kind,
      requestedTags: plan.tags.map(\.reference),
      completedTags: [],
      platforms: plan.platforms,
      buildArgumentKeys: Self.keys(from: plan.buildArguments),
      labelKeys: Self.keys(from: plan.labels),
      targetStage: plan.targetStage,
      startedAt: now(),
      finishedAt: nil,
      durationMilliseconds: nil,
      status: .running,
      imageDigest: nil,
      retainedImages: [],
      failureKind: nil,
      secretCount: plan.secrets.count,
      noCache: plan.noCache,
      cachePolicy: plan.cachePolicy,
      pullLatest: plan.pullLatest
    )
  }

  private static func failureDetails(
    for error: any Error
  ) -> (
    status: ImageBuildHistoryStatus,
    imageDigest: String?,
    completedTags: [String],
    retainedImages: [ImageBuildHistoryRetainedImage],
    failureKind: ImageBuildHistoryFailureKind
  ) {
    if error is ImageBuildOutputPartialCompletionError {
      return (.partiallySucceeded, nil, [], [], .partialExport)
    }
    if let partial = error as? ImageBuildPartialCompletionError {
      return (
        .partiallySucceeded,
        partial.imageDigest,
        partial.appliedTags,
        [],
        .partialFinalization
      )
    }
    if let partial = error as? ImageBuildImportPartialCompletionError {
      return (
        .partiallySucceeded,
        nil,
        [],
        partial.importedImages.map {
          ImageBuildHistoryRetainedImage(
            reference: $0.reference,
            digest: $0.digest
          )
        },
        .partialImport
      )
    }
    if error is ImageBuildSecretError {
      return (.failed, nil, [], [], .secretReview)
    }
    if error is BuildContextStagingError {
      return (.failed, nil, [], [], .context)
    }
    if error is ContainerBuildWorkerProcessError {
      return (.failed, nil, [], [], .builder)
    }
    if let error = error as? ImageBuildOutputError {
      let kind: ImageBuildHistoryFailureKind
      switch error {
      case .destinationRequired, .invalidDestinationName, .unsafeDestinationParent,
        .destinationMustBeNew, .destinationChanged,
        .outputReplacementRequiresConfirmation, .reviewUnavailable:
        kind = .destinationReview
      case .artifactKindMismatch, .publicationFailed:
        kind = .publication
      }
      return (.failed, nil, [], [], kind)
    }
    if let error = error as? ImageBuildError {
      return (.failed, nil, [], [], failureKind(for: error))
    }
    return (.failed, nil, [], [], .unknown)
  }

  private static func failureKind(
    for error: ImageBuildError
  ) -> ImageBuildHistoryFailureKind {
    switch error {
    case .tagReplacementRequiresConfirmation, .infrastructureTag:
      .authorization
    case .stalePlan:
      .staleReview
    case .workerArtifactMismatch, .unsafeArchiveMembers, .ambiguousArchive,
      .missingArtifact, .unsafeArtifact, .stagingReferenceChanged:
      .artifact
    case .secretBuildFailed, .buildSSHRequiresNativeContainersRuntime:
      .builder
    case .emptyTags, .duplicateTags, .archiveReferenceCount, .unexpectedTags,
      .rootFilesystemSinglePlatform, .emptyPlatforms, .duplicatePlatforms,
      .unsupportedPlatform, .invalidKeyValue, .invalidBuilderCPUCount,
      .invalidBuilderMemory, .remoteCacheRequiresCaching,
      .invalidRemoteCacheReference, .remoteCacheMatchesOutput:
      .context
    case .unsupported:
      .builder
    }
  }

  private static func keys(from values: [String]) -> [String] {
    Array(
      Set(
        values.compactMap { value in
          guard let separator = value.firstIndex(of: "=") else { return nil }
          let key = value[..<separator]
          return key.isEmpty ? nil : String(key)
        }
      )
    ).sorted()
  }

  private static func contextDisplayName(for url: URL) -> String {
    let candidate = url.lastPathComponent.unicodeScalars.map { scalar in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = candidate.isEmpty ? "Build Context" : candidate
    guard normalized.utf8.count > maximumDisplayNameBytes else {
      return normalized
    }

    var result = ""
    for scalar in normalized.unicodeScalars {
      let component = String(scalar)
      guard result.utf8.count + component.utf8.count <= maximumDisplayNameBytes else {
        break
      }
      result.append(component)
    }
    return result
  }
}
