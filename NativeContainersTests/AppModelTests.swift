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

    let succeeded = await model.pullImage(reference: "  alpine:latest  ")

    #expect(succeeded)
    #expect(model.progress?.phase == .completed)
    #expect(await service.pulledImageReferences == ["alpine:latest"])
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
    machines: []
  )
}

private actor MockContainerService: ContainerManaging {
  let inventory: ContainerInventory
  let inspection: ContainerInspection
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
    inspection: ContainerInspection = ContainerInspection(
      diskUsageBytes: 0,
      statistics: nil,
      standardOutput: "",
      bootLog: "",
      logsAreTruncated: false
    )
  ) {
    self.inventory = inventory
    self.inspection = inspection
  }

  func loadInventory() async throws -> ContainerInventory {
    loadCount += 1
    return inventory
  }

  func pullImage(
    reference: String,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    pulledImageReferences.append(reference)
    await progress(ContainerOperationProgress(phase: .fetchingImage, message: "Fetching image"))
    await progress(ContainerOperationProgress(phase: .completed, message: "Image ready"))
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
