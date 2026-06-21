import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct AppModelTests {
  @Test
  func refreshPublishesContainerAndVirtualMachineInventories() async throws {
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "release",
        commit: "abc123",
        applicationRoot: URL(filePath: "/tmp/data"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [
        ContainerRecord(
          id: "web",
          imageReference: "example/web:latest",
          platform: "linux/arm64",
          state: .running,
          ipAddress: "192.168.64.2/24",
          createdAt: Date(timeIntervalSince1970: 1),
          startedAt: Date(timeIntervalSince1970: 2),
          cpuCount: 2,
          memoryBytes: VirtualMachineResources.bytesPerGiB,
          ports: []
        )
      ],
      images: [],
      volumes: [],
      networks: [
        NetworkRecord(
          id: "default",
          name: "default",
          mode: .nat,
          createdAt: Date(timeIntervalSince1970: 1),
          configuredIPv4Subnet: nil,
          configuredIPv6Subnet: nil,
          assignedIPv4Subnet: "192.168.64.0/24",
          ipv4Gateway: "192.168.64.1",
          assignedIPv6Subnet: nil,
          labels: ["com.apple.container.resource.role": "builtin"],
          plugin: "container-network-vmnet",
          options: [:],
          isBuiltin: true,
          usedByContainerIDs: ["web"]
        )
      ],
      machines: []
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let manifest = try VirtualMachineManifest(name: "macOS", guest: .macOS, resources: resources)
    let containerService = MockContainerService(inventory: inventory)
    let library = MockVirtualMachineLibrary(manifests: [manifest])
    let model = AppModel(containerService: containerService, virtualMachineLibrary: library)

    await model.refresh()

    #expect(model.systemInfo == inventory.system)
    #expect(model.containers == inventory.containers)
    #expect(model.networks == inventory.networks)
    #expect(model.virtualMachines == [manifest])
    #expect(model.errorMessage == nil)
    #expect(model.lastRefresh != nil)
    #expect(!model.isRefreshing)
  }

  @Test
  func successfulMutationRefreshesInventory() async {
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "release",
        commit: "abc123",
        applicationRoot: URL(filePath: "/tmp/data"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [],
      images: [],
      volumes: [],
      networks: [],
      machines: []
    )
    let service = MockContainerService(inventory: inventory)
    let model = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )

    await model.startContainer(id: "web")

    #expect(await service.startedContainerIDs == ["web"])
    #expect(await service.loadCount == 1)
  }

  @Test
  func appServicesRoutesInventoryAndLifecycleThroughDistinctFacets() async {
    let routedInventory = inventoryWithImage(digest: "sha256:routed")
    let inventoryService = MockContainerService(inventory: routedInventory)
    let lifecycleService = MockContainerService(inventory: emptyInventory())
    let model = AppModel(
      services: AppServices(
        inventory: inventoryService,
        containerLifecycle: lifecycleService,
        containerCreator: lifecycleService,
        containerInspector: lifecycleService,
        containerTools: lifecycleService,
        containerTerminal: lifecycleService,
        machineLifecycle: lifecycleService,
        images: lifecycleService,
        volumes: lifecycleService,
        networks: lifecycleService,
        browser: lifecycleService,
        imageBuild: AppleContainerBuildService(),
        registry: AppleRegistryService(),
        virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
        restoreImageDiscovery: MacRestoreImageService(),
        restoreImageDownloader: RestoreImageDownloadService()
      )
    )

    await model.startContainer(id: "web")

    #expect(await lifecycleService.startedContainerIDs == ["web"])
    #expect(await lifecycleService.loadCount == 0)
    #expect(await inventoryService.startedContainerIDs.isEmpty)
    #expect(await inventoryService.loadCount == 1)
    #expect(model.images == routedInventory.images)
  }

  @Test
  func refreshRequestedDuringActivePassRunsAndAwaitsFollowUpPass() async {
    let stale = inventoryWithImage(digest: "sha256:stale")
    let current = inventoryWithImage(digest: "sha256:current")
    let service = MockContainerService(
      inventory: stale,
      subsequentInventories: [current]
    )
    let library = BlockingVirtualMachineLibrary()
    let model = AppModel(containerService: service, virtualMachineLibrary: library)

    let initialRefresh = Task { await model.refresh() }
    await library.waitUntilFirstListStarts()
    #expect(model.images == stale.images)

    let overlappingRefresh = Task { await model.refresh() }
    await Task.yield()
    await library.resumeFirstList()
    await initialRefresh.value
    await overlappingRefresh.value

    #expect(await service.loadCount == 2)
    #expect(model.images == current.images)
    #expect(!model.isRefreshing)
  }

  @Test
  func inspectorLoadsBoundedServiceSnapshot() async {
    let inspection = ContainerInspection(
      diskUsageBytes: 42,
      statistics: ContainerStatistics(
        memoryUsageBytes: 12,
        memoryLimitBytes: 100,
        cpuUsageMicroseconds: 900,
        networkReceivedBytes: 4,
        networkTransmittedBytes: 5,
        blockReadBytes: 6,
        blockWrittenBytes: 7,
        processCount: 2
      ),
      standardOutput: "ready\n",
      bootLog: "booted\n",
      logsAreTruncated: false
    )
    let service = MockContainerService(inventory: emptyInventory(), inspection: inspection)
    let model = ContainerInspectorModel(containerID: "web", allocatedCPUCount: 2, service: service)

    await model.load()

    #expect(model.inspection == inspection)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
    #expect(await service.inspectedContainerIDs == ["web"])
  }

  @Test
  func provisioningCreatesValidatedRequestAndRefreshesInventory() async throws {
    let service = MockContainerService(inventory: emptyInventory())
    let appModel = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )
    let model = appModel.makeContainerProvisioningModel()
    let request = try ContainerCreationRequest(
      operationID: UUID(uuidString: "E8ECF872-F7B9-4B5B-89A4-8B73A6588711")!,
      name: "web-api",
      imageReference: "alpine:latest",
      cpuCount: 2,
      memoryBytes: 512 * ContainerCreationRequest.bytesPerMiB,
      environment: [try ContainerEnvironmentVariable(key: "MODE", value: "test")],
      publishedPorts: [
        try ContainerPortPublication(
          hostAddress: "127.0.0.1",
          hostPort: 8_080,
          containerPort: 80,
          transportProtocol: .tcp
        )
      ]
    )

    let succeeded = await model.createContainer(request)

    #expect(succeeded)
    #expect(model.progress?.phase == .completed)
    #expect(model.errorMessage == nil)
    #expect(await service.createdRequests == [request])
    #expect(await service.loadCount == 1)
  }

  @Test
  func provisioningPullsImageAndRefreshesInventory() async {
    let service = MockContainerService(inventory: emptyInventory())
    let appModel = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )
    let model = appModel.makeContainerProvisioningModel()

    let plan = await model.prepareImagePull(
      reference: "  alpine:latest  ",
      platform: .current,
      transport: .automatic,
      unpackAfterPull: true,
      maxConcurrentDownloads: 3
    )
    let succeeded = await model.pullReviewedImage(plan, authorization: .none)

    #expect(succeeded)
    #expect(model.progress?.phase == .completed)
    #expect(await service.pulledImageReferences == ["alpine:latest"])
    #expect(await service.loadCount == 1)
  }

  @Test
  func failedPullStillRefreshesPotentiallyPartialInventory() async {
    let service = MockContainerService(
      inventory: emptyInventory(),
      pullError: AppModelTestError.transferFailed
    )
    let appModel = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )
    let model = appModel.makeContainerProvisioningModel()
    let plan = await model.prepareImagePull(
      reference: "alpine:latest",
      platform: .current,
      transport: .https,
      unpackAfterPull: true,
      maxConcurrentDownloads: 3
    )

    let succeeded = await model.pullReviewedImage(plan, authorization: .none)

    #expect(!succeeded)
    #expect(model.errorMessage?.contains("transfer failed") == true)
    #expect(await service.loadCount == 1)
  }

  @Test
  func partialPullPublishesCommittedDigestAndClearsStalePlan() async {
    let platform = OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
    let result = ImagePullResult(
      reference: "registry-1.docker.io/library/alpine:latest",
      digest: "sha256:downloaded",
      replacedDigest: "sha256:old",
      unpackOutcome: ImageUnpackOutcome(
        platforms: [
          ImagePlatformUnpackOutcome(
            platform: platform,
            state: .failed("Snapshot service unavailable")
          )
        ]
      )
    )
    let partialError = ImagePullPartialCompletionError(
      result: result,
      stage: .unpacking,
      failureMessage: "linux/arm64/v8: Snapshot service unavailable",
      wasCancelled: false
    )
    let service = MockContainerService(
      inventory: emptyInventory(),
      pullError: partialError
    )
    let appModel = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )
    let model = appModel.makeContainerProvisioningModel()
    let plan = await model.prepareImagePull(
      reference: "alpine:latest",
      platform: .current,
      transport: .https,
      unpackAfterPull: true,
      maxConcurrentDownloads: 3
    )

    let succeeded = await model.pullReviewedImage(plan, authorization: .none)

    #expect(!succeeded)
    #expect(model.pullResult == result)
    #expect(model.pullPlan == nil)
    #expect(model.errorMessage?.contains("now points to sha256:downloaded") == true)
    #expect(await service.loadCount == 1)
  }

  @Test
  func creationRequestRejectsInvalidUserInput() throws {
    #expect(throws: ContainerCreationValidationError.invalidName) {
      try ContainerCreationRequest(name: "!", imageReference: "alpine")
    }
    #expect(throws: ContainerCreationValidationError.invalidEnvironmentKey("BAD KEY")) {
      try ContainerEnvironmentVariable(key: "BAD KEY", value: "value")
    }
    #expect(throws: ContainerCreationValidationError.invalidMemory) {
      try ContainerCreationRequest(
        name: "tiny-memory",
        imageReference: "alpine",
        memoryBytes: 128 * ContainerCreationRequest.bytesPerMiB
      )
    }

    let ipv6 = try ContainerPortPublication(
      hostAddress: "[::1]",
      hostPort: 8_080,
      containerPort: 80,
      transportProtocol: .tcp
    )
    #expect(ipv6.hostAddress == "::1")
    #expect(ipv6.appleSpecification == "[::1]:8080:80/tcp")

    #expect(throws: ContainerCreationValidationError.invalidHostAddress("localhost")) {
      try ContainerPortPublication(
        hostAddress: "localhost",
        hostPort: 8_080,
        containerPort: 80,
        transportProtocol: .tcp
      )
    }
    #expect(throws: ContainerCreationValidationError.invalidPort) {
      try ContainerPortPublication(
        hostAddress: "127.0.0.1",
        hostPort: 1,
        containerPort: 80,
        transportProtocol: .tcp
      )
    }

    let first = try ContainerPortPublication(
      hostAddress: "127.0.0.1",
      hostPort: 8_080,
      containerPort: 80,
      transportProtocol: .tcp
    )
    let overlapping = try ContainerPortPublication(
      hostAddress: "0.0.0.0",
      hostPort: 8_080,
      containerPort: 8_000,
      transportProtocol: .tcp
    )
    #expect(throws: ContainerCreationValidationError.duplicatePortPublication) {
      try ContainerCreationRequest(
        name: "overlapping-ports",
        imageReference: "alpine",
        publishedPorts: [first, overlapping]
      )
    }
  }

  @Test
  func operationProgressPrefersByteFraction() {
    let progress = ContainerOperationProgress(
      phase: .fetchingImage,
      message: "Fetching image",
      completedItems: 9,
      totalItems: 10,
      transferredBytes: 25,
      totalBytes: 100
    )

    #expect(progress.fractionCompleted == 0.25)
  }

  @Test
  func inspectorSamplesStatisticsAndFollowsLogsUntilCancelled() async throws {
    let inspection = ContainerInspection(
      diskUsageBytes: 42,
      statistics: ContainerStatistics(
        memoryUsageBytes: 12,
        memoryLimitBytes: 100,
        cpuUsageMicroseconds: 900,
        networkReceivedBytes: 4,
        networkTransmittedBytes: 5,
        blockReadBytes: 6,
        blockWrittenBytes: 7,
        processCount: 2
      ),
      standardOutput: "ready\n",
      bootLog: "booted\n",
      logsAreTruncated: false
    )
    let service = MockContainerService(inventory: emptyInventory(), inspection: inspection)
    let model = ContainerInspectorModel(containerID: "web", allocatedCPUCount: 2, service: service)
    await model.load()

    let monitoring = Task {
      await model.monitor(followLogs: true, interval: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(30))
    monitoring.cancel()
    await monitoring.value

    #expect(model.samples.count > 1)
    #expect(model.lastUpdated != nil)
    #expect(await service.sampleCount > 0)
    #expect(await service.logLoadCount > 0)
  }

  @Test
  func restartAndForceStopRefreshInventory() async {
    let service = MockContainerService(inventory: emptyInventory())
    let model = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )

    await model.restartContainer(id: "web")
    await model.forceStopContainer(id: "worker")

    #expect(await service.restartedContainerIDs == ["web"])
    #expect(await service.forceStoppedContainerIDs == ["worker"])
    #expect(await service.loadCount == 2)
  }

  @Test
  func failedRuntimeRefreshClearsStaleInventories() async {
    let initial = ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "release",
        commit: "abc123",
        applicationRoot: URL(filePath: "/tmp/data"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [
        ContainerRecord(
          id: "stale",
          imageReference: "example/app:latest",
          platform: "linux/arm64",
          state: .stopped,
          ipAddress: nil,
          createdAt: Date(),
          startedAt: nil,
          cpuCount: 1,
          memoryBytes: 512 * 1_024 * 1_024,
          ports: []
        )
      ],
      images: [
        ImageRecord(
          reference: "example/app:latest",
          digest: "sha256:stale",
          mediaType: "index",
          indexSizeBytes: 512
        )
      ],
      volumes: [],
      networks: [],
      machines: []
    )
    let service = MockContainerService(
      inventory: initial,
      loadError: AppModelTestError.runtimeUnavailable
    )
    let model = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
      initialInventory: initial
    )

    await model.refresh()

    #expect(model.systemInfo == nil)
    #expect(model.containers.isEmpty)
    #expect(model.images.isEmpty)
    #expect(model.errorMessage?.contains("offline") == true)
  }

  @Test
  func toolsModelExecutesCommandAndCopiesBothDirections() async throws {
    let service = MockContainerService(inventory: emptyInventory())
    let model = ContainerToolsModel(containerID: "web", service: service)
    let command = try ContainerCommandRequest(
      executable: "/bin/echo",
      arguments: ["hello"],
      environment: [try ContainerEnvironmentVariable(key: "MODE", value: "test")],
      timeoutSeconds: 5
    )

    await model.execute(command)

    #expect(model.commandResult?.exitCode == 0)
    #expect(model.commandResult?.standardOutput == "ok\n")
    #expect(model.errorMessage == nil)
    #expect(await service.commandRequests == [command])

    let localSource = URL(filePath: "/tmp/source.txt")
    let localDestination = URL(filePath: "/tmp/export")
    let copyIn = try ContainerFileTransferRequest(
      direction: .intoContainer,
      localURL: localSource,
      containerPath: "/tmp/source.txt"
    )
    let copyOut = try ContainerFileTransferRequest(
      direction: .fromContainer,
      localURL: localDestination,
      containerPath: "/tmp/result.txt"
    )

    #expect(await model.transfer(copyIn))
    #expect(await model.transfer(copyOut))
    let copiedIn = await service.copiedIntoContainer
    let copiedOut = await service.copiedFromContainer
    #expect(copiedIn.count == 1)
    #expect(copiedIn.first?.0 == "web")
    #expect(copiedIn.first?.2 == "/tmp/source.txt")
    #expect(copiedOut.count == 1)
    #expect(copiedOut.first?.0 == "web")
    #expect(copiedOut.first?.1 == "/tmp/result.txt")
  }

  @Test
  func containerToolRequestsRejectUnsafeInputs() throws {
    #expect(throws: ContainerToolValidationError.missingExecutable) {
      try ContainerCommandRequest(executable: "")
    }
    #expect(throws: ContainerToolValidationError.invalidTimeout) {
      try ContainerCommandRequest(executable: "/bin/true", timeoutSeconds: 0)
    }
    #expect(throws: ContainerToolValidationError.invalidContainerPath("relative")) {
      try ContainerFileTransferRequest(
        direction: .fromContainer,
        localURL: URL(filePath: "/tmp"),
        containerPath: "relative"
      )
    }
  }
}

