import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Compose project workspace model")
struct ComposeProjectWorkspaceModelTests {
  @Test
  func folderSelectionSuggestsVisibleProjectNameAndReviewForwardsIntent() async throws {
    let service = WorkspaceComposeServiceDouble()
    let model = ComposeProjectWorkspaceModel(service: service)
    model.begin()
    model.selectDirectory(URL(filePath: "/tmp/My Project", directoryHint: .isDirectory))
    model.profilesText = "jobs, debug"
    model.pullPolicy = .missing
    model.removeOrphans = true

    #expect(model.projectName == "my-project")
    #expect(model.profiles == ["debug", "jobs"])
    #expect(model.canReview)

    await model.review()

    let request = try #require(await service.requests.first)
    #expect(request.directoryURL.path(percentEncoded: false) == "/tmp/My Project/")
    #expect(request.options.projectName == "my-project")
    #expect(request.options.profiles == ["debug", "jobs"])
    #expect(request.options.pullPolicy == .missing)
    #expect(request.options.removeOrphans)
    #expect(model.plan != nil)
    #expect(model.errorMessage == nil)
  }

  @Test
  func changingReviewedIntentInvalidatesThePlan() async {
    let service = WorkspaceComposeServiceDouble()
    let model = ComposeProjectWorkspaceModel(service: service)
    model.begin()
    model.selectDirectory(URL(filePath: "/tmp/demo", directoryHint: .isDirectory))
    await model.review()
    #expect(model.plan != nil)

    model.profilesText = "jobs"

    #expect(model.plan == nil)
  }

  @Test
  func upIntentCannotRetainRemoveVolumes() {
    let model = ComposeProjectWorkspaceModel(service: WorkspaceComposeServiceDouble())
    model.action = .down
    model.removeVolumes = true

    model.action = .up

    #expect(!model.removeVolumes)
  }

  @Test
  func executableReviewRunsThroughServiceAndRefreshesInventory() async throws {
    let service = WorkspaceComposeServiceDouble()
    let mutationRecorder = WorkspaceMutationRecorder()
    let model = ComposeProjectWorkspaceModel(service: service) {
      mutationRecorder.count += 1
    }
    model.begin()
    model.selectDirectory(URL(filePath: "/tmp/demo", directoryHint: .isDirectory))
    await model.review()
    #expect(model.canExecute)

    await model.execute()

    #expect(model.executionResult?.action == .up)
    #expect(await service.executedPlans.count == 1)
    #expect(mutationRecorder.count == 1)
    #expect(model.errorMessage == nil)
  }

  @Test
  func pendingRecoveryBlocksExecutionUntilExplicitReviewedDiscard() async throws {
    let recovery = workspaceRecoverySnapshot()
    let service = WorkspaceComposeServiceDouble(recoveries: [recovery])
    let model = ComposeProjectWorkspaceModel(service: service)
    model.begin()
    model.selectDirectory(URL(filePath: "/tmp/demo", directoryHint: .isDirectory))
    await model.review()
    await model.loadRecoveries()

    #expect(!model.canExecute)
    #expect(model.pendingRecoveries.map(\.operationID) == [recovery.operationID])

    await model.discardRecoveryAfterReview(operationID: recovery.operationID)

    #expect(model.pendingRecoveries.isEmpty)
    #expect(model.canExecute)
    #expect(await service.discardedOperationIDs == [recovery.operationID])
  }
}

private actor WorkspaceComposeServiceDouble: ComposeProjectLifecycleManaging {
  struct Request: Sendable {
    let directoryURL: URL
    let options: ComposeProjectReviewOptions
  }

  private(set) var requests: [Request] = []
  private(set) var executedPlans: [ComposeProjectPlan] = []
  private(set) var discardedOperationIDs: [UUID] = []
  private var recoveries: [ComposeOperationRecoverySnapshot]

  init(recoveries: [ComposeOperationRecoverySnapshot] = []) {
    self.recoveries = recoveries
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    requests.append(Request(directoryURL: directoryURL, options: options))
    return ComposeProjectPlan(
      id: UUID(),
      generatedAt: Date(),
      options: options,
      source: ComposeProjectSourceSummary(
        directoryName: directoryURL.lastPathComponent,
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
      ),
      desiredState: ComposeDesiredState(
        projectName: options.projectName,
        declaredServiceNames: [],
        serviceDependencies: [:],
        activeServices: [],
        volumes: [],
        networks: []
      ),
      fullConfigurationSHA256: String(repeating: "b", count: 64),
      activeConfigurationSHA256: String(repeating: "c", count: 64),
      composeReleaseVersion: "5.1.4",
      composeBinarySHA256: String(repeating: "d", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: String(repeating: "e", count: 64),
      serviceConfigurationHashes: [:],
      observedIdentity: .empty,
      issues: [],
      affectedContainerIDs: [],
      affectedVolumeNames: [],
      affectedNetworkNames: [],
      orphanContainerIDs: [],
      preservedResourceNames: []
    )
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    executedPlans.append(plan)
    return ComposeProjectExecutionResult(
      action: plan.options.action,
      projectName: plan.options.projectName,
      observedState: nil,
      remainingContainerCount: 1,
      remainingVolumeCount: 0,
      remainingNetworkCount: 1
    )
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] {
    recoveries
  }

  func discardRecoveryAfterReview(operationID: UUID) async throws {
    discardedOperationIDs.append(operationID)
    recoveries.removeAll { $0.operationID == operationID }
  }
}

@MainActor
private final class WorkspaceMutationRecorder {
  var count = 0
}

private func workspaceRecoverySnapshot() -> ComposeOperationRecoverySnapshot {
  ComposeOperationRecoverySnapshot(
    operationID: UUID(),
    planID: UUID(),
    action: .down,
    projectName: "demo",
    preparedAt: Date(timeIntervalSince1970: 1_000),
    sourceFileSHA256: String(repeating: "a", count: 64),
    fullConfigurationSHA256: String(repeating: "b", count: 64),
    activeConfigurationSHA256: String(repeating: "c", count: 64),
    composeBinarySHA256: String(repeating: "d", count: 64),
    composeSourceRevision: "source-revision",
    environmentSHA256: String(repeating: "e", count: 64),
    removeOrphans: false,
    removeVolumes: false,
    affectedContainerCount: 1,
    affectedVolumeCount: 0,
    affectedNetworkCount: 1,
    orphanContainerCount: 0,
    phase: .executing,
    completedContainerIDs: [],
    completedNetworkNames: [],
    completedVolumeNames: []
  )
}
