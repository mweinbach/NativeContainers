import CryptoKit
import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose project lifecycle coordinator")
struct ComposeProjectLifecycleServiceTests {
  @Test
  func reviewRequiresTwoStableRendersAndReleasesSourceLease() async throws {
    let source = ComposeSourceAccessDouble()
    let rendered = canonicalRendered(image: "nginx:1.27")
    let renderer = ComposeRendererDouble(results: [rendered, rendered])
    let inventory = ComposeInventoryDouble(inventory: emptyInventory)
    let service = ComposeProjectLifecycleService(
      sourceAccess: source,
      configRenderer: renderer,
      inventory: inventory
    )

    let plan = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
    )

    #expect(plan.desiredState.activeServiceNames == ["web"])
    #expect(plan.fullConfigurationSHA256 == rendered.fullConfigurationSHA256)
    #expect(await source.revalidationCount == 3)
    #expect(await source.releaseCount == 1)
    #expect(await renderer.renderCount == 2)
    #expect(await inventory.loadCount == 1)
  }

  @Test
  func reviewRejectsCanonicalDriftBeforeLoadingRuntimeInventory() async {
    let source = ComposeSourceAccessDouble()
    let renderer = ComposeRendererDouble(results: [
      canonicalRendered(image: "nginx:1.27"),
      canonicalRendered(image: "nginx:1.28"),
    ])
    let inventory = ComposeInventoryDouble(inventory: emptyInventory)
    let service = ComposeProjectLifecycleService(
      sourceAccess: source,
      configRenderer: renderer,
      inventory: inventory
    )

    await #expect(throws: ComposeProjectLifecycleError.configChangedDuringReview) {
      _ = try await service.review(
        directoryURL: URL(filePath: "/tmp/demo"),
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
      )
    }

    #expect(await source.releaseCount == 1)
    #expect(await inventory.loadCount == 0)
  }

  @Test
  func executeRemainsFailClosedBehindExplicitPolicyBoundary() async {
    let service = ComposeProjectLifecycleService(
      configRenderer: ComposeRendererDouble(results: []),
      inventory: ComposeInventoryDouble(inventory: emptyInventory)
    )

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await service.execute(
        ComposeLifecyclePlanner().plan(
          source: sourceSummary,
          rendered: canonicalRendered(image: "nginx:1.27"),
          review: ComposeDesiredStateReview(
            desiredState: ComposeDesiredState(
              projectName: "demo",
              declaredServiceNames: [],
              serviceDependencies: [:],
              activeServices: [],
              volumes: [],
              networks: []
            ),
            issues: []
          ),
          options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
          inventory: emptyInventory
        )
      )
    }
  }

  @Test
  func executeConsumesOpaqueReviewRevalidatesEveryBoundaryAndDiscardsFinishedJournal() async throws
  {
    let source = ComposeSourceAccessDouble()
    let rendered = canonicalRendered(image: "nginx:1.27")
    let renderer = ComposeRendererDouble(results: [rendered, rendered, rendered, rendered])
    let inventory = ComposeInventoryDouble(inventory: emptyInventory)
    let executionTool = ComposeExecutionToolDouble(
      environment: renderer.commandEnvironment
    )
    let executor = LifecycleMutationExecutorDouble()
    let journal = LifecycleJournalDouble()
    let service = ComposeProjectLifecycleService(
      sourceAccess: source,
      configRenderer: renderer,
      inventory: inventory,
      executionTool: executionTool,
      mutationExecutor: executor,
      journal: journal
    )
    let plan = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: ComposeProjectReviewOptions(
        action: .up,
        projectName: "demo",
        pullPolicy: .missing
      )
    )
    #expect(plan.canExecute)

    let result = try await service.execute(plan)

    #expect(result.action == .up)
    #expect(await renderer.renderCount == 4)
    #expect(await inventory.loadCount == 2)
    #expect(await source.revalidationCount == 6)
    #expect(await source.releaseCount == 2)
    #expect(await executionTool.resolveCount == 1)
    #expect(await executor.requests.count == 1)
    #expect(await journal.persistedOperationIDs.count == 1)
    #expect(await journal.discardedOperationIDs == journal.persistedOperationIDs)

    await #expect(throws: ComposeProjectLifecycleError.stalePlan) {
      _ = try await service.execute(plan)
    }
    #expect(await executor.requests.count == 1)
  }

  @Test
  func executionDriftFailsBeforeJournalOrMutationAuthorityIsGranted() async throws {
    let source = ComposeSourceAccessDouble()
    let reviewed = canonicalRendered(image: "nginx:1.27")
    let changed = canonicalRendered(image: "nginx:1.28")
    let renderer = ComposeRendererDouble(results: [reviewed, reviewed, changed, changed])
    let inventory = ComposeInventoryDouble(inventory: emptyInventory)
    let executor = LifecycleMutationExecutorDouble()
    let journal = LifecycleJournalDouble()
    let service = ComposeProjectLifecycleService(
      sourceAccess: source,
      configRenderer: renderer,
      inventory: inventory,
      executionTool: ComposeExecutionToolDouble(
        environment: renderer.commandEnvironment
      ),
      mutationExecutor: executor,
      journal: journal
    )
    let plan = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: ComposeProjectReviewOptions(
        action: .up,
        projectName: "demo",
        pullPolicy: .missing
      )
    )

    await #expect(throws: ComposeProjectLifecycleError.stalePlan) {
      _ = try await service.execute(plan)
    }

    #expect(await executor.requests.isEmpty)
    #expect(await journal.persistedOperationIDs.isEmpty)
  }

  @Test
  func reviewStoresExactHashesFromTheFinalSealedInputOverlay() async throws {
    let data = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let rendered = ComposeRenderedConfiguration(
      fullConfiguration: data,
      activeConfiguration: data,
      fullConfigurationSHA256: digest,
      activeConfigurationSHA256: digest,
      composeReleaseVersion: "5.1.4",
      composeBinarySHA256: String(repeating: "b", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: ComposeCommandEnvironment(processEnvironment: [:]).sha256,
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)]
    )
    let exactHashes = [
      ["web": String(repeating: "e", count: 64)],
      ["web": String(repeating: "f", count: 64)],
    ]
    let renderer = ComposeRendererDouble(
      results: Array(repeating: rendered, count: 8),
      executionHashes: exactHashes
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-lifecycle-hash-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ComposeProjectLifecycleService(
      sourceAccess: ComposeSourceAccessDouble(),
      configRenderer: renderer,
      desiredStateDecoder: ComposeDesiredStateDecoder(
        allowsBlockedLocalInputExecutionForTesting: true
      ),
      inputVault: ComposeProjectInputVault(
        sealer: HMACComposeInputSealer(keyData: Data(repeating: 15, count: 32))
      ),
      executionWorkspace: FileComposeExecutionWorkspace(rootURL: root),
      inventory: ComposeInventoryDouble(inventory: emptyInventory)
    )
    let options = ComposeProjectReviewOptions(
      action: .up,
      projectName: "demo",
      pullPolicy: .missing
    )

    let firstRequirements = try await service.discoverInputRequirements(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options
    )
    let first = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options,
      inputs: ComposeProjectReviewInputs(
        requirementsID: firstRequirements.id,
        environmentValues: ["DEMO_TOKEN": "first-value"]
      )
    )
    let secondRequirements = try await service.discoverInputRequirements(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options
    )
    let second = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options,
      inputs: ComposeProjectReviewInputs(
        requirementsID: secondRequirements.id,
        environmentValues: ["DEMO_TOKEN": "second-value"]
      )
    )

    #expect(first.executionServiceConfigurationHashes == exactHashes[0])
    #expect(second.executionServiceConfigurationHashes == exactHashes[1])
    #expect(
      first.desiredState.activeServices.first?.inputSeal
        != second.desiredState.activeServices.first?.inputSeal)
    let configurations = await renderer.hashedConfigurations
    #expect(configurations.count == 2)
    let firstConfiguration = try #require(configurations.first)
    let secondConfiguration = try #require(configurations.last)
    #expect(firstConfiguration != secondConfiguration)
    #expect(!configurations.joined().contains("first-value"))
    #expect(!configurations.joined().contains("second-value"))
  }

  @Test
  func productionReviewPreparesExecutableSealedInputs() async throws {
    let data = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let rendered = ComposeRenderedConfiguration(
      fullConfiguration: data,
      activeConfiguration: data,
      fullConfigurationSHA256: digest,
      activeConfigurationSHA256: digest,
      composeReleaseVersion: "5.1.4",
      composeBinarySHA256: String(repeating: "b", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: ComposeCommandEnvironment(processEnvironment: [:]).sha256,
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)]
    )
    let executionHash = String(repeating: "c", count: 64)
    let renderer = ComposeRendererDouble(
      results: Array(repeating: rendered, count: 4),
      executionHashes: [["web": executionHash]]
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-lifecycle-blocked-input-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ComposeProjectLifecycleService(
      sourceAccess: ComposeSourceAccessDouble(),
      configRenderer: renderer,
      inputVault: ComposeProjectInputVault(
        sealer: HMACComposeInputSealer(keyData: Data(repeating: 18, count: 32))
      ),
      executionWorkspace: FileComposeExecutionWorkspace(rootURL: root),
      inventory: ComposeInventoryDouble(inventory: emptyInventory)
    )
    let options = ComposeProjectReviewOptions(
      action: .up,
      projectName: "demo",
      pullPolicy: .missing
    )
    let requirements = try await service.discoverInputRequirements(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options
    )
    let plan = try await service.review(
      directoryURL: URL(filePath: "/tmp/demo"),
      options: options,
      inputs: ComposeProjectReviewInputs(
        requirementsID: requirements.id,
        environmentValues: ["DEMO_TOKEN": "reviewed-value"]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.blockers.isEmpty)
    #expect(plan.executionServiceConfigurationHashes == ["web": executionHash])
    #expect(await renderer.hashedConfigurations.count == 1)
    await service.discardReview(planID: plan.id)
  }

  private var emptyInventory: ContainerInventory {
    ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "test",
        commit: "test",
        applicationRoot: URL(filePath: "/tmp/app"),
        installRoot: URL(filePath: "/tmp/install")
      ),
      containers: [],
      images: [],
      volumes: [],
      networks: [],
      machines: []
    )
  }

  private var sourceSummary: ComposeProjectSourceSummary {
    ComposeProjectSourceSummary(
      directoryName: "demo",
      fileName: "compose.yaml",
      fileIdentity: ComposeProjectSourceFileIdentity(
        device: 1,
        inode: 2,
        owner: 501,
        permissions: 0o600,
        byteCount: 12,
        modificationSeconds: 1,
        modificationNanoseconds: 0,
        changeSeconds: 1,
        changeNanoseconds: 0,
        sha256: String(repeating: "a", count: 64)
      )
    )
  }

  private func canonicalRendered(image: String) -> ComposeRenderedConfiguration {
    let data = Data(
      """
      {"name":"demo","services":{"web":{"image":"\(image)"}}}
      """.utf8
    )
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ComposeRenderedConfiguration(
      fullConfiguration: data,
      activeConfiguration: data,
      fullConfigurationSHA256: digest,
      activeConfigurationSHA256: digest,
      composeReleaseVersion: "5.1.4",
      composeBinarySHA256: String(repeating: "b", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: ComposeCommandEnvironment(processEnvironment: [:]).sha256,
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)]
    )
  }
}

