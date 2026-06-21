import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Workspace navigation")
struct WorkspaceNavigationTests {
  @Test
  func routesExposeStableBaseIdentities() {
    let machineID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    #expect(WorkspaceRoute.container("api").baseRoute == .containers)
    #expect(
      WorkspaceRoute.composeProject("sample-stack").baseRoute == .composeProjects
    )
    #expect(WorkspaceRoute.image("example/api:latest").baseRoute == .images)
    #expect(WorkspaceRoute.volume("data").baseRoute == .volumes)
    #expect(WorkspaceRoute.network("backend").baseRoute == .networks)
    #expect(WorkspaceRoute.linuxMachine("dev").baseRoute == .linuxMachines)
    #expect(
      WorkspaceRoute.macOSVirtualMachine(machineID).baseRoute == .macOSVirtualMachines
    )
    #expect(
      WorkspaceRoute.macOSVirtualMachine(machineID).stableIdentifier
        == "macos-virtual-machine:01234567-89ab-cdef-0123-456789abcdef"
    )
    #expect(
      WorkspaceRoute.composeProject("sample-stack").stableIdentifier
        == "compose-project:sample-stack"
    )
  }

  @Test
  func catalogRanksExactTitleBeforePrefixAndSearchTermMatches() {
    let catalog = WorkspaceResourceCatalog()
    let entries = [
      WorkspaceResourceEntry(
        route: .container("term-match"),
        kind: .container,
        title: "worker",
        subtitle: "example/worker:latest",
        searchTerms: ["api"]
      ),
      WorkspaceResourceEntry(
        route: .container("prefix-match"),
        kind: .container,
        title: "api-worker",
        subtitle: "example/api-worker:latest",
        searchTerms: []
      ),
      WorkspaceResourceEntry(
        route: .container("exact-match"),
        kind: .container,
        title: "API",
        subtitle: "example/api:latest",
        searchTerms: []
      ),
    ]

    let results = catalog.search("api", in: entries, limit: 10)

    #expect(
      results.map(\.route) == [
        .container("exact-match"),
        .container("prefix-match"),
        .container("term-match"),
      ]
    )
  }

  @Test
  func catalogRequiresEveryNormalizedSearchToken() {
    let catalog = WorkspaceResourceCatalog()
    let armContainer = makeContainer(
      id: "api",
      imageReference: "ghcr.io/example/service:latest",
      platform: "linux/arm64"
    )
    let intelContainer = makeContainer(
      id: "api-intel",
      imageReference: "ghcr.io/example/service:latest",
      platform: "linux/amd64"
    )
    let entries = catalog.entries(
      from: WorkspaceResourceSnapshot(containers: [intelContainer, armContainer])
    )

    let results = catalog.search("EXAMPLE arm64", in: entries, limit: 10)

    #expect(results.map(\.route) == [.container("api")])
    #expect(
      catalog.search("arm64 missing-token", in: entries, limit: 10).isEmpty
    )
  }

  @Test
  func catalogIndexesLocalizedResourceKindTitles() {
    let catalog = WorkspaceResourceCatalog(
      locale: Locale(identifier: "fr_FR"),
      localizedKindTitles: [.container: "Conteneur"]
    )
    let entries = catalog.entries(
      from: WorkspaceResourceSnapshot(containers: [makeContainer(id: "api")])
    )

    #expect(catalog.search("conteneur", in: entries, limit: 10).map(\.route) == [.container("api")])
  }

  @Test
  func catalogDistinguishesGUIVirtualMachineGuests() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 32 * VirtualMachineResources.bytesPerGiB
    )
    let mac = try VirtualMachineManifest(
      name: "macOS",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    let linux = try VirtualMachineManifest(
      name: "Fedora",
      guest: .linux,
      installState: .stopped,
      resources: resources
    )

    let entries = WorkspaceResourceCatalog().entries(
      from: WorkspaceResourceSnapshot(macOSVirtualMachines: [mac, linux])
    )

    #expect(
      entries.first { $0.route == .macOSVirtualMachine(mac.id) }?.kind == .macOSVirtualMachine)
    #expect(
      entries.first { $0.route == .macOSVirtualMachine(linux.id) }?.kind
        == .linuxVirtualMachine
    )
  }

  @Test
  func catalogIndexesComposeProjectsAndCanonicalContainerLabels() throws {
    let fixture = try makeFixture()
    let catalog = WorkspaceResourceCatalog()
    let entries = catalog.entries(from: fixture.snapshot)

    let projectResults = catalog.search("sample-stack", in: entries, limit: 10)
    let serviceResults = catalog.search("api-service", in: entries, limit: 10)

    #expect(projectResults.first?.route == .composeProject("sample-stack"))
    #expect(projectResults.contains(where: { $0.route == .container("api") }))
    #expect(serviceResults.contains(where: { $0.route == .composeProject("sample-stack") }))
    #expect(serviceResults.contains(where: { $0.route == .container("api") }))
  }

  @Test
  func catalogDedupeIsStableAcrossInputOrdering() {
    let catalog = WorkspaceResourceCatalog()
    let alphabeticWinner = makeVolume(id: "shared", name: "Alpha")
    let laterDuplicate = makeVolume(id: "shared", name: "Zulu")

    let forward = catalog.entries(
      from: WorkspaceResourceSnapshot(volumes: [laterDuplicate, alphabeticWinner])
    )
    let reversed = catalog.entries(
      from: WorkspaceResourceSnapshot(volumes: [alphabeticWinner, laterDuplicate])
    )

    #expect(forward == reversed)
    #expect(forward.count == 1)
    #expect(forward.first?.route == .volume("shared"))
    #expect(forward.first?.title == "Alpha")
    #expect(Set(forward.map(\.id)).count == forward.count)
  }

  @Test
  func navigationRoutesEveryExactResourceAndRejectsMissingResources() throws {
    let fixture = try makeFixture()
    let navigation = WorkspaceNavigationModel(snapshot: fixture.snapshot)

    for route in fixture.resourceRoutes {
      #expect(navigation.navigate(to: route))
      #expect(navigation.route == route)
      #expect(navigation.route.baseRoute == route.baseRoute)
    }

    let retainedRoute = navigation.route
    #expect(!navigation.navigate(to: .container("missing")))
    #expect(navigation.route == retainedRoute)
  }

  @Test
  func navigationReconcilesAStaleResourceToItsBaseRoute() {
    let route = WorkspaceRoute.container("api")
    let navigation = WorkspaceNavigationModel(
      snapshot: WorkspaceResourceSnapshot(containers: [makeContainer(id: "api")])
    )
    #expect(navigation.navigate(to: route))

    navigation.query = "api"
    navigation.update(WorkspaceResourceSnapshot())

    #expect(navigation.route == .containers)
    #expect(navigation.entries.isEmpty)
    #expect(navigation.results.isEmpty)
  }

  @Test
  func navigationReconcilesAStaleComposeProjectToTheComposeWorkspace() throws {
    let fixture = try makeFixture()
    let navigation = WorkspaceNavigationModel(snapshot: fixture.snapshot)
    #expect(navigation.navigate(to: .composeProject("sample-stack")))

    navigation.update(WorkspaceResourceSnapshot())

    #expect(navigation.route == .composeProjects)
  }

  @Test
  func navigationRetainsAnExactRouteWhenRefreshIsNotAuthoritative() {
    let route = WorkspaceRoute.container("api")
    let navigation = WorkspaceNavigationModel(
      snapshot: WorkspaceResourceSnapshot(containers: [makeContainer(id: "api")])
    )
    #expect(navigation.navigate(to: route))

    navigation.update(
      WorkspaceResourceSnapshot(),
      reconcileMissingRoute: false
    )

    #expect(navigation.route == route)
    #expect(navigation.entries.isEmpty)
  }

  @Test
  func appModelRoutesExactResourcesThroughSidebarSelection() throws {
    let fixture = try makeFixture()
    let model = AppModel(
      initialInventory: fixture.inventory,
      initialVirtualMachines: [fixture.macVirtualMachine]
    )

    #expect(model.navigate(to: .container("api")))
    #expect(model.workspaceRoute == .container("api"))
    #expect(model.selection == .containers)

    #expect(model.navigate(to: .composeProject("sample-stack")))
    #expect(model.workspaceRoute == .composeProject("sample-stack"))
    #expect(model.selection == .composeProjects)

    #expect(model.navigate(to: .macOSVirtualMachine(fixture.macVirtualMachine.id)))
    #expect(
      model.workspaceRoute == .macOSVirtualMachine(fixture.macVirtualMachine.id)
    )
    #expect(model.selection == .macOSVirtualMachines)

    let retainedRoute = model.workspaceRoute
    #expect(!model.navigate(to: .network("missing")))
    #expect(model.workspaceRoute == retainedRoute)
  }

  @Test
  func reviewedBuildPlanRefusesAppModelNavigationUntilDiscarded() async throws {
    let fixture = try makeFixture()
    let plan = makeBuildPlan()
    let model = AppModel(
      imageBuildService: NavigationImageBuilder(plan: plan),
      initialInventory: fixture.inventory,
      initialVirtualMachines: [fixture.macVirtualMachine]
    )
    #expect(model.canNavigate(to: .builds))
    #expect(model.canNavigate(to: .containers))
    #expect(model.navigate(to: .builds))

    let buildModel = model.makeImageBuildModel()
    let prepared = await buildModel.prepare(makeBuildRequest())
    #expect(prepared == plan)
    #expect(model.isBuildWorkspaceNavigationLocked)
    #expect(model.canNavigate(to: .builds))
    #expect(!model.canNavigate(to: .containers))

    #expect(!model.navigate(to: .container("api")))
    #expect(model.workspaceRoute == .builds)
    model.selectSidebarDestination(.containers)
    #expect(model.workspaceRoute == .builds)

    await buildModel.discardPlan()
    #expect(!model.isBuildWorkspaceNavigationLocked)
    #expect(model.canNavigate(to: .container("api")))
    #expect(model.navigate(to: .container("api")))
    #expect(model.workspaceRoute == .container("api"))
  }
}

