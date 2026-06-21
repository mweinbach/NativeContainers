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
    return ComposeRenderedConfiguration(
      fullConfiguration: data,
      activeConfiguration: data,
      fullConfigurationSHA256: image,
      activeConfigurationSHA256: image,
      composeReleaseVersion: "5.1.4"
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

private actor ComposeRendererDouble: ComposeConfigRendering {
  private var results: [ComposeRenderedConfiguration]
  private(set) var renderCount = 0

  init(results: [ComposeRenderedConfiguration]) {
    self.results = results
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
