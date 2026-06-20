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
    let model = ContainerInspectorModel(containerID: "web", service: service)

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
  private(set) var loadCount = 0

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

  func startContainer(id: String) async throws { startedContainerIDs.append(id) }
  func stopContainer(id: String) async throws {}
  func deleteContainer(id: String) async throws {}
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
