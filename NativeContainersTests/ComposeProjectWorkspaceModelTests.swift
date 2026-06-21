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
}

private actor WorkspaceComposeServiceDouble: ComposeProjectLifecycleManaging {
  struct Request: Sendable {
    let directoryURL: URL
    let options: ComposeProjectReviewOptions
  }

  private(set) var requests: [Request] = []

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
        activeServices: [],
        volumes: [],
        networks: []
      ),
      fullConfigurationSHA256: String(repeating: "b", count: 64),
      activeConfigurationSHA256: String(repeating: "c", count: 64),
      composeReleaseVersion: "5.1.4",
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
    throw ComposeProjectLifecycleError.unavailable("Not used by workspace model tests.")
  }
}