private struct WorkspaceNavigationFixture {
  let inventory: ContainerInventory
  let macVirtualMachine: VirtualMachineManifest

  var snapshot: WorkspaceResourceSnapshot {
    WorkspaceResourceSnapshot(
      composeProjects: ComposeTopologyService().derive(from: inventory).projects,
      containers: inventory.containers,
      images: inventory.images,
      volumes: inventory.volumes,
      networks: inventory.networks,
      linuxMachines: inventory.machines,
      macOSVirtualMachines: [macVirtualMachine]
    )
  }

  var resourceRoutes: [WorkspaceRoute] {
    [
      .container("api"),
      .composeProject("sample-stack"),
      .image("ghcr.io/example/api:latest"),
      .volume("data"),
      .network("backend"),
      .linuxMachine("dev"),
      .macOSVirtualMachine(macVirtualMachine.id),
    ]
  }
}

private func makeFixture() throws -> WorkspaceNavigationFixture {
  let machineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  let macVirtualMachine = try VirtualMachineManifest(
    id: machineID,
    name: "macOS Development",
    guest: .macOS,
    installState: .stopped,
    resources: resources,
    createdAt: Date(timeIntervalSince1970: 10)
  )
  let inventory = makeInventory(
    containers: [
      makeContainer(
        id: "api",
        labels: [
          ComposeLabelKey.project: "sample-stack",
          ComposeLabelKey.service: "api-service",
        ]
      )
    ],
    images: [
      ImageRecord(
        reference: "ghcr.io/example/api:latest",
        digest: "sha256:api",
        mediaType: "application/vnd.oci.image.index.v1+json",
        indexSizeBytes: 1_024
      )
    ],
    volumes: [makeVolume(id: "data", name: "data", project: "sample-stack")],
    networks: [makeNetwork(id: "backend", project: "sample-stack")],
    machines: [makeLinuxMachine(id: "dev")]
  )
  return WorkspaceNavigationFixture(
    inventory: inventory,
    macVirtualMachine: macVirtualMachine
  )
}

