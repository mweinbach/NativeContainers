import Darwin
import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite(.serialized)
struct ImageBuildServiceTests {
  @Test
  func executionSafetyFailsClosedForReplacementWithoutAuthorization() throws {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")

    #expect(
      throws: ImageBuildError.tagReplacementRequiresConfirmation([
        "registry.example/nativecontainers/app:latest"
      ])
    ) {
      try ImageBuildExecutionSafety.validate(
        plan: plan,
        authorization: .none,
        currentDigests: [
          "registry.example/nativecontainers/app:latest": "sha256:reviewed"
        ],
        infrastructureTags: []
      )
    }

    try ImageBuildExecutionSafety.validate(
      plan: plan,
      authorization: ImageBuildAuthorization(
        allowsTagReplacement: true,
        allowsRecreateStoppedBuilder: false,
        allowsStopRunningBuilder: false
      ),
      currentDigests: [
        "registry.example/nativecontainers/app:latest": "sha256:reviewed"
      ],
      infrastructureTags: []
    )
  }

  @Test
  func executionSafetyRejectsTagDriftAndInfrastructureTags() {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")
    let authorization = ImageBuildAuthorization(
      allowsTagReplacement: true,
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: true
    )

    #expect(
      throws: ImageBuildError.stalePlan(
        "local tag “registry.example/nativecontainers/app:latest”"
      )
    ) {
      try ImageBuildExecutionSafety.validate(
        plan: plan,
        authorization: authorization,
        currentDigests: [
          "registry.example/nativecontainers/app:latest": "sha256:changed"
        ],
        infrastructureTags: []
      )
    }
    #expect(
      throws: ImageBuildError.infrastructureTag(
        "registry.example/nativecontainers/app:latest"
      )
    ) {
      try ImageBuildExecutionSafety.validate(
        plan: plan,
        authorization: authorization,
        currentDigests: [
          "registry.example/nativecontainers/app:latest": "sha256:reviewed"
        ],
        infrastructureTags: ["registry.example/nativecontainers/app:latest"]
      )
    }
  }

  @Test
  func executionSafetyTreatsAnUnexpectedNewTagAsStale() {
    let plan = makeImageBuildPlan(existingDigest: nil)

    #expect(
      throws: ImageBuildError.stalePlan(
        "local tag “registry.example/nativecontainers/app:latest”"
      )
    ) {
      try ImageBuildExecutionSafety.validate(
        plan: plan,
        authorization: .none,
        currentDigests: [
          "registry.example/nativecontainers/app:latest": "sha256:appeared"
        ],
        infrastructureTags: []
      )
    }
  }

  @Test
  func prepareBuildPinsCanonicalTagsAndTheStagedReviewBoundary() async throws {
    let staged = makeStagedBuildContext()
    let contextStager = TestBuildContextStager(staged: staged)
    let imageStore = TestImageBuildStore(
      resolvedTags: [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: "sha256:reviewed"
        )
      ]
    )
    let worker = TestContainerBuildWorker()
    let service = AppleContainerBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: TestImageBuildArtifactManager(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let recorder = ImageBuildProgressRecorder()
    let sourceDirectory = URL(
      filePath: "/tmp/nativecontainers-image-build-tests/prepare/source",
      directoryHint: .isDirectory
    )
    let dockerfile = sourceDirectory.appending(
      path: "Reviewed.Dockerfile",
      directoryHint: .notDirectory
    )
    let request = makeImageBuildRequest(
      contextDirectory: sourceDirectory,
      dockerfile: dockerfile,
      tags: [" nativecontainers/app:latest "],
      platforms: [.current, .amd64],
      buildArguments: ["CONFIGURATION=release"],
      labels: ["org.example.owner=nativecontainers"],
      targetStage: "runtime",
      cachePolicy: .disabled,
      pullLatest: false,
      builderCPUCount: 6,
      builderMemoryMiB: 8_192
    )

    let plan = try await service.prepareBuild(request) { progress in
      await recorder.record(progress)
    }
    let resolvedTags = imageStore.resolvedTags

    #expect(plan.id == staged.id)
    #expect(plan.sourceContextDirectory == request.contextDirectory.standardizedFileURL)
    #expect(plan.stagedContextDirectory == staged.contextURL)
    #expect(plan.stagedDockerfile == staged.dockerfileURL)
    #expect(plan.dockerfileSHA256 == staged.dockerfileSHA256)
    #expect(plan.stagedDockerignore == staged.dockerignoreURL)
    #expect(plan.dockerignoreSHA256 == staged.dockerignoreSHA256)
    #expect(plan.contextFingerprint == staged.fingerprint)
    #expect(plan.tags == resolvedTags)
    #expect(plan.platforms == [.current, .amd64])
    #expect(plan.buildArguments == request.buildArguments)
    #expect(plan.labels == request.labels)
    #expect(plan.targetStage == "runtime")
    #expect(plan.noCache)
    #expect(!plan.pullLatest)
    #expect(plan.builderCPUCount == 6)
    #expect(plan.builderMemoryMiB == 8_192)
    #expect(
      await contextStager.stageCalls == [
        TestBuildContextStageCall(
          sourceDirectory: request.contextDirectory,
          dockerfile: dockerfile,
          dockerignore: .conventional,
          excludingFileIdentities: []
        )
      ]
    )
    #expect(await imageStore.resolvedTagRequests == [[" nativecontainers/app:latest "]])
    #expect(await worker.requests.isEmpty)
    #expect(await recorder.values.map(\.phase) == [.stagingContext])
  }

  @Test
  func prepareBuildRejectsInvalidInputBeforeCallingCollaborators() async {
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext())
    let imageStore = TestImageBuildStore()
    let worker = TestContainerBuildWorker()
    let service = AppleContainerBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: TestImageBuildArtifactManager(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let request = makeImageBuildRequest(tags: [])

    await #expect(throws: ImageBuildError.emptyTags) {
      _ = try await service.prepareBuild(request) { _ in }
    }

    #expect(await contextStager.stageCalls.isEmpty)
    #expect(await imageStore.resolvedTagRequests.isEmpty)
    #expect(await worker.requests.isEmpty)
  }

  @Test
  func successfulBuildRunsReviewedPipelineAndCleansStaging() async throws {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")
    let artifact = makeWorkerResult(for: plan)
    let log = ImageBuildOperationLog()
    let contextStager = TestBuildContextStager(
      staged: makeStagedBuildContext(id: plan.id),
      log: log
    )
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: plan),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [
          ImageBuildStoredImage(
            reference: artifact.stagingReference!,
            digest: "sha256:built"
          )
        ],
        rejectedMembers: []
      ),
      log: log
    )
    let worker = TestContainerBuildWorker(log: log)
    let artifactManager = TestImageBuildArtifactManager(log: log)
    let service = AppleContainerBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager,
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let progress = ImageBuildProgressRecorder()
    let authorization = ImageBuildAuthorization(
      allowsTagReplacement: true,
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: true
    )

    let result = try await service.build(plan, authorization: authorization) { update in
      await progress.record(update)
    }

    #expect(result.buildID == plan.id)
    #expect(result.imageDigest == "sha256:built")
    #expect(result.tags == plan.tags.map(\.reference))
    #expect(result.platforms == plan.platforms)
    #expect(result.durationMilliseconds == artifact.durationMilliseconds)
    #expect(result.logTail == "builder start diagnostic\nbuild diagnostic")
    #expect(await contextStager.validatedContexts == [stagedContext(for: plan)])
    #expect(await contextStager.discardedContexts == [stagedContext(for: plan)])
    #expect(await artifactManager.validations == [TestArtifactValidation(artifact: artifact)])
    #expect(await artifactManager.revalidations == [TestArtifactValidation(artifact: artifact)])
    #expect(await artifactManager.removedBuildIDs == [plan.id])
    #expect(await imageStore.loadedArchives == [URL(filePath: artifact.archivePath)])
    #expect(await imageStore.verifiedPlatforms == plan.platforms)
    #expect(await imageStore.appliedTags == plan.tags)
    #expect(await imageStore.removedReferences == [artifact.stagingReference])

    let requests = await worker.requests
    #expect(requests.count == 2)
    #expect(requests[0].operation == .startBuilder)
    #expect(requests[0].builder.cpuCount == plan.builderCPUCount)
    #expect(requests[0].builder.memoryMiB == plan.builderMemoryMiB)
    #expect(requests[0].builder.allowsRecreateStoppedBuilder)
    #expect(requests[0].builder.allowsStopRunningBuilder)
    #expect(requests[0].build == nil)
    #expect(requests[1].operation == .build)
    #expect(!requests[1].builder.allowsRecreateStoppedBuilder)
    #expect(!requests[1].builder.allowsStopRunningBuilder)
    #expect(requests[1].build?.allowsTagReplacement == true)
    #expect(requests[1].build?.contextFingerprint == plan.contextFingerprint)
    #expect(requests[1].build?.tags == plan.tags)
    #expect(requests[1].build?.platforms == plan.platforms)

    #expect(
      await log.values == [
        "context.validate",
        "store.tagState:\(plan.tags[0].reference)",
        "worker.startBuilder",
        "worker.build",
        "artifact.validate",
        "store.tagState:\(plan.tags[0].reference)",
        "store.tagState:\(artifact.stagingReference!)",
        "artifact.revalidate",
        "store.load",
        "store.verify:\(ContainerBuildPlatform.current.description)",
        "store.tagState:\(plan.tags[0].reference)",
        "store.tag:\(plan.tags[0].reference)",
        "store.remove:\(artifact.stagingReference!)",
        "context.discard",
        "artifact.remove",
      ]
    )
    #expect(await progress.values.map(\.phase).contains(.importingImage))
    #expect(await progress.values.map(\.phase).contains(.verifyingPlatforms))
    #expect(await progress.values.map(\.phase).contains(.taggingImage))
    #expect(await progress.values.last?.phase == .completed)
  }

  @Test
  func ociArchiveBuildRoutesThroughOutputServiceWithoutMutatingImageStore() async throws {
    let staged = makeStagedBuildContext()
    let destination = URL(
      filePath: "/tmp/nativecontainers-output-tests/reviewed-image.oci.tar",
      directoryHint: .notDirectory
    )
    let selection = ImageBuildOutputSelection(
      kind: .ociArchive,
      destinationURL: destination
    )
    let outputPlan = ImageBuildOutputPlan(
      reviewID: UUID(),
      kind: .ociArchive,
      destinationURL: destination,
      existingDestinationIdentity: nil
    )
    let completion = ImageBuildCompletion.ociArchive(
      destination: destination,
      sha256: String(repeating: "a", count: 64),
      byteCount: 4_096
    )
    let artifact = ContainerBuildWorkerResult(
      buildID: staged.id,
      artifact: ContainerBuildWorkerArtifact(
        kind: .ociArchive,
        path: fixedArtifactPath(for: staged.id),
        sha256: String(repeating: "a", count: 64),
        byteCount: 4_096,
        entryCount: nil
      ),
      stagingReference: nil,
      platforms: [.current],
      durationMilliseconds: 1_250
    )
    let contextStager = TestBuildContextStager(staged: staged)
    let imageStore = TestImageBuildStore(
      resolvedTags: [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: "sha256:local"
        )
      ]
    )
    let worker = TestContainerBuildWorker(buildResultOverride: artifact)
    let artifactManager = TestImageBuildArtifactManager()
    let outputManager = TestImageBuildOutputManager(
      preparedPlan: outputPlan,
      completion: completion
    )
    let service = AppleContainerBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager,
      outputManager: outputManager,
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let selectionProgress = ImageBuildProgressRecorder()
    let request = makeImageBuildRequest(output: selection)

    let plan = try await service.prepareBuild(request) { update in
      await selectionProgress.record(update)
    }
    #expect(plan.output == outputPlan)
    #expect(
      plan.tags == [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: nil
        )
      ])
    #expect(await outputManager.preparedSelections == [selection])

    let result = try await service.build(plan, authorization: .none) { update in
      await selectionProgress.record(update)
    }

    #expect(result.output == completion)
    #expect(result.imageDigest == nil)
    #expect(result.tags.isEmpty)
    let requests = await worker.requests
    #expect(requests.count == 2)
    #expect(requests[1].build?.outputKind == .ociArchive)
    #expect(requests[1].build?.tags == plan.tags)
    #expect(await imageStore.tagStateRequests.isEmpty)
    #expect(await imageStore.loadedArchives.isEmpty)
    #expect(await imageStore.verifiedPlatforms.isEmpty)
    #expect(await imageStore.appliedTags.isEmpty)
    #expect(await imageStore.removedReferences.isEmpty)
    #expect(await outputManager.publishedResults == [artifact])
    #expect(await outputManager.publishedIdentities.count == 1)
    #expect(await outputManager.publishedPlans == [outputPlan])
    #expect(await outputManager.publishedAuthorizations == [.none])
    #expect(await outputManager.discardedPlans == [outputPlan])
    #expect(await contextStager.discardedContexts == [staged])
    #expect(await artifactManager.removedBuildIDs == [staged.id])
    #expect(await selectionProgress.values.map(\.phase).contains(.exportingArtifact))
    #expect(await selectionProgress.values.last?.phase == .completed)
  }

  @Test
  func secretBuildStreamsValuesAfterReviewAndSuppressesAllDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-service-secret-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceContext = root.appending(path: "context", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceContext,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let secretURL = root.appending(path: "token.secret", directoryHint: .notDirectory)
    let sentinel = Data("service-secret-sentinel".utf8)
    try sentinel.write(to: secretURL)
    #expect(Darwin.chmod(secretURL.path(percentEncoded: false), 0o600) == 0)

    let staged = makeStagedBuildContext()
    let expectedReview = ImageBuildSecretReview(
      id: "token",
      displayPath: (secretURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
      byteCount: Int64(sentinel.count)
    )
    let expectedPlan = makeImageBuildPlan(id: staged.id, secrets: [expectedReview])
    let contextStager = TestBuildContextStager(staged: staged)
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: expectedPlan),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [
          ImageBuildStoredImage(
            reference: stagingReference(for: staged.id),
            digest: "sha256:built"
          )
        ],
        rejectedMembers: []
      )
    )
    let worker = TestContainerBuildWorker(
      expectedSecretValues: ["token": sentinel]
    )
    let artifactManager = TestImageBuildArtifactManager()
    let service = AppleContainerBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager,
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let progress = ImageBuildProgressRecorder()
    let request = makeImageBuildRequest(
      contextDirectory: sourceContext,
      secrets: [ImageBuildSecretSelection(id: "token", sourceURL: secretURL)]
    )

    let plan = try await service.prepareBuild(request) { update in
      await progress.record(update)
    }
    #expect(plan.secrets == [expectedReview])
    #expect(plan.secrets.map(\.id) == ["token"])

    let result = try await service.build(plan, authorization: .none) { update in
      await progress.record(update)
    }

    #expect(await worker.secretPayloadIDs == [[], ["token"]])
    #expect(await worker.secretPayloadMatchedExpectation == true)
    #expect(await worker.requests.last?.build?.secretIDs == ["token"])
    #expect(
      result.logTail == ContainerBuildWorkerDiagnostics.suppressedMessage
    )
    let retainedText =
      await progress.values.map {
        "\($0.message)\n\($0.logTail)"
      }.joined(separator: "\n") + "\n" + result.logTail
    #expect(!retainedText.contains("service-secret-sentinel"))
    #expect(!retainedText.contains(sentinel.base64EncodedString()))
    #expect(await progress.values.map(\.phase).contains(.stagingSecrets))
  }

  @Test
  func secretSourceIsRevalidatedOnlyAfterBuilderPreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-service-secret-drift-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceContext = root.appending(path: "context", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceContext, withIntermediateDirectories: false)
    let secretURL = root.appending(path: "token.secret", directoryHint: .notDirectory)
    try Data("reviewed".utf8).write(to: secretURL)
    #expect(Darwin.chmod(secretURL.path(percentEncoded: false), 0o600) == 0)

    let staged = makeStagedBuildContext()
    let gate = ImageBuildTestGate()
    let worker = TestContainerBuildWorker(firstStartGate: gate)
    let expectedPlan = makeImageBuildPlan(
      id: staged.id,
      secrets: [
        ImageBuildSecretReview(
          id: "token",
          displayPath: (secretURL.path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath,
          byteCount: 8
        )
      ]
    )
    let service = AppleContainerBuildService(
      contextStager: TestBuildContextStager(staged: staged),
      worker: worker,
      imageStore: TestImageBuildStore(tagStates: matchingTagStates(for: expectedPlan)),
      artifactManager: TestImageBuildArtifactManager(),
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )
    let plan = try await service.prepareBuild(
      makeImageBuildRequest(
        contextDirectory: sourceContext,
        secrets: [ImageBuildSecretSelection(id: "token", sourceURL: secretURL)]
      )
    ) { _ in }

    let task = Task {
      try await service.build(plan, authorization: .none) { _ in }
    }
    await gate.waitUntilEntered()
    try Data("changed!".utf8).write(to: secretURL)
    #expect(Darwin.chmod(secretURL.path(percentEncoded: false), 0o600) == 0)
    await gate.release()

    await #expect(throws: ImageBuildSecretError.sourceChanged("token")) {
      _ = try await task.value
    }
    #expect(await worker.requests.map(\.operation) == [.startBuilder])
  }

  @Test
  func replacementAuthorizationFailsClosedBeforeStartingWorker() async {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: [tagState(for: plan)]
    )
    let worker = TestContainerBuildWorker()
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    await #expect(
      throws: ImageBuildError.tagReplacementRequiresConfirmation(plan.tags.map(\.reference))
    ) {
      _ = try await service.build(plan, authorization: .none) { _ in }
    }

    #expect(await worker.requests.isEmpty)
    #expect(await imageStore.loadedArchives.isEmpty)
    #expect(await contextStager.discardedContexts == [stagedContext(for: plan)])
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func staleTagBeforeBuildFailsBeforeStartingWorker() async {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: [
        ImageBuildTagState(
          currentDigests: [plan.tags[0].reference: "sha256:changed"],
          infrastructureTags: []
        )
      ]
    )
    let worker = TestContainerBuildWorker()
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )
    let authorization = replacementAuthorization()

    await #expect(
      throws: ImageBuildError.stalePlan("local tag “\(plan.tags[0].reference)”")
    ) {
      _ = try await service.build(plan, authorization: authorization) { _ in }
    }

    #expect(await worker.requests.isEmpty)
    #expect(await artifactManager.validations.isEmpty)
    #expect(await imageStore.loadedArchives.isEmpty)
  }

  @Test
  func staleTagBeforeImportFailsAfterBuildWithoutImportingArtifact() async {
    let plan = makeImageBuildPlan(existingDigest: "sha256:reviewed")
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: [
        tagState(for: plan),
        ImageBuildTagState(
          currentDigests: [plan.tags[0].reference: "sha256:changed"],
          infrastructureTags: []
        ),
      ]
    )
    let worker = TestContainerBuildWorker()
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    await #expect(
      throws: ImageBuildError.stalePlan("local tag “\(plan.tags[0].reference)”")
    ) {
      _ = try await service.build(plan, authorization: replacementAuthorization()) { _ in }
    }

    #expect(await worker.requests.map(\.operation) == [.startBuilder, .build])
    #expect(await artifactManager.validations.count == 1)
    #expect(await imageStore.loadedArchives.isEmpty)
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func workerArtifactMetadataMismatchFailsBeforeArtifactOrImageStoreAccess() async {
    let plan = makeImageBuildPlan()
    let mismatched = ContainerBuildWorkerResult(
      buildID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
      archivePath: fixedArtifactPath(for: plan.id),
      archiveSHA256: String(repeating: "a", count: 64),
      archiveByteCount: 4_096,
      stagingReference: stagingReference(for: plan.id),
      platforms: plan.platforms,
      durationMilliseconds: 100
    )
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(tagStates: [tagState(for: plan)])
    let worker = TestContainerBuildWorker(buildResultOverride: mismatched)
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    await #expect(throws: ImageBuildError.workerArtifactMismatch) {
      _ = try await service.build(plan, authorization: .none) { _ in }
    }

    #expect(await artifactManager.validations.isEmpty)
    #expect(await imageStore.loadedArchives.isEmpty)
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func localCachePlanRequiresMatchingStagedReceiptBeforeArtifactAccess() async {
    let plan = makeImageBuildPlan(cachePolicy: .appOwnedLocalV1)
    let missingReceipt = ContainerBuildWorkerResult(
      buildID: plan.id,
      artifact: ContainerBuildWorkerArtifact(
        kind: .ociArchive,
        path: fixedArtifactPath(for: plan.id),
        sha256: String(repeating: "a", count: 64),
        byteCount: 4_096,
        entryCount: nil
      ),
      stagingReference: stagingReference(for: plan.id),
      platforms: plan.platforms,
      durationMilliseconds: 100
    )
    let worker = TestContainerBuildWorker(buildResultOverride: missingReceipt)
    let artifactManager = TestImageBuildArtifactManager()
    let cacheFinalizer = TestImageBuildCacheFinalizer()
    let service = makeBuildService(
      contextStager: TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id)),
      worker: worker,
      imageStore: TestImageBuildStore(tagStates: [tagState(for: plan)]),
      artifactManager: artifactManager,
      cacheFinalizer: cacheFinalizer
    )

    await #expect(throws: ImageBuildError.workerArtifactMismatch) {
      _ = try await service.build(plan, authorization: .none) { _ in }
    }

    #expect(await artifactManager.validations.isEmpty)
    #expect(await cacheFinalizer.committedBuildIDs.isEmpty)
    #expect(await cacheFinalizer.discardedBuildIDs == [plan.id])
  }

  @Test
  func nonlocalCachePlanRejectsUnexpectedLocalCacheReceipt() async {
    let plan = makeImageBuildPlan()
    let unexpectedReceipt = ContainerBuildWorkerResult(
      buildID: plan.id,
      artifact: ContainerBuildWorkerArtifact(
        kind: .ociArchive,
        path: fixedArtifactPath(for: plan.id),
        sha256: String(repeating: "a", count: 64),
        byteCount: 4_096,
        entryCount: nil
      ),
      stagingReference: stagingReference(for: plan.id),
      platforms: plan.platforms,
      durationMilliseconds: 100,
      cacheReceipt: ContainerBuildWorkerCacheReceipt(
        mode: .appOwnedLocalV1,
        handoffToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        fingerprintSHA256: String(repeating: "a", count: 64),
        byteCount: 4_096,
        entryCount: 9
      )
    )
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id)),
      worker: TestContainerBuildWorker(buildResultOverride: unexpectedReceipt),
      imageStore: TestImageBuildStore(tagStates: [tagState(for: plan)]),
      artifactManager: artifactManager
    )

    await #expect(throws: ImageBuildError.workerArtifactMismatch) {
      _ = try await service.build(plan, authorization: .none) { _ in }
    }

    #expect(await artifactManager.validations.isEmpty)
  }

  @Test
  func localCacheFinalizesAfterArtifactValidationAndCleansPreparedStaging() async throws {
    let plan = makeImageBuildPlan(cachePolicy: .appOwnedLocalV1)
    let artifact = makeWorkerResult(for: plan)
    let cacheFinalizer = TestImageBuildCacheFinalizer()
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id)),
      worker: TestContainerBuildWorker(buildResultOverride: artifact),
      imageStore: TestImageBuildStore(
        tagStates: matchingTagStates(for: plan),
        archiveLoadResult: ImageBuildArchiveLoadResult(
          images: [
            ImageBuildStoredImage(
              reference: artifact.stagingReference!,
              digest: "sha256:built"
            )
          ],
          rejectedMembers: []
        )
      ),
      artifactManager: artifactManager,
      cacheFinalizer: cacheFinalizer
    )

    _ = try await service.build(plan, authorization: .none) { _ in }

    #expect(await artifactManager.validations.count == 1)
    #expect(await cacheFinalizer.committedBuildIDs == [plan.id])
    #expect(await cacheFinalizer.discardedBuildIDs == [plan.id])
  }

  @Test
  func stagingValidationFailurePreventsAnyWorkerOperation() async {
    let plan = makeImageBuildPlan()
    let contextStager = TestBuildContextStager(
      staged: makeStagedBuildContext(id: plan.id),
      validationError: .stagedFingerprintMismatch
    )
    let imageStore = TestImageBuildStore()
    let worker = TestContainerBuildWorker()
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    await #expect(throws: BuildContextStagingError.stagedFingerprintMismatch) {
      _ = try await service.build(plan, authorization: .none) { _ in }
    }

    #expect(await worker.requests.isEmpty)
    #expect(await imageStore.tagStateRequests.isEmpty)
    #expect(await contextStager.discardedContexts == [stagedContext(for: plan)])
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func snapshotFailureReportsImportedImageAsPartialCompletion() async {
    let plan = makeImageBuildPlan()
    let artifact = makeWorkerResult(for: plan)
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: plan, includesPostImportValidation: false),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [
          ImageBuildStoredImage(reference: artifact.stagingReference!, digest: "sha256:built")
        ],
        rejectedMembers: []
      ),
      snapshotFailureIndex: 0
    )
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: TestContainerBuildWorker(),
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    do {
      _ = try await service.build(plan, authorization: .none) { _ in }
      Issue.record("Expected an imported-image partial-completion failure.")
    } catch let error as ImageBuildPartialCompletionError {
      #expect(error.buildID == plan.id)
      #expect(error.imageDigest == "sha256:built")
      #expect(error.appliedTags.isEmpty)
      #expect(error.failureMessage == TestImageBuildFailure.snapshotFailure.localizedDescription)
    } catch {
      Issue.record("Expected ImageBuildPartialCompletionError, got \(error).")
    }

    #expect(await imageStore.loadedArchives == [URL(filePath: artifact.archivePath)])
    #expect(await imageStore.appliedTags.isEmpty)
    #expect(await imageStore.removedReferences.isEmpty)
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func rejectedArchiveMembersReportEveryAlreadyImportedImage() async {
    let plan = makeImageBuildPlan()
    let artifact = makeWorkerResult(for: plan)
    let imported = ImageBuildStoredImage(
      reference: artifact.stagingReference!,
      digest: "sha256:built"
    )
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: plan, includesPostImportValidation: false),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [imported],
        rejectedMembers: ["../../unexpected"]
      )
    )
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: TestContainerBuildWorker(),
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    do {
      _ = try await service.build(plan, authorization: .none) { _ in }
      Issue.record("Expected a partial archive-import failure.")
    } catch let error as ImageBuildImportPartialCompletionError {
      #expect(error.buildID == plan.id)
      #expect(
        error.importedImages == [
          ImageBuildImportedImageRecord(
            reference: imported.reference,
            digest: imported.digest
          )
        ]
      )
      #expect(error.failureMessage.contains("../../unexpected"))
    } catch {
      Issue.record("Expected ImageBuildImportPartialCompletionError, got \(error).")
    }

    #expect(await imageStore.verifiedPlatforms.isEmpty)
    #expect(await imageStore.appliedTags.isEmpty)
    #expect(await imageStore.removedReferences.isEmpty)
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func committedArchiveImportWithLostReplyReportsRecoveredPartialState() async {
    let plan = makeImageBuildPlan()
    let artifact = makeWorkerResult(for: plan)
    let recovered = ImageBuildStoredImage(
      reference: artifact.stagingReference!,
      digest: "sha256:built"
    )
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: plan, includesPostImportValidation: false),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [recovered],
        rejectedMembers: [],
        reconciledFailureMessage: "XPC reply was interrupted"
      )
    )
    let service = makeBuildService(
      contextStager: TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id)),
      worker: TestContainerBuildWorker(),
      imageStore: imageStore,
      artifactManager: TestImageBuildArtifactManager()
    )

    do {
      _ = try await service.build(plan, authorization: .none) { _ in }
      Issue.record("Expected a reconciled import partial-completion failure.")
    } catch let error as ImageBuildImportPartialCompletionError {
      #expect(error.buildID == plan.id)
      #expect(
        error.importedImages == [
          ImageBuildImportedImageRecord(
            reference: recovered.reference,
            digest: recovered.digest
          )
        ]
      )
      #expect(error.failureMessage.contains("XPC reply was interrupted"))
    } catch {
      Issue.record("Expected ImageBuildImportPartialCompletionError, got \(error).")
    }

    #expect(await imageStore.verifiedPlatforms.isEmpty)
    #expect(await imageStore.appliedTags.isEmpty)
    #expect(await imageStore.removedReferences.isEmpty)
  }

  @Test
  func tagReconciliationRecognizesPostCommitReplyFailure() {
    #expect(
      ImageBuildTagMutationReconciliation.outcome(
        currentDigest: "sha256:built",
        reviewedDigest: "sha256:old",
        sourceDigest: "sha256:built"
      ) == .applied
    )
    #expect(
      ImageBuildTagMutationReconciliation.outcome(
        currentDigest: "sha256:old",
        reviewedDigest: "sha256:old",
        sourceDigest: "sha256:built"
      ) == .unchanged
    )
    #expect(
      ImageBuildTagMutationReconciliation.outcome(
        currentDigest: "sha256:other",
        reviewedDigest: "sha256:old",
        sourceDigest: "sha256:built"
      ) == .drifted
    )
  }

  @Test
  func laterTagFailureReportsExactlyTheTagsAlreadyApplied() async {
    let plan = makeImageBuildPlan(
      tags: [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: nil
        ),
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:release",
          existingDigest: nil
        ),
      ]
    )
    let artifact = makeWorkerResult(for: plan)
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext(id: plan.id))
    let imageStore = TestImageBuildStore(
      tagStates: matchingTagStates(for: plan),
      archiveLoadResult: ImageBuildArchiveLoadResult(
        images: [
          ImageBuildStoredImage(reference: artifact.stagingReference!, digest: "sha256:built")
        ],
        rejectedMembers: []
      ),
      tagFailureIndex: 1
    )
    let artifactManager = TestImageBuildArtifactManager()
    let service = makeBuildService(
      contextStager: contextStager,
      worker: TestContainerBuildWorker(),
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    do {
      _ = try await service.build(plan, authorization: .none) { _ in }
      Issue.record("Expected a partial tag-completion failure.")
    } catch let error as ImageBuildPartialCompletionError {
      #expect(error.buildID == plan.id)
      #expect(error.imageDigest == "sha256:built")
      #expect(error.appliedTags == [plan.tags[0].reference])
      #expect(error.failureMessage == TestImageBuildFailure.tagFailure.localizedDescription)
    } catch {
      Issue.record("Expected ImageBuildPartialCompletionError, got \(error).")
    }

    #expect(await imageStore.appliedTags == [plan.tags[0]])
    #expect(await imageStore.removedReferences.isEmpty)
    #expect(await artifactManager.removedBuildIDs == [plan.id])
  }

  @Test
  func buildExecutionCoordinatorAllowsOnlyOneBuildPipelineAtATime() async throws {
    let firstPlan = makeImageBuildPlan(
      id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    let secondPlan = makeImageBuildPlan(
      id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )
    let gate = ImageBuildTestGate()
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext())
    let worker = TestContainerBuildWorker(firstStartGate: gate)
    let imageStore = TestImageBuildStore(
      tagStates: [tagState(for: firstPlan), tagState(for: secondPlan)]
    )
    let artifactManager = TestImageBuildArtifactManager(validationError: .artifactRejected)
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    let first = Task {
      try await service.build(firstPlan, authorization: .none) { _ in }
    }
    await gate.waitUntilEntered()
    let second = Task {
      try await service.build(secondPlan, authorization: .none) { _ in }
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(await contextStager.validatedContexts == [stagedContext(for: firstPlan)])
    #expect(await worker.requests.map(\.operation) == [.startBuilder])

    await gate.release()
    _ = try? await first.value
    _ = try? await second.value

    #expect(
      await contextStager.validatedContexts == [
        stagedContext(for: firstPlan), stagedContext(for: secondPlan),
      ]
    )
    #expect(
      await worker.requests.map(\.operation) == [
        .startBuilder, .build, .startBuilder, .build,
      ]
    )
  }

  @Test
  func cancellingQueuedBuildCleansItsReviewedContextWithoutRunningWorker() async throws {
    let firstPlan = makeImageBuildPlan(
      id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    let secondPlan = makeImageBuildPlan(
      id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )
    let gate = ImageBuildTestGate()
    let contextStager = TestBuildContextStager(staged: makeStagedBuildContext())
    let worker = TestContainerBuildWorker(firstStartGate: gate)
    let imageStore = TestImageBuildStore(tagStates: [tagState(for: firstPlan)])
    let artifactManager = TestImageBuildArtifactManager(validationError: .artifactRejected)
    let service = makeBuildService(
      contextStager: contextStager,
      worker: worker,
      imageStore: imageStore,
      artifactManager: artifactManager
    )

    let first = Task {
      try await service.build(firstPlan, authorization: .none) { _ in }
    }
    await gate.waitUntilEntered()
    let second = Task {
      try await service.build(secondPlan, authorization: .none) { _ in }
    }
    try await Task.sleep(for: .milliseconds(50))
    second.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await second.value
    }
    #expect(await worker.requests.map(\.operation) == [.startBuilder])
    #expect(await contextStager.validatedContexts == [stagedContext(for: firstPlan)])
    #expect(await contextStager.discardedContexts == [stagedContext(for: secondPlan)])
    #expect(await artifactManager.removedBuildIDs == [secondPlan.id])

    await gate.release()
    _ = try? await first.value
    #expect(await worker.requests.map(\.operation) == [.startBuilder, .build])
  }

  @Test
  func modelRefreshesInventoryAfterSuccessfulBuild() async {
    let plan = makeImageBuildPlan()
    let expected = makeImageBuildResult(for: plan)
    let service = TestImageBuilding(
      preparedPlan: plan,
      outcome: .success(expected)
    )
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }

    let succeeded = await model.execute(plan, authorization: .none)

    #expect(succeeded)
    #expect(model.result == expected)
    #expect(model.errorMessage == nil)
    #expect(model.progress?.phase == .completed)
    #expect(model.plan == nil)
    #expect(!model.isBuilding)
    #expect(await refreshes.count == 1)
    #expect(await service.buildCalls == [TestImageBuildCall(plan: plan, authorization: .none)])
  }

  @Test
  func modelDoesNotRefreshImageInventoryForFilesystemOutput() async {
    let destination = URL(
      filePath: "/tmp/nativecontainers-output-tests/rootfs.tar",
      directoryHint: .notDirectory
    )
    let outputPlan = ImageBuildOutputPlan(
      reviewID: UUID(),
      kind: .rootFilesystemArchive,
      destinationURL: destination,
      existingDestinationIdentity: nil
    )
    let plan = makeImageBuildPlan(tags: [], output: outputPlan)
    let expected = ImageBuildResult(
      buildID: plan.id,
      output: .rootFilesystemArchive(
        destination: destination,
        sha256: String(repeating: "f", count: 64),
        byteCount: 2_048
      ),
      platforms: plan.platforms,
      durationMilliseconds: 1_250,
      logTail: "native build complete"
    )
    let service = TestImageBuilding(
      preparedPlan: plan,
      outcome: .success(expected)
    )
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }

    let succeeded = await model.execute(plan, authorization: .none)

    #expect(succeeded)
    #expect(model.result == expected)
    #expect(model.plan == nil)
    #expect(await refreshes.count == 0)
  }

  @Test
  func modelRefreshesInventoryAndClearsPlanAfterCancellation() async {
    let plan = makeImageBuildPlan()
    let service = TestImageBuilding(preparedPlan: plan, outcome: .cancelled)
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }
    _ = await model.prepare(makeImageBuildRequest())

    let succeeded = await model.execute(authorization: .none)

    #expect(!succeeded)
    #expect(model.result == nil)
    #expect(model.plan == nil)
    #expect(!model.isBuilding)
    #expect(model.errorMessage?.contains("cancelled") == true)
    #expect(model.errorMessage?.contains("before a final output was promised") == true)
    #expect(await refreshes.count == 1)
  }

  @Test
  func modelRefreshesInventoryAfterOrdinaryBuildFailure() async {
    let plan = makeImageBuildPlan()
    let service = TestImageBuilding(preparedPlan: plan, outcome: .failure(.workerUnavailable))
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }

    let succeeded = await model.execute(plan, authorization: .none)

    #expect(!succeeded)
    #expect(model.result == nil)
    #expect(model.plan == nil)
    #expect(!model.isBuilding)
    #expect(model.errorMessage == TestImageBuildFailure.workerUnavailable.localizedDescription)
    #expect(await refreshes.count == 1)
  }

  @Test
  func modelReportsPartialImportAndAppliedTagsThenRefreshesInventory() async {
    let plan = makeImageBuildPlan(
      tags: [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: nil
        ),
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:release",
          existingDigest: nil
        ),
      ]
    )
    let partial = ImageBuildPartialCompletionError(
      buildID: plan.id,
      imageDigest: "sha256:imported",
      appliedTags: ["registry.example/nativecontainers/app:latest"],
      failureMessage: "release tag changed"
    )
    let service = TestImageBuilding(preparedPlan: plan, outcome: .partial(partial))
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }

    let succeeded = await model.execute(plan, authorization: .none)

    #expect(!succeeded)
    #expect(model.result == nil)
    #expect(model.errorMessage?.contains("sha256:imported") == true)
    #expect(
      model.errorMessage?.contains("registry.example/nativecontainers/app:latest") == true
    )
    #expect(model.errorMessage?.contains("staging reference was retained") == true)
    #expect(await refreshes.count == 1)
  }

  @Test
  func modelReportsPartialArchiveImportThenRefreshesInventory() async {
    let plan = makeImageBuildPlan()
    let partial = ImageBuildImportPartialCompletionError(
      buildID: plan.id,
      importedImages: [
        ImageBuildImportedImageRecord(
          reference: stagingReference(for: plan.id),
          digest: "sha256:imported"
        )
      ],
      failureMessage: "archive validation failed"
    )
    let service = TestImageBuilding(preparedPlan: plan, outcome: .importPartial(partial))
    let refreshes = ImageBuildRefreshRecorder()
    let model = ImageBuildModel(service: service) {
      await refreshes.record()
    }

    let succeeded = await model.execute(plan, authorization: .none)

    #expect(!succeeded)
    #expect(model.result == nil)
    #expect(model.errorMessage?.contains("sha256:imported") == true)
    #expect(model.errorMessage?.contains("inspect these retained references") == true)
    #expect(await refreshes.count == 1)
  }

  @Test
  func modelDiscardsThePreviousReviewedContextBeforePreparingAnother() async {
    let first = makeImageBuildPlan(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    let second = makeImageBuildPlan(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    let service = TestImageBuilding(preparedPlans: [first, second], outcome: .cancelled)
    let model = ImageBuildModel(service: service) {}

    _ = await model.prepare(makeImageBuildRequest())
    let prepared = await model.prepare(makeImageBuildRequest())

    #expect(prepared == second)
    #expect(model.plan == second)
    #expect(await service.discardedPlans == [first])
  }
}

private func makeImageBuildRequest(
  contextDirectory: URL = URL(
    filePath: "/tmp/nativecontainers-source",
    directoryHint: .isDirectory
  ),
  dockerfile: URL? = nil,
  secrets: [ImageBuildSecretSelection] = [],
  tags: [String] = ["registry.example/nativecontainers/app:latest"],
  platforms: [ContainerBuildPlatform] = [.current],
  buildArguments: [String] = [],
  labels: [String] = [],
  targetStage: String = "",
  cachePolicy: ImageBuildCachePolicy = .builderInternal,
  pullLatest: Bool = true,
  builderCPUCount: Int? = nil,
  builderMemoryMiB: Int? = nil,
  output: ImageBuildOutputSelection = .imageStore
) -> ImageBuildRequest {
  ImageBuildRequest(
    contextDirectory: contextDirectory,
    dockerfile: dockerfile,
    secrets: secrets,
    tags: tags,
    platforms: platforms,
    buildArguments: buildArguments,
    labels: labels,
    targetStage: targetStage,
    cachePolicy: cachePolicy,
    pullLatest: pullLatest,
    builderCPUCount: builderCPUCount,
    builderMemoryMiB: builderMemoryMiB,
    output: output
  )
}

private func makeImageBuildPlan(
  id: UUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
  existingDigest: String? = nil,
  tags: [ContainerBuildTagExpectation]? = nil,
  secrets: [ImageBuildSecretReview] = [],
  cachePolicy: ImageBuildCachePolicy = .builderInternal,
  output: ImageBuildOutputPlan = .imageStore
) -> ImageBuildPlan {
  let stagedRoot = URL(
    filePath: "/tmp/nativecontainers-build-tests/\(id.uuidString.lowercased())/context",
    directoryHint: .isDirectory
  )
  return ImageBuildPlan(
    id: id,
    sourceContextDirectory: URL(
      filePath: "/tmp/nativecontainers-source",
      directoryHint: .isDirectory
    ),
    stagedContextDirectory: stagedRoot,
    stagedDockerfile: stagedRoot.appending(path: "Dockerfile", directoryHint: .notDirectory),
    dockerfileSHA256: String(repeating: "a", count: 64),
    stagedDockerignore: stagedRoot.appending(
      path: ".dockerignore",
      directoryHint: .notDirectory
    ),
    dockerignoreSHA256: String(repeating: "b", count: 64),
    contextFingerprint: String(repeating: "c", count: 64),
    secretReviewID: secrets.isEmpty ? nil : id,
    secrets: secrets,
    tags: tags
      ?? [
        ContainerBuildTagExpectation(
          reference: "registry.example/nativecontainers/app:latest",
          existingDigest: existingDigest
        )
      ],
    platforms: [.current],
    buildArguments: ["CONFIGURATION=release"],
    labels: ["org.example.owner=nativecontainers"],
    targetStage: "runtime",
    cachePolicy: cachePolicy,
    pullLatest: true,
    builderCPUCount: 4,
    builderMemoryMiB: 4_096,
    output: output,
    generatedAt: Date(timeIntervalSince1970: 1_000)
  )
}

private func makeStagedBuildContext(
  id: UUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
) -> StagedBuildContext {
  let root = URL(
    filePath: "/tmp/nativecontainers-build-tests/\(id.uuidString.lowercased())/context",
    directoryHint: .isDirectory
  )
  return StagedBuildContext(
    id: id,
    contextURL: root,
    dockerfileURL: root.appending(path: "Dockerfile", directoryHint: .notDirectory),
    dockerfileSHA256: String(repeating: "a", count: 64),
    dockerignoreURL: root.appending(path: ".dockerignore", directoryHint: .notDirectory),
    dockerignoreSHA256: String(repeating: "b", count: 64),
    fingerprint: String(repeating: "c", count: 64)
  )
}

private func makeImageBuildResult(for plan: ImageBuildPlan) -> ImageBuildResult {
  ImageBuildResult(
    buildID: plan.id,
    imageDigest: "sha256:built",
    tags: plan.tags.map(\.reference),
    platforms: plan.platforms,
    durationMilliseconds: 1_250,
    logTail: "native build complete"
  )
}

private func makeBuildService(
  contextStager: TestBuildContextStager,
  worker: TestContainerBuildWorker,
  imageStore: TestImageBuildStore,
  artifactManager: TestImageBuildArtifactManager,
  cacheFinalizer: any ImageBuildCacheFinalizing = TestImageBuildCacheFinalizer(),
  runtimeMutationCoordinator: RuntimeMutationCoordinator = RuntimeMutationCoordinator(),
  buildExecutionCoordinator: RuntimeMutationCoordinator = RuntimeMutationCoordinator()
) -> AppleContainerBuildService {
  AppleContainerBuildService(
    contextStager: contextStager,
    worker: worker,
    imageStore: imageStore,
    artifactManager: artifactManager,
    cacheFinalizer: cacheFinalizer,
    runtimeMutationCoordinator: runtimeMutationCoordinator,
    buildExecutionCoordinator: buildExecutionCoordinator
  )
}

private func replacementAuthorization() -> ImageBuildAuthorization {
  ImageBuildAuthorization(
    allowsTagReplacement: true,
    allowsRecreateStoppedBuilder: false,
    allowsStopRunningBuilder: false
  )
}

private func tagState(for plan: ImageBuildPlan) -> ImageBuildTagState {
  ImageBuildTagState(
    currentDigests: Dictionary(
      uniqueKeysWithValues: plan.tags.compactMap { tag in
        tag.existingDigest.map { (tag.reference, $0) }
      }
    ),
    infrastructureTags: []
  )
}

private func matchingTagStates(
  for plan: ImageBuildPlan,
  includesPostImportValidation: Bool = true
) -> [ImageBuildTagState] {
  var states = [
    tagState(for: plan),
    tagState(for: plan),
    ImageBuildTagState(currentDigests: [:], infrastructureTags: []),
  ]
  if includesPostImportValidation {
    states.append(tagState(for: plan))
  }
  return states
}

private func stagingReference(for buildID: UUID) -> String {
  let identifier = buildID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
  return "nativecontainers.local/nativecontainers-build-\(identifier):staging"
}

private func fixedArtifactPath(for buildID: UUID) -> String {
  "/tmp/nativecontainers-build-artifacts/\(buildID.uuidString.lowercased())/out.tar"
}

private func makeWorkerResult(for plan: ImageBuildPlan) -> ContainerBuildWorkerResult {
  ContainerBuildWorkerResult(
    buildID: plan.id,
    artifact: ContainerBuildWorkerArtifact(
      kind: .ociArchive,
      path: fixedArtifactPath(for: plan.id),
      sha256: String(repeating: "a", count: 64),
      byteCount: 4_096,
      entryCount: nil
    ),
    stagingReference: stagingReference(for: plan.id),
    platforms: plan.platforms,
    durationMilliseconds: 1_250,
    cacheReceipt: cacheReceipt(for: plan.cachePolicy)
  )
}

private func makeWorkerResult(
  for build: ContainerBuildWorkerBuildRequest
) -> ContainerBuildWorkerResult {
  ContainerBuildWorkerResult(
    buildID: build.buildID,
    artifact: ContainerBuildWorkerArtifact(
      kind: .ociArchive,
      path: fixedArtifactPath(for: build.buildID),
      sha256: String(repeating: "a", count: 64),
      byteCount: 4_096,
      entryCount: nil
    ),
    stagingReference: stagingReference(for: build.buildID),
    platforms: build.platforms,
    durationMilliseconds: 1_250,
    cacheReceipt: cacheReceipt(for: build.cachePolicy)
  )
}

private func cacheReceipt(
  for policy: ImageBuildCachePolicy
) -> ContainerBuildWorkerCacheReceipt? {
  guard policy == .appOwnedLocalV1 else { return nil }
  return ContainerBuildWorkerCacheReceipt(
    mode: policy,
    handoffToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
    fingerprintSHA256: String(repeating: "a", count: 64),
    byteCount: 4_096,
    entryCount: 9
  )
}

private func stagedContext(for plan: ImageBuildPlan) -> StagedBuildContext {
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

private struct TestBuildContextStageCall: Equatable, Sendable {
  let sourceDirectory: URL
  let dockerfile: URL?
  let dockerignore: BuildContextDockerignoreSelection
  let excludingFileIdentities: Set<BuildContextExcludedFileIdentity>
}

private actor TestBuildContextStager: BuildContextStaging {
  let staged: StagedBuildContext
  private let validationError: BuildContextStagingError?
  private let log: ImageBuildOperationLog?
  private(set) var stageCalls: [TestBuildContextStageCall] = []
  private(set) var validatedContexts: [StagedBuildContext] = []
  private(set) var discardedContexts: [StagedBuildContext] = []

  init(
    staged: StagedBuildContext,
    validationError: BuildContextStagingError? = nil,
    log: ImageBuildOperationLog? = nil
  ) {
    self.staged = staged
    self.validationError = validationError
    self.log = log
  }

  func stage(
    sourceDirectory: URL,
    dockerfile: URL?,
    dockerignore: BuildContextDockerignoreSelection,
    excludingFileIdentities: Set<BuildContextExcludedFileIdentity>
  ) async throws -> StagedBuildContext {
    stageCalls.append(
      TestBuildContextStageCall(
        sourceDirectory: sourceDirectory,
        dockerfile: dockerfile,
        dockerignore: dockerignore,
        excludingFileIdentities: excludingFileIdentities
      )
    )
    return staged
  }

  func validate(_ context: StagedBuildContext) async throws {
    validatedContexts.append(context)
    await log?.record("context.validate")
    if let validationError { throw validationError }
  }

  func discard(_ context: StagedBuildContext) async throws {
    discardedContexts.append(context)
    await log?.record("context.discard")
  }
}

private actor TestImageBuildStore: ImageBuildStoring {
  let resolvedTags: [ContainerBuildTagExpectation]
  private var tagStates: [ImageBuildTagState]
  private let archiveLoadResult: ImageBuildArchiveLoadResult
  private let snapshotFailureIndex: Int?
  private let tagFailureIndex: Int?
  private let removeResult: Bool
  private let log: ImageBuildOperationLog?
  private(set) var resolvedTagRequests: [[String]] = []
  private(set) var tagStateRequests: [[String]] = []
  private(set) var loadedArchives: [URL] = []
  private(set) var loadedArchiveExpectedReferences: [String] = []
  private(set) var verifiedPlatforms: [ContainerBuildPlatform] = []
  private(set) var appliedTags: [ContainerBuildTagExpectation] = []
  private(set) var removedReferences: [String] = []

  init(
    resolvedTags: [ContainerBuildTagExpectation] = [
      ContainerBuildTagExpectation(
        reference: "registry.example/nativecontainers/app:latest",
        existingDigest: nil
      )
    ],
    tagStates: [ImageBuildTagState] = [],
    archiveLoadResult: ImageBuildArchiveLoadResult = ImageBuildArchiveLoadResult(
      images: [],
      rejectedMembers: []
    ),
    snapshotFailureIndex: Int? = nil,
    tagFailureIndex: Int? = nil,
    removeResult: Bool = true,
    log: ImageBuildOperationLog? = nil
  ) {
    self.resolvedTags = resolvedTags
    self.tagStates = tagStates
    self.archiveLoadResult = archiveLoadResult
    self.snapshotFailureIndex = snapshotFailureIndex
    self.tagFailureIndex = tagFailureIndex
    self.removeResult = removeResult
    self.log = log
  }

  func resolveTagExpectations(
    _ references: [String]
  ) async throws -> [ContainerBuildTagExpectation] {
    resolvedTagRequests.append(references)
    return resolvedTags
  }

  func tagState(for references: [String]) async throws -> ImageBuildTagState {
    tagStateRequests.append(references)
    await log?.record("store.tagState:\(references.joined(separator: ","))")
    guard !tagStates.isEmpty else {
      return ImageBuildTagState(currentDigests: [:], infrastructureTags: [])
    }
    return tagStates.removeFirst()
  }

  func loadArchive(
    at url: URL,
    expectedReference: String
  ) async throws -> ImageBuildArchiveLoadResult {
    loadedArchives.append(url)
    loadedArchiveExpectedReferences.append(expectedReference)
    await log?.record("store.load")
    return archiveLoadResult
  }

  func verifySnapshot(
    reference: String,
    digest: String,
    platform: ContainerBuildPlatform
  ) async throws {
    verifiedPlatforms.append(platform)
    await log?.record("store.verify:\(platform.description)")
    if snapshotFailureIndex == verifiedPlatforms.count - 1 {
      throw TestImageBuildFailure.snapshotFailure
    }
  }

  func applyTag(
    sourceReference: String,
    sourceDigest: String,
    target: ContainerBuildTagExpectation
  ) async throws {
    await log?.record("store.tag:\(target.reference)")
    if tagFailureIndex == appliedTags.count {
      throw TestImageBuildFailure.tagFailure
    }
    appliedTags.append(target)
  }

  func removeReferenceIfUnchanged(reference: String, digest: String) async throws -> Bool {
    removedReferences.append(reference)
    await log?.record("store.remove:\(reference)")
    return removeResult
  }
}

private actor TestImageBuildCacheFinalizer: ImageBuildCacheFinalizing {
  private(set) var committedBuildIDs: [UUID] = []
  private(set) var discardedBuildIDs: [UUID] = []

  func commitPreparedCache(
    _ receipt: ContainerBuildWorkerCacheReceipt,
    buildID: UUID
  ) async throws -> AppOwnedBuildCacheSnapshot {
    committedBuildIDs.append(buildID)
    return AppOwnedBuildCacheSnapshot(
      byteCount: receipt.byteCount,
      entryCount: receipt.entryCount
    )
  }

  func discardPreparedCache(buildID: UUID) async {
    discardedBuildIDs.append(buildID)
  }
}

private actor TestContainerBuildWorker: ContainerBuildWorkerRunning {
  private let buildResultOverride: ContainerBuildWorkerResult?
  private let firstStartGate: ImageBuildTestGate?
  private let log: ImageBuildOperationLog?
  private let expectedSecretValues: [String: Data]?
  private var startCount = 0
  private(set) var requests: [ContainerBuildWorkerRequest] = []
  private(set) var secretPayloadIDs: [[String]] = []
  private(set) var secretPayloadMatchedExpectation: Bool?

  init(
    buildResultOverride: ContainerBuildWorkerResult? = nil,
    firstStartGate: ImageBuildTestGate? = nil,
    log: ImageBuildOperationLog? = nil,
    expectedSecretValues: [String: Data]? = nil
  ) {
    self.buildResultOverride = buildResultOverride
    self.firstStartGate = firstStartGate
    self.log = log
    self.expectedSecretValues = expectedSecretValues
  }

  func run(
    _ request: ContainerBuildWorkerRequest,
    secrets: ContainerBuildSecretSourcePayload,
    onEvent: @escaping ContainerBuildWorkerEventHandler
  ) async throws -> ContainerBuildWorkerProcessOutput {
    requests.append(request)
    secretPayloadIDs.append(secrets.ids)
    let transferredSecrets = try await transfer(secrets)
    await log?.record("worker.\(request.operation.rawValue)")
    switch request.operation {
    case .startBuilder:
      startCount += 1
      if startCount == 1, let firstStartGate {
        await firstStartGate.wait()
      }
      let terminal = ContainerBuildWorkerEvent.builderReady(message: "Builder ready")
      await onEvent(.progress(.preparingBuilder, message: "Preparing builder"))
      await onEvent(terminal)
      return ContainerBuildWorkerProcessOutput(
        events: [.hello(), terminal],
        terminalEvent: terminal,
        result: nil,
        diagnostics: .captured(
          tail: "builder start diagnostic",
          wasTruncated: false
        ),
        exitStatus: 0
      )
    case .build:
      guard let build = request.build else {
        throw TestImageBuildFailure.missingBuildRequest
      }
      guard build.secretIDs == secrets.ids else {
        throw TestImageBuildFailure.missingBuildRequest
      }
      if let expectedSecretValues {
        secretPayloadMatchedExpectation = transferredSecrets == expectedSecretValues
      }
      let result = buildResultOverride ?? makeWorkerResult(for: build)
      let terminal = ContainerBuildWorkerEvent.completed(result)
      await onEvent(.progress(.building, message: "Building image"))
      await onEvent(terminal)
      return ContainerBuildWorkerProcessOutput(
        events: [.hello(), terminal],
        terminalEvent: terminal,
        result: result,
        diagnostics:
          secrets.isEmpty
          ? .captured(tail: "build diagnostic", wasTruncated: false)
          : .suppressed,
        exitStatus: 0
      )
    }
  }

  private func transfer(
    _ source: ContainerBuildSecretSourcePayload
  ) async throws -> [String: Data] {
    let expectedIDs = source.ids
    let pipe = Pipe()
    try ContainerBuildSecretWire.write(
      source,
      to: pipe.fileHandleForWriting.fileDescriptor
    )
    let values = try ContainerBuildSecretWire.read(
      from: pipe.fileHandleForReading.fileDescriptor,
      expectedIDs: expectedIDs
    )
    try? pipe.fileHandleForWriting.close()
    try? pipe.fileHandleForReading.close()

    var transferred: [String: Data] = [:]
    try await values.consume { transferred = $0 }
    return transferred
  }
}

private struct TestArtifactValidation: Equatable, Sendable {
  let artifact: ContainerBuildWorkerResult
}

private actor TestImageBuildArtifactManager: ImageBuildArtifactManaging {
  private let validationError: TestImageBuildFailure?
  private let log: ImageBuildOperationLog?
  private(set) var validations: [TestArtifactValidation] = []
  private(set) var revalidations: [TestArtifactValidation] = []
  private(set) var removedBuildIDs: [UUID] = []

  init(
    validationError: TestImageBuildFailure? = nil,
    log: ImageBuildOperationLog? = nil
  ) {
    self.validationError = validationError
    self.log = log
  }

  func validateArtifact(
    _ artifact: ContainerBuildWorkerResult
  ) async throws -> ImageBuildArtifactIdentity {
    validations.append(TestArtifactValidation(artifact: artifact))
    await log?.record("artifact.validate")
    if let validationError { throw validationError }
    return .regularFile(
      SecureRegularFileIdentity(
        device: 1,
        inode: 2,
        size: artifact.artifact.byteCount,
        permissions: 0o400,
        owner: 501,
        linkCount: 1,
        modificationSeconds: 3,
        modificationNanoseconds: 4
      )
    )
  }

  func revalidateArtifact(
    _ artifact: ContainerBuildWorkerResult,
    expectedIdentity: ImageBuildArtifactIdentity
  ) async throws {
    revalidations.append(TestArtifactValidation(artifact: artifact))
    await log?.record("artifact.revalidate")
    guard case .regularFile(let identity) = expectedIdentity else {
      Issue.record("Expected a regular file artifact")
      return
    }
    #expect(identity.size == artifact.artifact.byteCount)
  }

  func removeArtifacts(buildID: UUID) async {
    removedBuildIDs.append(buildID)
    await log?.record("artifact.remove")
  }
}

private actor TestImageBuildOutputManager: ImageBuildOutputManaging {
  private let preparedPlan: ImageBuildOutputPlan
  private let completion: ImageBuildCompletion
  private(set) var preparedSelections: [ImageBuildOutputSelection] = []
  private(set) var publishedResults: [ContainerBuildWorkerResult] = []
  private(set) var publishedIdentities: [ImageBuildArtifactIdentity] = []
  private(set) var publishedPlans: [ImageBuildOutputPlan] = []
  private(set) var publishedAuthorizations: [ImageBuildAuthorization] = []
  private(set) var discardedPlans: [ImageBuildOutputPlan] = []

  init(
    preparedPlan: ImageBuildOutputPlan,
    completion: ImageBuildCompletion
  ) {
    self.preparedPlan = preparedPlan
    self.completion = completion
  }

  func prepare(_ selection: ImageBuildOutputSelection) async throws -> ImageBuildOutputPlan {
    preparedSelections.append(selection)
    return preparedPlan
  }

  func publish(
    _ result: ContainerBuildWorkerResult,
    artifactIdentity: ImageBuildArtifactIdentity,
    plan: ImageBuildOutputPlan,
    authorization: ImageBuildAuthorization
  ) async throws -> ImageBuildCompletion {
    publishedResults.append(result)
    publishedIdentities.append(artifactIdentity)
    publishedPlans.append(plan)
    publishedAuthorizations.append(authorization)
    return completion
  }

  func discard(_ plan: ImageBuildOutputPlan) async {
    discardedPlans.append(plan)
  }
}

private enum TestImageBuildOutcome: Sendable {
  case success(ImageBuildResult)
  case cancelled
  case failure(TestImageBuildFailure)
  case importPartial(ImageBuildImportPartialCompletionError)
  case partial(ImageBuildPartialCompletionError)
}

private struct TestImageBuildCall: Equatable, Sendable {
  let plan: ImageBuildPlan
  let authorization: ImageBuildAuthorization
}

private actor TestImageBuilding: ImageBuilding {
  private var preparedPlans: [ImageBuildPlan]
  private let outcome: TestImageBuildOutcome
  private(set) var buildCalls: [TestImageBuildCall] = []
  private(set) var discardedPlans: [ImageBuildPlan] = []

  init(preparedPlan: ImageBuildPlan, outcome: TestImageBuildOutcome) {
    self.preparedPlans = [preparedPlan]
    self.outcome = outcome
  }

  init(preparedPlans: [ImageBuildPlan], outcome: TestImageBuildOutcome) {
    self.preparedPlans = preparedPlans
    self.outcome = outcome
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    guard !preparedPlans.isEmpty else { throw TestImageBuildFailure.missingPreparedPlan }
    let plan = preparedPlans.removeFirst()
    await progress(
      ImageBuildProgress(
        phase: .stagingContext,
        message: "Staged reviewed context",
        logTail: ""
      )
    )
    return plan
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    buildCalls.append(TestImageBuildCall(plan: plan, authorization: authorization))
    switch outcome {
    case .success(let result):
      await progress(
        ImageBuildProgress(
          phase: .completed,
          message: "Image build completed",
          logTail: result.logTail
        )
      )
      return result
    case .cancelled:
      throw CancellationError()
    case .failure(let error):
      throw error
    case .importPartial(let error):
      throw error
    case .partial(let error):
      throw error
    }
  }

  func discardBuild(_ plan: ImageBuildPlan) async {
    discardedPlans.append(plan)
  }
}

private enum TestImageBuildFailure: LocalizedError, Equatable, Sendable {
  case artifactRejected
  case missingPreparedPlan
  case missingBuildRequest
  case snapshotFailure
  case tagFailure
  case unexpectedWorkerCall
  case workerUnavailable

  var errorDescription: String? {
    switch self {
    case .artifactRejected:
      "The fixed test artifact was rejected."
    case .missingPreparedPlan:
      "No prepared build plan was available."
    case .missingBuildRequest:
      "The worker build request was missing."
    case .snapshotFailure:
      "The imported snapshot could not be verified."
    case .tagFailure:
      "The reviewed output tag changed."
    case .unexpectedWorkerCall:
      "The build worker was called unexpectedly."
    case .workerUnavailable:
      "The isolated build worker is unavailable."
    }
  }
}

private actor ImageBuildProgressRecorder {
  private(set) var values: [ImageBuildProgress] = []

  func record(_ progress: ImageBuildProgress) {
    values.append(progress)
  }
}

private actor ImageBuildRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private actor ImageBuildOperationLog {
  private(set) var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }
}

private actor ImageBuildTestGate {
  private var entered = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    entered = true
    guard !released else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilEntered() async {
    while !entered {
      await Task.yield()
    }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