private actor ComposeSourceAccessDouble: ComposeProjectSourceAccessing {
  private(set) var revalidationCount = 0
  private(set) var releaseCount = 0

  func acquire(directoryURL: URL) async throws -> ComposeProjectSourceLease {
    ComposeProjectSourceLease(
      id: UUID(),
      directoryURL: directoryURL,
      composeFileURL: directoryURL.appending(path: "compose.yaml"),
      summary: ComposeProjectSourceSummary(
        directoryName: "demo",
        fileName: "compose.yaml",
        fileIdentity: ComposeProjectSourceFileIdentity(
          device: 1,
          inode: 2,
          owner: 501,
          permissions: 0o600,
          byteCount: 12,
          modificationSeconds: 1,
          modificationNanoseconds: 0,
          changeSeconds: 1,
          changeNanoseconds: 0,
          sha256: String(repeating: "a", count: 64)
        )
      )
    )
  }

  func revalidate(_ lease: ComposeProjectSourceLease) async throws {
    revalidationCount += 1
  }

  func release(_ lease: ComposeProjectSourceLease) async {
    releaseCount += 1
  }
}

private actor ComposeRendererDouble: ComposeConfigRendering,
  ComposeExecutionServiceHashRendering
{
  nonisolated let commandEnvironment = ComposeCommandEnvironment(processEnvironment: [:])

  private var results: [ComposeRenderedConfiguration]
  private var executionHashes: [[String: String]]
  private(set) var renderCount = 0
  private(set) var hashedConfigurations: [String] = []

  init(
    results: [ComposeRenderedConfiguration],
    executionHashes: [[String: String]] = []
  ) {
    self.results = results
    self.executionHashes = executionHashes
  }

  func render(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeRenderedConfiguration {
    renderCount += 1
    guard !results.isEmpty else {
      throw ComposeProjectLifecycleError.unavailable("No renderer result.")
    }
    return results.removeFirst()
  }

  func renderExecutionServiceHashes(
    configurationURL: URL,
    projectDirectoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputEnvironment: [String: String]
  ) async throws -> [String: String] {
    hashedConfigurations.append(try String(contentsOf: configurationURL, encoding: .utf8))
    guard !executionHashes.isEmpty else {
      throw ComposeProjectLifecycleError.unavailable("No execution hash result.")
    }
    return executionHashes.removeFirst()
  }
}

private actor ComposeInventoryDouble: ContainerInventoryLoading {
  private let inventory: ContainerInventory
  private(set) var loadCount = 0

  init(inventory: ContainerInventory) {
    self.inventory = inventory
  }

  func loadInventory() async throws -> ContainerInventory {
    loadCount += 1
    return inventory
  }
}

private actor ComposeExecutionToolDouble: ComposeExecutionToolResolving {
  nonisolated let commandEnvironment: ComposeCommandEnvironment
  private(set) var resolveCount = 0

  init(environment: ComposeCommandEnvironment) {
    commandEnvironment = environment
  }

  func verifiedExecutableURL() async throws -> URL {
    resolveCount += 1
    return URL(filePath: "/tmp/verified-docker-compose")
  }
}

private actor LifecycleMutationExecutorDouble: ComposeProjectMutationExecuting {
  private(set) var requests: [ComposeProjectMutationRequest] = []

  func execute(
    _ request: ComposeProjectMutationRequest
  ) async throws -> ComposeProjectExecutionResult {
    requests.append(request)
    return ComposeProjectExecutionResult(
      action: request.plan.options.action,
      projectName: request.plan.options.projectName,
      observedState: nil,
      remainingContainerCount: 1,
      remainingVolumeCount: 0,
      remainingNetworkCount: 1
    )
  }
}

private actor LifecycleJournalDouble: ComposeOperationJournaling {
  private(set) var persistedOperationIDs: [UUID] = []
  private(set) var discardedOperationIDs: [UUID] = []

  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {
    persistedOperationIDs.append(entry.operationID)
  }

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {}

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] { [] }

  func discardPendingAfterReview(operationID: UUID) async throws {
    discardedOperationIDs.append(operationID)
  }
}
