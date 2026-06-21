import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct AppModelTests {
  @Test
  func imageBuildWorkspaceUsesAStableNavigationGuardModel() {
    let model = AppModel.previewEmpty

    #expect(model.makeImageBuildModel() === model.makeImageBuildModel())
    #expect(
      model.makeContainerBuilderManagementModel()
        === model.makeContainerBuilderManagementModel()
    )
    #expect(
      model.makeAppOwnedBuildCacheModel()
        === model.makeAppOwnedBuildCacheModel()
    )
    #expect(
      model.makeStorageOverviewModel()
        === model.makeStorageOverviewModel()
    )
    #expect(
      model.makeStorageReclamationModel()
        === model.makeStorageReclamationModel()
    )
    #expect(
      model.makeLaunchAtLoginModel()
        === model.makeLaunchAtLoginModel()
    )
  }

  @Test
  func ordinaryInventoryRefreshDoesNotMeasureStorage() async {
    let storage = CountingAppStorageUsageService()
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      storageUsageService: storage,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )

    await model.refresh()

    #expect(await storage.runtimeLoadCount == 0)
    #expect(await storage.virtualMachineLoadCount == 0)
  }

  @Test
  func macVirtualMachineRuntimeUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineRuntimeModel(for: machine)
        === model.makeMacVirtualMachineRuntimeModel(for: machine)
    )
  }

  @Test
  func macVirtualMachineUSBUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineUSBModel(for: machine)
        === model.makeMacVirtualMachineUSBModel(for: machine)
    )
  }

  @Test
  func linuxVirtualMachineRuntimeUsesAStableAppScopedModel() throws {
    let model = AppModel.previewEmpty
    let machine = try VirtualMachineManifest(
      name: "Linux",
      guest: .linux,
      installState: .readyToInstall,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 32 * VirtualMachineResources.bytesPerGiB
      )
    )

    #expect(
      model.makeLinuxVirtualMachineRuntimeModel(for: machine)
        === model.makeLinuxVirtualMachineRuntimeModel(for: machine)
    )
  }

  @Test
  func macVirtualMachineAudioUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineAudioModel(for: machine)
        === model.makeMacVirtualMachineAudioModel(for: machine)
    )
  }

  @Test
  func macVirtualMachineNetworkUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineNetworkModel(for: machine)
        === model.makeMacVirtualMachineNetworkModel(for: machine)
    )
  }

  @Test
  func macVirtualMachineDiskSnapshotsUseAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineDiskSnapshotModel(for: machine)
        === model.makeMacVirtualMachineDiskSnapshotModel(for: machine)
    )
  }

  @Test
  func macVirtualMachineSharingUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeMacVirtualMachineSharedDirectoriesModel(for: machine)
        === model.makeMacVirtualMachineSharedDirectoriesModel(for: machine)
    )
  }

  @Test
  func linuxVirtualMachineSharingUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(
      model.virtualMachines.first(where: { $0.guest == .linux })
    )

    #expect(
      model.makeLinuxVirtualMachineSharedDirectoriesModel(for: machine)
        === model.makeLinuxVirtualMachineSharedDirectoriesModel(for: machine)
    )
  }

  @Test
  func diskMaintenanceUsesAStableAppScopedModel() throws {
    let model = AppModel.previewVirtualMachines
    let machine = try #require(model.virtualMachines.first)

    #expect(
      model.makeVirtualMachineDiskImageMaintenanceModel(for: machine)
        === model.makeVirtualMachineDiskImageMaintenanceModel(for: machine)
    )
  }

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
          ports: [],
          labels: [
            ComposeLabelKey.project: "store",
            ComposeLabelKey.service: "web",
          ]
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
          labels: [
            "com.apple.container.resource.role": "builtin",
            ComposeLabelKey.project: "store",
            ComposeLabelKey.network: "default",
          ],
          plugin: "container-network-vmnet",
          options: [:],
          isBuiltin: false,
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
    #expect(model.runningContainerCount == 1)
    #expect(model.runningLinuxMachineCount == 0)
    #expect(model.networks == inventory.networks)
    #expect(model.composeProjects.map(\.name) == ["store"])
    #expect(model.composeProjects.first?.services.map(\.name) == ["web"])
    #expect(model.composeProjects.first?.networks.map(\.id) == ["default"])
    #expect(model.virtualMachines == [manifest])
    #expect(model.errorMessage == nil)
    #expect(model.lastRefresh != nil)
    #expect(model.containerInventoryRevision == 1)
    #expect(!model.isRefreshing)
  }

  @Test
  func composeTopologyDerivationIsReplaceableAtTheApplicationBoundary() {
    let inventory = ContainerInventory(
      system: emptyInventory().system,
      containers: [
        ContainerRecord(
          id: "web",
          imageReference: "example/web:latest",
          platform: "linux/arm64",
          state: .running,
          ipAddress: nil,
          createdAt: Date(timeIntervalSince1970: 1),
          startedAt: Date(timeIntervalSince1970: 2),
          cpuCount: 2,
          memoryBytes: VirtualMachineResources.bytesPerGiB,
          ports: [],
          labels: [
            ComposeLabelKey.project: "replaceable",
            ComposeLabelKey.service: "web",
          ]
        )
      ],
      images: [],
      volumes: [],
      networks: [],
      machines: []
    )
    let model = AppModel(
      containerService: MockContainerService(inventory: inventory),
      composeTopologyService: EmptyComposeTopologyService(),
      initialInventory: inventory
    )

    #expect(model.composeTopology == .empty)
    #expect(model.composeProjects.isEmpty)
  }

  @Test
  func macPreparationPublishesThePersistedManifestWithoutASecondLibraryRead() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let draft = try VirtualMachineManifest(
      name: "Prepared Mac",
      guest: .macOS,
      resources: resources
    )
    let restoreImageURL = URL(filePath: "/private/cache/Prepared.ipsw")
    var prepared = draft
    prepared.markReadyToInstallMacOS(
      restoreImageURL: restoreImageURL,
      auxiliaryStoragePath: "MacPlatform/AuxiliaryStorage",
      hardwareModelPath: "MacPlatform/HardwareModel",
      machineIdentifierPath: "MacPlatform/MachineIdentifier"
    )
    let library = PostPersistenceReadFailingVirtualMachineLibrary(prepared: prepared)
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: library,
      initialInventory: emptyInventory(),
      initialVirtualMachines: [draft]
    )

    try await model.prepareMacVirtualMachine(
      id: draft.id,
      restoreImageURL: restoreImageURL
    )

    #expect(model.virtualMachines == [prepared])
    #expect(await library.listCount == 0)
  }

  @Test
  func cloningUsesFocusedServiceThenPublishesAndSelectsPersistedClone() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var source = try VirtualMachineManifest(
      name: "Source Mac",
      guest: .macOS,
      resources: resources
    )
    source.installState = .stopped
    let fixture = AppModelVirtualMachineCloneFixture(source: source)
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: fixture,
      virtualMachineCloner: fixture,
      initialInventory: emptyInventory(),
      initialVirtualMachines: [source]
    )

    let clone = try await model.cloneVirtualMachine(id: source.id, name: "Source Mac Copy")

    #expect(await fixture.requests == [.init(id: source.id, name: "Source Mac Copy")])
    #expect(model.virtualMachines == [source, clone])
    #expect(model.workspaceRoute == .macOSVirtualMachine(clone.id))
  }

  @Test
  func exportForwardsToFocusedServiceWithoutChangingInventoryOrRoute() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var source = try VirtualMachineManifest(
      name: "Export Source",
      guest: .macOS,
      resources: resources
    )
    source.installState = .stopped
    let transfer = AppModelVirtualMachineTransferFixture(imported: source)
    let library = AppModelVirtualMachineCloneFixture(source: source)
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: library,
      virtualMachineTransfer: transfer,
      initialInventory: emptyInventory(),
      initialVirtualMachines: [source]
    )
    model.navigate(to: .macOSVirtualMachine(source.id))
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "Export Source.nativevm")

    let receipt = try await model.exportVirtualMachine(
      id: source.id,
      to: destination
    )

    #expect(
      receipt == VirtualMachineExportReceipt(machineID: source.id, destinationURL: destination))
    #expect(await transfer.requests == [.export(id: source.id, destinationURL: destination)])
    #expect(model.virtualMachines == [source])
    #expect(model.workspaceRoute == .macOSVirtualMachine(source.id))
  }

  @Test
  func importPublishesReturnedManifestAndSelectsItWithoutASecondLibraryRead() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var source = try VirtualMachineManifest(
      name: "Zulu Source",
      guest: .macOS,
      resources: resources
    )
    source.installState = .stopped
    var imported = try VirtualMachineManifest(
      name: "Alpha Imported",
      guest: .macOS,
      resources: resources
    )
    imported.installState = .stopped
    let transfer = AppModelVirtualMachineTransferFixture(imported: imported)
    let library = AppModelVirtualMachineCloneFixture(source: source)
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: library,
      virtualMachineTransfer: transfer,
      initialInventory: emptyInventory(),
      initialVirtualMachines: [source]
    )
    let package = FileManager.default.temporaryDirectory
      .appending(path: "Imported.nativevm")

    let result = try await model.importVirtualMachine(
      from: package,
      mode: .clone(name: imported.name)
    )

    #expect(result == imported)
    #expect(
      await transfer.requests
        == [.importPackage(sourceURL: package, mode: .clone(name: imported.name))]
    )
    #expect(model.virtualMachines == [imported, source])
    #expect(model.workspaceRoute == .macOSVirtualMachine(imported.id))
  }

  @Test
  func firstLoadRunsDedicatedDiskAndRestoreImageRecoveryServices() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var prepared = try VirtualMachineManifest(
      name: "Recovery Mac",
      guest: .macOS,
      resources: resources
    )
    let restoreImageURL = URL(filePath: "/private/cache/Recovery.ipsw")
    prepared.markReadyToInstallMacOS(
      restoreImageURL: restoreImageURL,
      auxiliaryStoragePath: "MacPlatform/AuxiliaryStorage",
      hardwareModelPath: "MacPlatform/HardwareModel",
      machineIdentifierPath: "MacPlatform/MachineIdentifier"
    )
    let restoreImageRecovery = RecoveryRecordingRestoreImageStoreRecovery()
    let diskRecovery = RecoveryRecordingDiskImageReplacementService()
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [prepared]),
      virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices(
        migration: UnavailableVirtualMachineDiskImageMigrationService(),
        rewrite: UnavailableVirtualMachineDiskImageRewriteService(),
        recovery: diskRecovery
      ),
      restoreImageStoreRecovery: restoreImageRecovery
    )

    await model.loadIfNeeded()

    #expect(diskRecovery.recoveryCount == 1)
    #expect(await restoreImageRecovery.recoveryCount == 1)
  }

  @Test
  func diskRecoveryFailureDoesNotStarveRestoreImageRecovery() async throws {
    let machineID = UUID()
    let restoreImageRecovery = RecoveryRecordingRestoreImageStoreRecovery()
    let diskRecovery = RecoveryRecordingDiskImageReplacementService(
      report: VirtualMachineDiskImageReplacementRecoveryReport(
        recoveredMachineIDs: [],
        deferredMachineIDs: [],
        failures: [
          VirtualMachineDiskImageReplacementRecoveryFailure(
            machineID: machineID,
            diagnostic: "malformed journal"
          )
        ]
      )
    )
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
      virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices(
        migration: UnavailableVirtualMachineDiskImageMigrationService(),
        rewrite: UnavailableVirtualMachineDiskImageRewriteService(),
        recovery: diskRecovery
      ),
      restoreImageStoreRecovery: restoreImageRecovery
    )

    await model.loadIfNeeded()

    #expect(await restoreImageRecovery.recoveryCount > 0)
    #expect(model.errorMessage?.contains("malformed journal") == true)
  }

  @Test
  func refreshConvergesALateLegacyRestoreImageReference() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var prepared = try VirtualMachineManifest(
      name: "Legacy Recovery Mac",
      guest: .macOS,
      resources: resources
    )
    let restoreImageURL = URL(filePath: "/private/cache/Late.ipsw")
    prepared.markReadyToInstallMacOS(
      restoreImageURL: restoreImageURL,
      auxiliaryStoragePath: "MacPlatform/AuxiliaryStorage",
      hardwareModelPath: "MacPlatform/HardwareModel",
      machineIdentifierPath: "MacPlatform/MachineIdentifier"
    )
    let library = MockVirtualMachineLibrary(manifests: [prepared])
    let recovery = ConditionalRecoveryRecordingRestoreImageStoreRecovery()
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: library,
      restoreImageStoreRecovery: recovery,
      initialInventory: emptyInventory(),
      initialVirtualMachines: [prepared]
    )

    await model.refresh()

    #expect(await recovery.checkedReferences == [[restoreImageURL]])
    #expect(await library.listCount == 2)
  }

  @Test
  func refreshCancellationDuringLegacyRecoveryDoesNotPublishAStaleSnapshot() async throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var initial = try VirtualMachineManifest(
      name: "Published Mac",
      guest: .macOS,
      resources: resources
    )
    initial.installState = .stopped
    var stale = try VirtualMachineManifest(
      name: "Pre-migration Mac",
      guest: .macOS,
      resources: resources
    )
    stale.markReadyToInstallMacOS(
      restoreImageURL: URL(filePath: "/private/cache/Stale.ipsw"),
      auxiliaryStoragePath: "MacPlatform/AuxiliaryStorage",
      hardwareModelPath: "MacPlatform/HardwareModel",
      machineIdentifierPath: "MacPlatform/MachineIdentifier"
    )
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [stale]),
      restoreImageStoreRecovery: CancellingRestoreImageStoreRecovery(),
      initialInventory: emptyInventory(),
      initialVirtualMachines: [initial]
    )
    let publishedRevision = model.virtualMachineInventoryRevision
    let publishedRefreshDate = model.lastRefresh

    await model.refresh()

    #expect(model.virtualMachines == [initial])
    #expect(model.virtualMachineInventoryRevision == publishedRevision)
    #expect(model.lastRefresh == publishedRefreshDate)
    #expect(model.errorMessage == nil)
    #expect(!model.isRefreshing)
  }

  @Test
  func refreshRetriesARecoveryThatFailedDuringFirstLoad() async {
    let installer = RetryableRecoveryInstaller(failuresBeforeSuccess: 2)
    let model = AppModel(
      containerService: MockContainerService(inventory: emptyInventory()),
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
      virtualMachineInstaller: installer
    )

    await model.loadIfNeeded()
    #expect(model.errorMessage?.contains("Virtual machine recovery") == true)
    #expect(installer.recoveryAttempts == 2)

    await model.refresh()

    #expect(installer.recoveryAttempts == 3)
    #expect(model.errorMessage == nil)
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
        containerAttachments: lifecycleService,
        machineCreator: lifecycleService,
        machineLifecycle: lifecycleService,
        images: lifecycleService,
        volumes: lifecycleService,
        networks: lifecycleService,
        browser: lifecycleService,
        imageBuild: AppleContainerBuildService(),
        registry: AppleRegistryService(),
        virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
        restoreImageDiscovery: MacRestoreImageService(),
        restoreImageAcquisition: RestoreImageAcquisitionService.standard()
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
  func provisioningLoadsFocusedAttachmentEnvironment() async throws {
    let hostAccess = try ContainerHostAccessConfiguration(
      domain: "host.container.internal",
      redirectIPv4Address: "203.0.113.113"
    )
    let environment = ContainerAttachmentEnvironment(
      publishedSocketRootPath: "/tmp/nativecontainers",
      hostAccess: ContainerHostAccessCatalog(
        configurations: [hostAccess],
        warnings: []
      )
    )
    let service = MockContainerService(
      inventory: emptyInventory(),
      attachmentEnvironment: environment
    )
    let appModel = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )
    let model = appModel.makeContainerProvisioningModel()

    await model.loadAttachmentEnvironment()

    #expect(model.attachmentEnvironment == environment)
    #expect(await service.attachmentEnvironmentLoadCount == 1)
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
          ports: [],
          labels: [
            ComposeLabelKey.project: "stale-project",
            ComposeLabelKey.service: "app",
          ]
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
    #expect(model.composeProjects.map(\.name) == ["stale-project"])

    await model.refresh()

    #expect(model.systemInfo == nil)
    #expect(model.containers.isEmpty)
    #expect(model.images.isEmpty)
    #expect(model.composeProjects.isEmpty)
    #expect(model.errorMessage?.contains("offline") == true)
  }

  @Test
  func transientRuntimeRefreshFailurePreservesExactRouteThroughRecovery() async {
    let initial = ContainerInventory(
      system: emptyInventory().system,
      containers: [
        ContainerRecord(
          id: "db",
          imageReference: "example/db:latest",
          platform: "linux/arm64",
          state: .running,
          ipAddress: nil,
          createdAt: Date(timeIntervalSince1970: 1),
          startedAt: Date(timeIntervalSince1970: 2),
          cpuCount: 2,
          memoryBytes: VirtualMachineResources.bytesPerGiB,
          ports: []
        )
      ],
      images: [],
      volumes: [],
      networks: [],
      machines: []
    )
    let service = MockContainerService(
      inventory: initial,
      loadError: AppModelTestError.runtimeUnavailable,
      subsequentLoadErrors: [nil]
    )
    let model = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: []),
      initialInventory: initial
    )
    #expect(model.navigate(to: .container("db")))

    await model.refresh()

    #expect(model.containers.isEmpty)
    #expect(model.workspaceRoute == .container("db"))

    await model.refresh()

    #expect(model.containers == initial.containers)
    #expect(model.workspaceRoute == .container("db"))
    #expect(model.errorMessage == nil)
  }

  @Test
  func toolsModelExecutesCommandAndCopiesBothDirections() async throws {
    let service = MockContainerService(inventory: emptyInventory())
    let model = ContainerToolsModel(
      containerID: "web",
      tooling: service,
      shellDiscovery: UnavailableContainerShellService()
    )
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

private actor MockContainerService: ContainerManaging, MachineManaging {
  private var inventories: [ContainerInventory]
  private var loadErrors: [(any Error)?]
  let inspection: ContainerInspection
  let pullError: (any Error)?
  let attachmentEnvironment: ContainerAttachmentEnvironment
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
  private(set) var attachmentEnvironmentLoadCount = 0

  init(
    inventory: ContainerInventory,
    subsequentInventories: [ContainerInventory] = [],
    loadError: (any Error)? = nil,
    subsequentLoadErrors: [(any Error)?] = [],
    pullError: (any Error)? = nil,
    attachmentEnvironment: ContainerAttachmentEnvironment = ContainerAttachmentEnvironment(
      publishedSocketRootPath: "",
      hostAccess: .empty
    ),
    inspection: ContainerInspection = ContainerInspection(
      diskUsageBytes: 0,
      statistics: nil,
      standardOutput: "",
      bootLog: "",
      logsAreTruncated: false
    )
  ) {
    inventories = [inventory] + subsequentInventories
    loadErrors = [loadError] + subsequentLoadErrors
    self.pullError = pullError
    self.attachmentEnvironment = attachmentEnvironment
    self.inspection = inspection
  }

  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment {
    attachmentEnvironmentLoadCount += 1
    return attachmentEnvironment
  }

  func loadInventory() async throws -> ContainerInventory {
    loadCount += 1
    let loadError: (any Error)?
    if loadErrors.count > 1 {
      loadError = loadErrors.removeFirst()
    } else {
      loadError = loadErrors[0]
    }
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
  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    await progress(
      ContainerOperationProgress(phase: .completed, message: "Linux machine ready")
    )
    return LinuxMachineCreationResult(
      identity: LinuxMachineIdentity(
        id: request.name,
        imageReference: request.imageReference,
        platform: "linux/\(request.architecture.rawValue)",
        createdAt: Date()
      ),
      state: request.startAfterCreation ? .running : .stopped,
      isInitialized: request.startAfterCreation
    )
  }
  func startMachine(_ target: LinuxMachineIdentity) async throws {}
  func stopMachine(_ target: LinuxMachineIdentity) async throws {}
  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws {}
  func deleteMachine(_ target: LinuxMachineIdentity) async throws {}
}

private actor CountingAppStorageUsageService: StorageUsageLoading {
  private(set) var runtimeLoadCount = 0
  private(set) var virtualMachineLoadCount = 0

  func loadAppleRuntimeStorageUsage() async throws
    -> AppleRuntimeStorageUsage
  {
    runtimeLoadCount += 1
    throw StorageUsageError.unavailable
  }

  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    virtualMachineLoadCount += 1
    throw StorageUsageError.unavailable
  }
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
  private(set) var listCount = 0

  init(manifests: [VirtualMachineManifest]) {
    self.manifests = manifests
  }

  func list() async throws -> [VirtualMachineManifest] {
    listCount += 1
    return manifests
  }

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

private actor PostPersistenceReadFailingVirtualMachineLibrary: VirtualMachineLibraryProtocol {
  let prepared: VirtualMachineManifest
  private(set) var listCount = 0

  init(prepared: VirtualMachineManifest) {
    self.prepared = prepared
  }

  func list() async throws -> [VirtualMachineManifest] {
    listCount += 1
    throw AppModelTestError.runtimeUnavailable
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest {
    try VirtualMachineManifest(name: name, guest: guest, resources: resources)
  }

  func prepareMacVM(id: UUID, restoreImageURL: URL) async throws -> VirtualMachineManifest {
    prepared
  }
}

private actor AppModelVirtualMachineCloneFixture:
  VirtualMachineLibraryProtocol,
  VirtualMachineCloning
{
  struct Request: Equatable, Sendable {
    let id: UUID
    let name: String
  }

  private var manifests: [VirtualMachineManifest]
  private(set) var requests: [Request] = []

  init(source: VirtualMachineManifest) {
    manifests = [source]
  }

  func list() -> [VirtualMachineManifest] {
    manifests
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    try VirtualMachineManifest(name: name, guest: guest, resources: resources)
  }

  func cloneVirtualMachine(id: UUID, name: String) throws -> VirtualMachineManifest {
    guard let source = manifests.first(where: { $0.id == id }) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    requests.append(Request(id: id, name: name))
    let clone = try VirtualMachineManifest(cloning: source, name: name)
    manifests.append(clone)
    return clone
  }
}

private actor AppModelVirtualMachineTransferFixture:
  VirtualMachinePackageTransferring
{
  enum Request: Equatable, Sendable {
    case export(id: UUID, destinationURL: URL)
    case importPackage(sourceURL: URL, mode: VirtualMachineImportMode)
  }

  let imported: VirtualMachineManifest
  private(set) var requests: [Request] = []

  init(imported: VirtualMachineManifest) {
    self.imported = imported
  }

  func exportVirtualMachine(
    id: UUID,
    to destinationURL: URL
  ) -> VirtualMachineExportReceipt {
    requests.append(.export(id: id, destinationURL: destinationURL))
    return VirtualMachineExportReceipt(
      machineID: id,
      destinationURL: destinationURL
    )
  }

  func importVirtualMachine(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) -> VirtualMachineManifest {
    requests.append(.importPackage(sourceURL: sourceURL, mode: mode))
    return imported
  }
}

@MainActor
private final class RecoveryRecordingDiskImageReplacementService:
  VirtualMachineDiskImageReplacementRecovering
{
  private(set) var recoveryCount = 0
  private let report: VirtualMachineDiskImageReplacementRecoveryReport

  init(report: VirtualMachineDiskImageReplacementRecoveryReport = .empty) {
    self.report = report
  }

  func recoverInterruptedDiskImageReplacements() async throws
    -> VirtualMachineDiskImageReplacementRecoveryReport
  {
    recoveryCount += 1
    return report
  }
}

private actor RecoveryRecordingRestoreImageStoreRecovery:
  RestoreImageStoreRecovering
{
  private(set) var recoveryCount = 0

  func recover() async throws {
    recoveryCount += 1
  }
}

private actor ConditionalRecoveryRecordingRestoreImageStoreRecovery:
  RestoreImageStoreRecovering
{
  private(set) var checkedReferences: [Set<URL>] = []

  func recover() async throws {}

  func recoverLegacyReferencesIfNeeded(
    _ referencedURLs: Set<URL>
  ) async throws -> Bool {
    checkedReferences.append(referencedURLs)
    return true
  }
}

private struct CancellingRestoreImageStoreRecovery:
  RestoreImageStoreRecovering
{
  func recover() async throws {}

  func recoverLegacyReferencesIfNeeded(
    _ referencedURLs: Set<URL>
  ) async throws -> Bool {
    throw CancellationError()
  }
}

@MainActor
private final class RetryableRecoveryInstaller: MacVirtualMachineInstalling {
  let failuresBeforeSuccess: Int
  private(set) var recoveryAttempts = 0

  init(failuresBeforeSuccess: Int) {
    self.failuresBeforeSuccess = failuresBeforeSuccess
  }

  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {}

  func recoverInterruptedInstallations() async throws -> MacVirtualMachineRecoveryOutcome {
    recoveryAttempts += 1
    if recoveryAttempts <= failuresBeforeSuccess {
      throw AppModelTestError.runtimeUnavailable
    }
    return .recovered
  }
}

private struct EmptyComposeTopologyService: ComposeTopologyDeriving {
  func derive(from inventory: ContainerInventory) -> ComposeTopologySnapshot {
    .empty
  }
}