private func emptyInventory() -> ContainerInventory {
  ContainerInventory(
    system: ContainerSystemInfo(
      version: "1.0.0",
      build: "release",
      commit: "abc123",
      applicationRoot: URL(filePath: "/tmp/data"),
      installRoot: URL(filePath: "/usr/local")
    ),
    containers: [],
    images: [],
    volumes: [],
    networks: [],
    machines: []
  )
}

private func inventoryWithImage(digest: String) -> ContainerInventory {
  let empty = emptyInventory()
  return ContainerInventory(
    system: empty.system,
    containers: [],
    images: [
      ImageRecord(
        reference: "example/app:latest",
        digest: digest,
        mediaType: "index",
        indexSizeBytes: 512
      )
    ],
    volumes: [],
    networks: [],
    machines: []
  )
}

private actor MockContainerService: ContainerManaging {
  private var inventories: [ContainerInventory]
  let inspection: ContainerInspection
  let loadError: (any Error)?
  let pullError: (any Error)?
  private(set) var startedContainerIDs: [String] = []
  private(set) var inspectedContainerIDs: [String] = []
  private(set) var createdRequests: [ContainerCreationRequest] = []
  private(set) var pulledImageReferences: [String] = []
  private(set) var restartedContainerIDs: [String] = []
  private(set) var forceStoppedContainerIDs: [String] = []
  private(set) var commandRequests: [ContainerCommandRequest] = []
  private(set) var copiedIntoContainer: [(String, URL, String)] = []
  private(set) var copiedFromContainer: [(String, String, URL)] = []
  private(set) var loadCount = 0
  private(set) var sampleCount = 0
  private(set) var logLoadCount = 0

  init(
    inventory: ContainerInventory,
    subsequentInventories: [ContainerInventory] = [],
    loadError: (any Error)? = nil,
    pullError: (any Error)? = nil,
    inspection: ContainerInspection = ContainerInspection(
      diskUsageBytes: 0,
      statistics: nil,
      standardOutput: "",
      bootLog: "",
      logsAreTruncated: false
    )
  ) {
    inventories = [inventory] + subsequentInventories
    self.loadError = loadError
    self.pullError = pullError
    self.inspection = inspection
  }

  func loadInventory() async throws -> ContainerInventory {
    loadCount += 1
    if let loadError { throw loadError }
    if inventories.count > 1 {
      return inventories.removeFirst()
    }
    return inventories[0]
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    ImagePullPlan(
      normalizedReference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
      registryHost: "registry-1.docker.io",
      existingDigest: nil,
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: transport,
      resolvedTransport: .https,
      unpackAfterPull: unpackAfterPull,
      maxConcurrentDownloads: maxConcurrentDownloads,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
  }

  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    pulledImageReferences.append(plan.normalizedReference)
    await progress(ContainerOperationProgress(phase: .fetchingImage, message: "Fetching image"))
    if let pullError { throw pullError }
    await progress(ContainerOperationProgress(phase: .completed, message: "Image ready"))
    return ImagePullResult(
      reference: plan.normalizedReference,
      digest: "sha256:test",
      replacedDigest: plan.existingDigest,
      unpackOutcome: plan.unpackAfterPull
        ? ImageUnpackOutcome(
          platforms: [
            ImagePlatformUnpackOutcome(
              platform: OCIPlatformValue(
                os: "linux",
                architecture: "arm64",
                variant: "v8"
              ),
              state: .created
            )
          ]
        ) : nil
    )
  }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    createdRequests.append(request)
    await progress(ContainerOperationProgress(phase: .creating, message: "Creating container"))
    await progress(ContainerOperationProgress(phase: .completed, message: "Container ready"))
  }

  func inspectContainer(id: String) async throws -> ContainerInspection {
    inspectedContainerIDs.append(id)
    return inspection
  }

  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    sampleCount += 1
    return inspection.statistics
  }

  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    logLoadCount += 1
    return ContainerLogsSnapshot(
      standardOutput: inspection.standardOutput,
      bootLog: inspection.bootLog,
      logsAreTruncated: inspection.logsAreTruncated
    )
  }

  func startContainer(id: String) async throws { startedContainerIDs.append(id) }
  func stopContainer(id: String) async throws {}
  func restartContainer(id: String) async throws { restartedContainerIDs.append(id) }
  func forceStopContainer(id: String) async throws { forceStoppedContainerIDs.append(id) }
  func deleteContainer(id: String) async throws {}
  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    commandRequests.append(request)
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: "ok\n",
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(10)
    )
  }
  func copyIntoContainer(id: String, source: URL, destination: String) async throws {
    copiedIntoContainer.append((id, source, destination))
  }
  func copyFromContainer(id: String, source: String, destination: URL) async throws {
    copiedFromContainer.append((id, source, destination))
  }
  func startMachine(id: String) async throws {}
  func stopMachine(id: String) async throws {}
  func deleteMachine(id: String) async throws {}
}