private func makeInventory(
  containers: [ContainerRecord] = [],
  images: [ImageRecord] = [],
  volumes: [VolumeRecord] = [],
  networks: [NetworkRecord] = [],
  machines: [LinuxMachineRecord] = []
) -> ContainerInventory {
  ContainerInventory(
    system: ContainerSystemInfo(
      version: "1.0.0",
      build: "tests",
      commit: "workspace-navigation",
      applicationRoot: URL(filePath: "/tmp/nativecontainers-navigation"),
      installRoot: URL(filePath: "/usr/local")
    ),
    containers: containers,
    images: images,
    volumes: volumes,
    networks: networks,
    machines: machines
  )
}

private func makeContainer(
  id: String,
  imageReference: String = "ghcr.io/example/api:latest",
  platform: String = "linux/arm64",
  labels: [String: String] = [:]
) -> ContainerRecord {
  ContainerRecord(
    id: id,
    imageReference: imageReference,
    platform: platform,
    state: .running,
    ipAddress: "192.168.64.3/24",
    createdAt: Date(timeIntervalSince1970: 1),
    startedAt: Date(timeIntervalSince1970: 2),
    cpuCount: 2,
    memoryBytes: VirtualMachineResources.bytesPerGiB,
    ports: [],
    labels: labels
  )
}