private enum AppModelTestError: LocalizedError {
  case runtimeUnavailable
  case transferFailed

  var errorDescription: String? {
    switch self {
    case .runtimeUnavailable: "Apple container services are offline."
    case .transferFailed: "The image transfer failed after downloading content."
    }
  }
}

private actor MockVirtualMachineLibrary: VirtualMachineLibraryProtocol {
  private var manifests: [VirtualMachineManifest]

  init(manifests: [VirtualMachineManifest]) {
    self.manifests = manifests
  }

  func list() async throws -> [VirtualMachineManifest] { manifests }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest {
    let manifest = try VirtualMachineManifest(name: name, guest: guest, resources: resources)
    manifests.append(manifest)
    return manifest
  }
}

private actor BlockingVirtualMachineLibrary: VirtualMachineLibraryProtocol {
  private var hasStartedFirstList = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstListContinuation: CheckedContinuation<Void, Never>?

  func list() async -> [VirtualMachineManifest] {
    guard !hasStartedFirstList else { return [] }
    hasStartedFirstList = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      firstListContinuation = continuation
    }
    return []
  }

  func waitUntilFirstListStarts() async {
    guard !hasStartedFirstList else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resumeFirstList() {
    firstListContinuation?.resume()
    firstListContinuation = nil
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest {
    try VirtualMachineManifest(name: name, guest: guest, resources: resources)
  }
}