private func makeVolume(id: String, name: String, project: String? = nil) -> VolumeRecord {
  var labels: [String: String] = [:]
  if let project {
    labels[ComposeLabelKey.project] = project
    labels[ComposeLabelKey.volume] = name
  }
  return VolumeRecord(
    id: id,
    name: name,
    driver: "local",
    format: "ext4",
    source: "/tmp/\(id)",
    createdAt: Date(timeIntervalSince1970: 1),
    sizeBytes: 8 * VirtualMachineResources.bytesPerGiB,
    allocatedBytes: 1_024,
    labels: labels,
    options: [:],
    isAnonymous: false,
    usedByContainerIDs: []
  )
}

private func makeNetwork(id: String, project: String? = nil) -> NetworkRecord {
  var labels: [String: String] = [:]
  if let project {
    labels[ComposeLabelKey.project] = project
    labels[ComposeLabelKey.network] = id
  }
  return NetworkRecord(
    id: id,
    name: id,
    mode: .nat,
    createdAt: Date(timeIntervalSince1970: 1),
    configuredIPv4Subnet: nil,
    configuredIPv6Subnet: nil,
    assignedIPv4Subnet: "192.168.100.0/24",
    ipv4Gateway: "192.168.100.1",
    assignedIPv6Subnet: nil,
    labels: labels,
    plugin: "container-network-vmnet",
    options: [:],
    isBuiltin: false,
    usedByContainerIDs: []
  )
}

private func makeLinuxMachine(id: String) -> LinuxMachineRecord {
  LinuxMachineRecord(
    id: id,
    imageReference: "ubuntu:24.04",
    platform: "linux/arm64",
    state: .stopped,
    ipAddress: nil,
    createdAt: Date(timeIntervalSince1970: 1),
    startedAt: nil,
    diskSizeBytes: 32 * VirtualMachineResources.bytesPerGiB,
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    homeMount: .none,
    isInitialized: true
  )
}

private struct NavigationImageBuilder: ImageBuilding {
  let plan: ImageBuildPlan

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    plan
  }
}

private func makeBuildRequest() -> ImageBuildRequest {
  ImageBuildRequest(
    contextDirectory: URL(
      filePath: "/tmp/nativecontainers-navigation-source",
      directoryHint: .isDirectory
    ),
    dockerfile: nil,
    secrets: [],
    tags: ["example/navigation:latest"],
    platforms: [.current],
    buildArguments: [],
    labels: [],
    targetStage: "",
    cachePolicy: .builderInternal,
    pullLatest: true,
    builderCPUCount: nil,
    builderMemoryMiB: nil
  )
}

private func makeBuildPlan() -> ImageBuildPlan {
  let id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
  let source = URL(
    filePath: "/tmp/nativecontainers-navigation-source",
    directoryHint: .isDirectory
  )
  let staged = URL(
    filePath: "/tmp/nativecontainers-navigation-stage",
    directoryHint: .isDirectory
  )
  return ImageBuildPlan(
    id: id,
    sourceContextDirectory: source,
    stagedContextDirectory: staged,
    stagedDockerfile: staged.appending(path: "Dockerfile", directoryHint: .notDirectory),
    dockerfileSHA256: String(repeating: "a", count: 64),
    stagedDockerignore: nil,
    dockerignoreSHA256: nil,
    contextFingerprint: String(repeating: "b", count: 64),
    secretReviewID: nil,
    secrets: [],
    tags: [
      ContainerBuildTagExpectation(
        reference: "example/navigation:latest",
        existingDigest: nil
      )
    ],
    platforms: [.current],
    buildArguments: [],
    labels: [],
    targetStage: "",
    cachePolicy: .builderInternal,
    pullLatest: true,
    builderCPUCount: nil,
    builderMemoryMiB: nil,
    output: .imageStore,
    generatedAt: Date(timeIntervalSince1970: 1)
  )
}
