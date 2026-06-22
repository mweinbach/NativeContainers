import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  let workspaceNavigation: WorkspaceNavigationModel

  var selection: SidebarDestination {
    get { SidebarDestination(workspaceRoute: workspaceNavigation.route) }
    set { selectSidebarDestination(newValue) }
  }

  var workspaceRoute: WorkspaceRoute { workspaceNavigation.route }

  private(set) var systemInfo: ContainerSystemInfo?
  private(set) var containers: [ContainerRecord] = []
  private(set) var images: [ImageRecord] = []
  private(set) var volumes: [VolumeRecord] = []
  private(set) var networks: [NetworkRecord] = []
  private(set) var linuxMachines: [LinuxMachineRecord] = []
  private(set) var composeTopology = ComposeTopologySnapshot.empty
  private(set) var virtualMachines: [VirtualMachineManifest] = []
  private(set) var runningContainerCount = 0
  private(set) var runningLinuxMachineCount = 0
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?
  private(set) var errorMessage: String?
  private(set) var containerInventoryRevision: UInt64 = 0
  private(set) var virtualMachineInventoryRevision: UInt64 = 0

  private let services: AppServices

  var composeProjects: [ComposeProjectRecord] { composeTopology.projects }

  @ObservationIgnored
  private lazy var imageBuildWorkspaceModel = ImageBuildModel(
    service: services.imageBuild,
    notifications: services.notifications
  ) { [weak self] in
    await self?.refresh()
  }

  @ObservationIgnored
  private lazy var builderWorkspaceModel = ContainerBuilderManagementModel(
    service: services.builder
  ) { [weak self] in
    await self?.refresh()
  }

  @ObservationIgnored
  private lazy var appOwnedBuildCacheModel = AppOwnedBuildCacheModel(
    service: services.appOwnedBuildCache
  )

  @ObservationIgnored
  private lazy var storageOverviewModel = StorageOverviewModel(
    service: services.storageUsage
  )

  @ObservationIgnored
  private lazy var storageReclamationModel = StorageReclamationModel(
    service: services.storageReclamation,
    currentSource: { [weak self] in
      guard let self else { return nil }
      return self.storageOverviewModel.reclamationSource(
        inventoryRevision: self.containerInventoryRevision
      )
    },
    didMutate: { [weak self] in
      guard let self else { return }
      await self.refresh()
      await self.storageOverviewModel.refreshAppleRuntimeAfterMutation()
    }
  )

  @ObservationIgnored
  private lazy var virtualMachineStorageReclamationModel =
    VirtualMachineStorageReclamationModel(
      service: services.virtualMachineStorageReclamation,
      currentSource: { [weak self] in
        guard let self else { return nil }
        return self.storageOverviewModel.virtualMachineReclamationSource(
          libraryRevision: self.virtualMachineInventoryRevision
        )
      },
      didMutate: { [weak self] in
        await self?.refreshVirtualMachineStorageAfterMutation()
      }
    )

  @ObservationIgnored
  private lazy var dockerCompatibilitySettingsModel = DockerCompatibilityModel(
    service: services.dockerCompatibility,
    composeConformance: services.composeBridgeConformance,
    composeClientService: services.dockerComposeClient
  )

  @ObservationIgnored
  private lazy var launchAtLoginModel = LaunchAtLoginModel(
    service: services.launchAtLogin
  )

  @ObservationIgnored
  private lazy var appNotificationSettingsModel = AppNotificationSettingsModel(
    service: services.notifications
  )

  @ObservationIgnored
  private lazy var performanceBenchmarkModel = PerformanceBenchmarkModel(
    service: services.performanceBenchmarks
  )

  @ObservationIgnored
  private lazy var fieldDiagnosticModel = FieldDiagnosticModel(
    service: services.fieldDiagnostics
  )

  @ObservationIgnored
  private lazy var kubernetesClusterModel = KubernetesClusterModel(
    service: services.kubernetes
  ) { [weak self] in
    await self?.refresh()
  }

  @ObservationIgnored
  private lazy var composeProjectWorkspaceModel = ComposeProjectWorkspaceModel(
    service: services.composeProjectLifecycle
  ) { [weak self] in
    await self?.refresh()
  }

  @ObservationIgnored
  private var macVirtualMachineRuntimeModels: [UUID: MacVirtualMachineRuntimeModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineUSBModels: [UUID: MacVirtualMachineUSBModel] = [:]

  @ObservationIgnored
  private var linuxVirtualMachineRuntimeModels: [UUID: LinuxVirtualMachineRuntimeModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineAudioModels: [UUID: MacVirtualMachineAudioModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineNetworkModels: [UUID: MacVirtualMachineNetworkModel] = [:]

  @ObservationIgnored
  private var linuxVirtualMachineNetworkModels: [UUID: LinuxVirtualMachineNetworkModel] = [:]

  @ObservationIgnored
  private var virtualMachineComputeModels: [UUID: VirtualMachineComputeModel] = [:]

  @ObservationIgnored
  private var virtualMachineNameModels: [UUID: VirtualMachineNameModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineDiskSnapshotModels: [UUID: MacVirtualMachineDiskSnapshotModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineSharedDirectoryModels:
    [UUID: MacVirtualMachineSharedDirectoriesModel] = [:]

  @ObservationIgnored
  private var linuxVirtualMachineSharedDirectoryModels:
    [UUID: LinuxVirtualMachineSharedDirectoriesModel] = [:]

  @ObservationIgnored
  private var virtualMachineDiskImageMaintenanceModels:
    [UUID: VirtualMachineDiskImageMaintenanceModel] = [:]

  private var hasLoaded = false
  private var refreshRequested = false
  private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var virtualMachineRecoveryErrorMessage: String?

  init(
    services: AppServices,
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = [],
    workspaceNavigation: WorkspaceNavigationModel = WorkspaceNavigationModel()
  ) {
    self.services = services
    self.workspaceNavigation = workspaceNavigation
    if let initialInventory {
      composeTopology = services.composeTopology.derive(from: initialInventory)
      systemInfo = initialInventory.system
      containers = initialInventory.containers
      images = initialInventory.images
      volumes = initialInventory.volumes
      networks = initialInventory.networks
      linuxMachines = initialInventory.machines
      runningContainerCount = initialInventory.containers.lazy.filter(\.state.isRunning).count
      runningLinuxMachineCount = initialInventory.machines.lazy.filter(\.state.isRunning).count
      virtualMachines = initialVirtualMachines
      hasLoaded = true
      containerInventoryRevision = 1
      virtualMachineInventoryRevision = 1
      lastRefresh = Date()
    }
    updateWorkspaceNavigation()
    services.notifications.setResponseHandler { [weak self] destination in
      await self?.handleNotificationResponse(destination)
    }
    services.fieldDiagnostics.start()
  }

  convenience init(
    containerService: any ContainerManaging = AppleContainerService(),
    containerShellService: any ContainerShellDiscovering = UnavailableContainerShellService(),
    terminalPresetService: any TerminalPresetManaging = EphemeralTerminalPresetStore(),
    terminalTargetService: any TerminalTargetOpening = UnavailableTerminalTargetService(),
    launchAtLoginService: any LaunchAtLoginManaging = UnavailableLaunchAtLoginService(),
    notificationService: any AppNotificationManaging = UnavailableAppNotificationService(),
    composeTopologyService: any ComposeTopologyDeriving = ComposeTopologyService(),
    storageUsageService: any StorageUsageLoading = UnavailableStorageUsageService(),
    storageReclamationService: any StorageReclamationManaging =
      UnavailableStorageReclamationService(),
    virtualMachineStorageReclamationService:
      any VirtualMachineStorageReclamationManaging =
      UnavailableVirtualMachineStorageReclamationService(),
    machineService: any MachineManaging = AppleMachineManagementService(),
    machineConfigurationService: any MachineConfigurationManaging =
      UnavailableLinuxMachineConfigurationService(),
    imageBuildService: any ImageBuilding = AppleContainerBuildService(),
    registryService: any RegistryManaging = AppleRegistryService(),
    dockerCompatibilityService: any DockerCompatibilityManaging =
      UnavailableDockerCompatibilityService(),
    composeBridgeConformance: any ComposeBridgeConformanceReporting =
      SocktainerComposeConformanceService(),
    dockerComposeClientService: any DockerComposeClientInstalling =
      UnavailableDockerComposeClientService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol = VirtualMachineLibrary(),
    virtualMachineCloner: any VirtualMachineCloning = UnavailableVirtualMachineCloneService(),
    virtualMachineTransfer: any VirtualMachinePackageTransferring =
      UnavailableVirtualMachineTransferService(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineUSB: any MacVirtualMachineUSBManaging =
      UnavailableMacVirtualMachineUSBService(),
    virtualMachineAudio: any MacVirtualMachineAudioManaging =
      UnavailableMacVirtualMachineAudioService(),
    virtualMachineNetwork: any MacVirtualMachineNetworkManaging =
      UnavailableMacVirtualMachineNetworkService(),
    linuxVirtualMachineNetwork: any LinuxVirtualMachineNetworkManaging =
      UnavailableLinuxVirtualMachineNetworkService(),
    virtualMachineCompute: any MacVirtualMachineComputeManaging =
      UnavailableVirtualMachineComputeService(),
    linuxVirtualMachineCompute: any LinuxVirtualMachineComputeManaging =
      UnavailableVirtualMachineComputeService(),
    virtualMachineName: any MacVirtualMachineNameManaging =
      UnavailableVirtualMachineNameService(),
    linuxVirtualMachineName: any LinuxVirtualMachineNameManaging =
      UnavailableVirtualMachineNameService(),
    virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging =
      UnavailableMacVirtualMachineSharedDirectoryService(),
    linuxVirtualMachineSharedDirectories:
      any LinuxVirtualMachineSharedDirectoryManaging =
      UnavailableLinuxVirtualMachineSharedDirectoryService(),
    virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices = .unavailable,
    virtualMachineDiskSnapshots: any MacVirtualMachineDiskSnapshotManaging =
      UnavailableMacVirtualMachineDiskSnapshotService(),
    virtualMachineAvailability:
      any MacVirtualMachineAvailabilityChecking =
      StaticMacVirtualMachineAvailabilityChecker(value: .available),
    restoreImageDiscovery: any MacRestoreImageDiscovering = MacRestoreImageService(),
    restoreImageAcquisition: any RestoreImageAcquiring =
      RestoreImageAcquisitionService.standard(),
    restoreImageStoreRecovery: any RestoreImageStoreRecovering =
      NoopRestoreImageStoreRecoveryService(),
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.init(
      services: AppServices(
        containerService: containerService,
        containerShell: containerShellService,
        terminalPresets: terminalPresetService,
        terminalTargets: terminalTargetService,
        launchAtLogin: launchAtLoginService,
        notifications: notificationService,
        composeTopology: composeTopologyService,
        storageUsage: storageUsageService,
        storageReclamation: storageReclamationService,
        virtualMachineStorageReclamation:
          virtualMachineStorageReclamationService,
        machineService: machineService,
        machineConfiguration: machineConfigurationService,
        imageBuild: imageBuildService,
        registry: registryService,
        dockerCompatibility: dockerCompatibilityService,
        composeBridgeConformance: composeBridgeConformance,
        dockerComposeClient: dockerComposeClientService,
        virtualMachineLibrary: virtualMachineLibrary,
        virtualMachineCloner: virtualMachineCloner,
        virtualMachineTransfer: virtualMachineTransfer,
        virtualMachineInstaller: virtualMachineInstaller,
        virtualMachineRuntime: virtualMachineRuntime,
        virtualMachineUSB: virtualMachineUSB,
        virtualMachineAudio: virtualMachineAudio,
        virtualMachineNetwork: virtualMachineNetwork,
        linuxVirtualMachineNetwork: linuxVirtualMachineNetwork,
        virtualMachineCompute: virtualMachineCompute,
        linuxVirtualMachineCompute: linuxVirtualMachineCompute,
        virtualMachineName: virtualMachineName,
        linuxVirtualMachineName: linuxVirtualMachineName,
        virtualMachineSharedDirectories: virtualMachineSharedDirectories,
        linuxVirtualMachineSharedDirectories: linuxVirtualMachineSharedDirectories,
        virtualMachineDiskImages: virtualMachineDiskImages,
        virtualMachineDiskSnapshots: virtualMachineDiskSnapshots,
        virtualMachineAvailability: virtualMachineAvailability,
        restoreImageDiscovery: restoreImageDiscovery,
        restoreImageAcquisition: restoreImageAcquisition,
        restoreImageStoreRecovery: restoreImageStoreRecovery
      ),
      initialInventory: initialInventory,
      initialVirtualMachines: initialVirtualMachines
    )
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await recoverVirtualMachineState()
    await refresh()
  }

  private func recoverVirtualMachineState() async {
    do {
      let recoveryOutcome =
        try await services.virtualMachineInstaller.recoverInterruptedInstallations()
      guard recoveryOutcome == .recovered else {
        virtualMachineRecoveryErrorMessage =
          "Virtual machine recovery is waiting for another NativeContainers process to finish its active operation."
        return
      }
      let diskRecovery =
        try await services.virtualMachineDiskImages.recovery
        .recoverInterruptedDiskImageReplacements()
      let diskResizeRecovery =
        try await services.virtualMachineDiskImages.resizeRecovery
        .recoverInterruptedDiskImageResizes()
      try await services.restoreImageStoreRecovery.recover()
      if let failure = diskRecovery.failures.first {
        virtualMachineRecoveryErrorMessage =
          "Disk replacement recovery needs attention for \(diskRecovery.failures.count) virtual machine(s): \(failure.diagnostic)"
      } else if let failure = diskResizeRecovery.failures.first {
        virtualMachineRecoveryErrorMessage =
          "Virtual disk growth recovery needs attention for \(diskResizeRecovery.failures.count) virtual machine(s): \(failure.diagnostic)"
      } else if !diskRecovery.deferredMachineIDs.isEmpty {
        virtualMachineRecoveryErrorMessage =
          "Disk replacement recovery is waiting for another NativeContainers process to release \(diskRecovery.deferredMachineIDs.count) virtual machine(s)."
      } else if !diskResizeRecovery.deferredMachineIDs.isEmpty {
        virtualMachineRecoveryErrorMessage =
          "Virtual disk growth recovery is waiting for another NativeContainers process to release \(diskResizeRecovery.deferredMachineIDs.count) virtual machine(s)."
      } else {
        virtualMachineRecoveryErrorMessage = nil
      }
    } catch {
      virtualMachineRecoveryErrorMessage =
        "Virtual machine recovery: \(error.localizedDescription)"
    }
  }

  func refresh() async {
    guard !isRefreshing else {
      refreshRequested = true
      await withCheckedContinuation { continuation in
        refreshWaiters.append(continuation)
      }
      return
    }
    isRefreshing = true
    if virtualMachineRecoveryErrorMessage != nil {
      await recoverVirtualMachineState()
    }
    repeat {
      refreshRequested = false
      await performRefreshPass()
    } while refreshRequested
    isRefreshing = false

    let waiters = refreshWaiters
    refreshWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func performRefreshPass() async {
    var messages = virtualMachineRecoveryErrorMessage.map { [$0] } ?? []
    var didLoadContainerInventory = false
    var didLoadVirtualMachineLibrary = false

    do {
      let inventory = try await services.inventory.loadInventory()
      let topology = services.composeTopology.derive(from: inventory)
      didLoadContainerInventory = true
      systemInfo = inventory.system
      containers = inventory.containers
      images = inventory.images
      volumes = inventory.volumes
      networks = inventory.networks
      linuxMachines = inventory.machines
      runningContainerCount = inventory.containers.lazy.filter(\.state.isRunning).count
      runningLinuxMachineCount = inventory.machines.lazy.filter(\.state.isRunning).count
      composeTopology = topology
      containerInventoryRevision &+= 1
    } catch is CancellationError {
      return
    } catch {
      systemInfo = nil
      containers = []
      images = []
      volumes = []
      networks = []
      linuxMachines = []
      runningContainerCount = 0
      runningLinuxMachineCount = 0
      composeTopology = .empty
      messages.append("Apple container services: \(error.localizedDescription)")
    }

    do {
      var loadedVirtualMachines = try await services.virtualMachineLibrary.list()
      let referencedRestoreImages = Set(
        loadedVirtualMachines.compactMap(\.restoreImageURL)
      )
      do {
        if try await services.restoreImageStoreRecovery
          .recoverLegacyReferencesIfNeeded(referencedRestoreImages)
        {
          loadedVirtualMachines = try await services.virtualMachineLibrary.list()
        }
      } catch is CancellationError {
        return
      } catch {
        messages.append("Restore-image storage: \(error.localizedDescription)")
      }
      virtualMachines = loadedVirtualMachines
      didLoadVirtualMachineLibrary = true
      virtualMachineInventoryRevision &+= 1
      removeStaleVirtualMachineModels()
    } catch is CancellationError {
      return
    } catch {
      messages.append("Virtual machine library: \(error.localizedDescription)")
    }

    updateWorkspaceNavigation(
      reconcileMissingRoute: shouldReconcileWorkspaceRoute(
        didLoadContainerInventory: didLoadContainerInventory,
        didLoadVirtualMachineLibrary: didLoadVirtualMachineLibrary
      )
    )

    errorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    lastRefresh = Date()
  }

  private func refreshVirtualMachineStorageAfterMutation() async {
    storageOverviewModel.markVirtualMachineSnapshotStale()
    do {
      virtualMachines = try await services.virtualMachineLibrary.list()
      virtualMachineInventoryRevision &+= 1
      removeStaleVirtualMachineModels()
      updateWorkspaceNavigation()
    } catch {
      errorMessage = "Virtual machine library: \(error.localizedDescription)"
    }
    await storageOverviewModel.refreshVirtualMachinesAfterMutation()
  }

  func startContainer(id: String) async {
    await performMutation {
      try await self.services.containerLifecycle.startContainer(id: id)
    }
  }

  func stopContainer(id: String) async {
    await performMutation {
      try await self.services.containerLifecycle.stopContainer(id: id)
    }
  }

  func restartContainer(id: String) async {
    await performMutation {
      try await self.services.containerLifecycle.restartContainer(id: id)
    }
  }

  func forceStopContainer(id: String) async {
    await performMutation {
      try await self.services.containerLifecycle.forceStopContainer(id: id)
    }
  }

  func deleteContainer(id: String) async {
    await performMutation {
      try await self.services.containerLifecycle.deleteContainer(id: id)
    }
  }

  var virtualMachineAvailability: MacVirtualMachineAvailability {
    services.virtualMachineAvailability.availability()
  }

  func createVirtualMachineDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws {
    _ = try await services.virtualMachineLibrary.createDraft(
      name: name,
      guest: guest,
      resources: resources
    )
    virtualMachines = try await services.virtualMachineLibrary.list()
    updateWorkspaceNavigation()
  }

  @discardableResult
  func createLinuxVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest {
    let machine = try await services.linuxVirtualMachineCreator
      .createLinuxVirtualMachine(
        name: name,
        resources: resources,
        installationMediaURL: installationMediaURL
      )
    publishVirtualMachineManifest(machine)
    navigate(to: .macOSVirtualMachine(machine.id))
    return machine
  }

  func discardVirtualMachine(id: UUID) async {
    await performMutation {
      try await self.services.virtualMachineLibrary.discardVirtualMachine(id: id)
    }
  }

  @discardableResult
  func cloneVirtualMachine(id: UUID, name: String) async throws -> VirtualMachineManifest {
    let clone = try await services.virtualMachineCloner.cloneVirtualMachine(id: id, name: name)
    virtualMachines = try await services.virtualMachineLibrary.list()
    updateWorkspaceNavigation()
    navigate(to: .macOSVirtualMachine(clone.id))
    return clone
  }

  @discardableResult
  func exportVirtualMachine(
    id: UUID,
    to destinationURL: URL
  ) async throws -> VirtualMachineExportReceipt {
    try await services.virtualMachineTransfer.exportVirtualMachine(
      id: id,
      to: destinationURL
    )
  }

  @discardableResult
  func importVirtualMachine(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) async throws -> VirtualMachineManifest {
    let imported = try await services.virtualMachineTransfer.importVirtualMachine(
      from: sourceURL,
      mode: mode
    )
    publishVirtualMachineManifest(imported)
    navigate(to: .macOSVirtualMachine(imported.id))
    return imported
  }

  func prepareMacVirtualMachine(id: UUID, restoreImageURL: URL) async throws {
    let prepared = try await services.virtualMachineLibrary.prepareMacVM(
      id: id,
      restoreImageURL: restoreImageURL
    )
    publishVirtualMachineManifest(prepared)
  }

  func clearError() {
    errorMessage = nil
  }

  func currentWorkloadCreationDefaults() -> WorkloadCreationDefaults {
    services.workloadCreationDefaults.currentDefaults()
  }

  func makeContainerInspector(for container: ContainerRecord) -> ContainerInspectorModel {
    ContainerInspectorModel(
      containerID: container.id,
      allocatedCPUCount: container.cpuCount,
      service: services.containerInspector
    )
  }

  func makeLinuxMachineManagementModel() -> LinuxMachineManagementModel {
    LinuxMachineManagementModel(
      creator: services.machineCreator,
      lifecycle: services.machineLifecycle,
      configuration: services.machineConfiguration
    ) { [weak self] in
      await self?.refresh()
    }
  }

  func makeLinuxMachineCommandModel(
    for machine: LinuxMachineRecord
  ) -> LinuxMachineCommandModel {
    LinuxMachineCommandModel(
      machine: machine,
      service: services.machineCommands
    ) { [weak self] in
      await self?.refresh()
    }
  }

  func makeLinuxMachineTerminalModel(
    for machine: LinuxMachineRecord
  ) -> ContainerTerminalModel {
    let target = LinuxMachineIdentity(machine: machine)
    let service = services.machineTerminal
    return ContainerTerminalModel(containerID: machine.id) { _, request in
      try await service.openTerminal(
        in: target,
        request: try LinuxMachineTerminalRequest(containerRequest: request)
      )
    }
  }

  func makeContainerProvisioningModel() -> ContainerProvisioningModel {
    ContainerProvisioningModel(
      containerCreator: services.containerCreator,
      imageService: services.images,
      attachmentService: services.containerAttachments
    ) { [weak self] in
      await self?.refresh()
    }
  }

  func makeImageInspector(reference: String) -> ImageInspectorModel {
    ImageInspectorModel(reference: reference, service: services.images)
  }

  func makeImageOperations(reference: String? = nil) -> ImageOperationsModel {
    ImageOperationsModel(sourceReference: reference, service: services.images) { [weak self] in
      await self?.refresh()
    }
  }

  func makeVolumeManagementModel() -> VolumeManagementModel {
    VolumeManagementModel(service: services.volumes) { [weak self] in
      await self?.refresh()
    }
  }

  func makeNetworkManagementModel() -> NetworkManagementModel {
    NetworkManagementModel(service: services.networks) { [weak self] in
      await self?.refresh()
    }
  }

  func resolveContainerBrowserURL(_ target: ContainerBrowserTarget) async -> URL? {
    do {
      return try await services.browser.resolveContainerBrowserURL(target)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  var isBuildWorkspaceNavigationLocked: Bool {
    imageBuildWorkspaceModel.plan != nil
      || imageBuildWorkspaceModel.isWorking
      || builderWorkspaceModel.plan != nil
      || builderWorkspaceModel.isBusy
  }

  func selectSidebarDestination(_ destination: SidebarDestination) {
    _ = navigate(to: destination.workspaceRoute)
  }

  func canNavigate(to route: WorkspaceRoute) -> Bool {
    workspaceNavigation.canNavigate(
      to: route,
      lockedTo: isBuildWorkspaceNavigationLocked ? .builds : nil
    )
  }

  @discardableResult
  func navigate(to route: WorkspaceRoute) -> Bool {
    workspaceNavigation.navigate(
      to: route,
      lockedTo: isBuildWorkspaceNavigationLocked ? .builds : nil
    )
  }

  func presentQuickOpen() {
    workspaceNavigation.presentQuickOpen()
  }

  private func handleNotificationResponse(
    _ destination: AppNotificationDestination
  ) async {
    await loadIfNeeded()
    let route = destination.workspaceRoute
    guard !navigate(to: route) else { return }
    _ = navigate(to: route.baseRoute)
  }

  func makeImageBuildModel() -> ImageBuildModel {
    imageBuildWorkspaceModel
  }

  func makeImageBuildHistoryModel() -> ImageBuildHistoryModel {
    ImageBuildHistoryModel(service: services.imageBuildHistory)
  }

  func makeContainerBuilderManagementModel() -> ContainerBuilderManagementModel {
    builderWorkspaceModel
  }

  func makeAppOwnedBuildCacheModel() -> AppOwnedBuildCacheModel {
    appOwnedBuildCacheModel
  }

  func makeStorageOverviewModel() -> StorageOverviewModel {
    storageOverviewModel
  }

  func makeStorageReclamationModel() -> StorageReclamationModel {
    storageReclamationModel
  }

  func makeVirtualMachineStorageReclamationModel()
    -> VirtualMachineStorageReclamationModel
  {
    virtualMachineStorageReclamationModel
  }

  func makeRegistrySettingsModel() -> RegistrySettingsModel {
    RegistrySettingsModel(service: services.registry)
  }

  func makeLaunchAtLoginModel() -> LaunchAtLoginModel {
    launchAtLoginModel
  }

  func makeAppNotificationSettingsModel() -> AppNotificationSettingsModel {
    appNotificationSettingsModel
  }

  func makePerformanceBenchmarkModel() -> PerformanceBenchmarkModel {
    performanceBenchmarkModel
  }

  func makeFieldDiagnosticModel() -> FieldDiagnosticModel {
    fieldDiagnosticModel
  }

  func makeKubernetesClusterModel() -> KubernetesClusterModel {
    kubernetesClusterModel
  }

  func makeDockerCompatibilityModel() -> DockerCompatibilityModel {
    dockerCompatibilitySettingsModel
  }

  func makeComposeProjectWorkspaceModel() -> ComposeProjectWorkspaceModel {
    composeProjectWorkspaceModel
  }

  func makeContainerToolsModel(containerID: String) -> ContainerToolsModel {
    ContainerToolsModel(
      containerID: containerID,
      tooling: services.containerTools,
      shellDiscovery: services.containerShell
    )
  }

  func makeContainerTerminalModel(containerID: String) -> ContainerTerminalModel {
    ContainerTerminalModel(containerID: containerID, service: services.containerTerminal)
  }

  func makeTerminalWorkspaceModel(
    request: TerminalWindowRequest
  ) -> TerminalWorkspaceModel {
    TerminalWorkspaceModel(
      windowRequest: request,
      presetStore: services.terminalPresets
    ) { [self] target in
      makeIdentityPinnedTerminalModel(for: target)
    }
  }

  func makeIdentityPinnedTerminalModel(
    for target: TerminalTargetIdentity
  ) -> ContainerTerminalModel {
    let terminalTargets = services.terminalTargets
    return ContainerTerminalModel(containerID: target.id) { _, request in
      try await terminalTargets.openTerminal(for: target, request: request)
    }
  }

  func makeMacRestoreImagePreparationModel(
    for machine: VirtualMachineManifest
  ) -> MacRestoreImagePreparationModel {
    MacRestoreImagePreparationModel(
      machine: machine,
      discovery: services.restoreImageDiscovery,
      acquisition: services.restoreImageAcquisition,
      notifications: services.notifications
    ) { [self] restoreImageURL in
      try await prepareMacVirtualMachine(
        id: machine.id,
        restoreImageURL: restoreImageURL
      )
    }
  }

  func makeMacVirtualMachineInstallationModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineInstallationModel {
    MacVirtualMachineInstallationModel(
      machine: machine,
      installer: services.virtualMachineInstaller,
      notifications: services.notifications
    ) { [weak self] in
      await self?.refresh()
    }
  }

  func makeMacVirtualMachineRuntimeModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineRuntimeModel {
    if let model = macVirtualMachineRuntimeModels[machine.id] {
      return model
    }
    let model = MacVirtualMachineRuntimeModel(
      machineID: machine.id,
      service: services.virtualMachineRuntime
    )
    macVirtualMachineRuntimeModels[machine.id] = model
    return model
  }

  func makeMacVirtualMachineUSBModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineUSBModel {
    if let model = macVirtualMachineUSBModels[machine.id] {
      return model
    }
    let model = MacVirtualMachineUSBModel(
      machineID: machine.id,
      service: services.virtualMachineUSB,
      runtime: services.virtualMachineRuntime
    )
    macVirtualMachineUSBModels[machine.id] = model
    return model
  }

  func makeLinuxVirtualMachineRuntimeModel(
    for machine: VirtualMachineManifest
  ) -> LinuxVirtualMachineRuntimeModel {
    if let model = linuxVirtualMachineRuntimeModels[machine.id] {
      return model
    }
    let model = LinuxVirtualMachineRuntimeModel(
      machineID: machine.id,
      service: services.linuxVirtualMachineRuntime
    ) { [weak self] manifest in
      self?.publishVirtualMachineManifest(manifest)
    }
    linuxVirtualMachineRuntimeModels[machine.id] = model
    return model
  }

  func makeVirtualMachineDiskImageMaintenanceModel(
    for machine: VirtualMachineManifest
  ) -> VirtualMachineDiskImageMaintenanceModel {
    if let model = virtualMachineDiskImageMaintenanceModels[machine.id] {
      return model
    }
    let didSettle: @MainActor @Sendable () async -> Void
    switch machine.guest {
    case .macOS:
      let runtime = makeMacVirtualMachineRuntimeModel(for: machine)
      didSettle = { await runtime.refreshSavedState() }
    case .linux:
      let runtime = makeLinuxVirtualMachineRuntimeModel(for: machine)
      didSettle = { await runtime.refreshSavedState() }
    }
    let model = VirtualMachineDiskImageMaintenanceModel(
      machineID: machine.id,
      guest: machine.guest,
      migration: services.virtualMachineDiskImages.migration,
      rewrite: services.virtualMachineDiskImages.rewrite,
      resize: services.virtualMachineDiskImages.resize,
      didMutate: { [weak self] in
        await self?.refreshVirtualMachineStorageAfterMutation()
      },
      didSettle: didSettle
    )
    virtualMachineDiskImageMaintenanceModels[machine.id] = model
    return model
  }

  func makeMacVirtualMachineDiskSnapshotModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineDiskSnapshotModel {
    if let model = macVirtualMachineDiskSnapshotModels[machine.id] {
      return model
    }
    let runtime = makeMacVirtualMachineRuntimeModel(for: machine)
    let model = MacVirtualMachineDiskSnapshotModel(
      machineID: machine.id,
      initialConfiguration:
        machine.effectiveMacOSDiskSnapshotConfiguration,
      service: services.virtualMachineDiskSnapshots
    ) { [weak self] manifest in
      self?.publishVirtualMachineManifest(manifest)
      await self?.refreshVirtualMachineStorageAfterMutation()
    } didSettle: {
      await runtime.refreshSavedState()
    }
    macVirtualMachineDiskSnapshotModels[machine.id] = model
    return model
  }

  func makeMacVirtualMachineAudioModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineAudioModel {
    if let model = macVirtualMachineAudioModels[machine.id] {
      return model
    }
    let model = MacVirtualMachineAudioModel(
      machineID: machine.id,
      initialConfiguration: machine.effectiveAudioConfiguration,
      service: services.virtualMachineAudio
    )
    macVirtualMachineAudioModels[machine.id] = model
    return model
  }

  func makeMacVirtualMachineNetworkModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineNetworkModel {
    if let model = macVirtualMachineNetworkModels[machine.id] {
      return model
    }
    let model = MacVirtualMachineNetworkModel(
      machineID: machine.id,
      initialConfiguration: machine.effectiveNetworkConfiguration,
      service: services.virtualMachineNetwork
    )
    macVirtualMachineNetworkModels[machine.id] = model
    return model
  }

  func makeLinuxVirtualMachineNetworkModel(
    for machine: VirtualMachineManifest
  ) -> LinuxVirtualMachineNetworkModel {
    if let model = linuxVirtualMachineNetworkModels[machine.id] {
      return model
    }
    let model = LinuxVirtualMachineNetworkModel(
      machineID: machine.id,
      initialConfiguration: machine.effectiveNetworkConfiguration,
      service: services.linuxVirtualMachineNetwork
    )
    linuxVirtualMachineNetworkModels[machine.id] = model
    return model
  }

  func makeVirtualMachineComputeModel(
    for machine: VirtualMachineManifest
  ) -> VirtualMachineComputeModel {
    if let model = virtualMachineComputeModels[machine.id] {
      return model
    }
    let service: any VirtualMachineComputeManaging =
      switch machine.guest {
      case .macOS:
        services.virtualMachineCompute
      case .linux:
        services.linuxVirtualMachineCompute
      }
    let model = VirtualMachineComputeModel(
      machineID: machine.id,
      initialResources: machine.resources,
      service: service
    ) { [weak self] in
      await self?.refresh()
    }
    virtualMachineComputeModels[machine.id] = model
    return model
  }

  func makeVirtualMachineNameModel(
    for machine: VirtualMachineManifest
  ) -> VirtualMachineNameModel {
    if let model = virtualMachineNameModels[machine.id] {
      return model
    }
    let service: any VirtualMachineNameManaging =
      switch machine.guest {
      case .macOS:
        services.virtualMachineName
      case .linux:
        services.linuxVirtualMachineName
      }
    let model = VirtualMachineNameModel(
      machineID: machine.id,
      initialName: machine.name,
      service: service
    ) { [weak self] in
      await self?.refresh()
    }
    virtualMachineNameModels[machine.id] = model
    return model
  }

  func makeMacVirtualMachineSharedDirectoriesModel(
    for machine: VirtualMachineManifest
  ) -> MacVirtualMachineSharedDirectoriesModel {
    if let model = macVirtualMachineSharedDirectoryModels[machine.id] {
      return model
    }
    let model = MacVirtualMachineSharedDirectoriesModel(
      machineID: machine.id,
      service: services.virtualMachineSharedDirectories
    )
    macVirtualMachineSharedDirectoryModels[machine.id] = model
    return model
  }

  func makeLinuxVirtualMachineSharedDirectoriesModel(
    for machine: VirtualMachineManifest
  ) -> LinuxVirtualMachineSharedDirectoriesModel {
    if let model = linuxVirtualMachineSharedDirectoryModels[machine.id] {
      return model
    }
    let model = LinuxVirtualMachineSharedDirectoriesModel(
      machineID: machine.id,
      service: services.linuxVirtualMachineSharedDirectories
    )
    linuxVirtualMachineSharedDirectoryModels[machine.id] = model
    return model
  }

  private func publishVirtualMachineManifest(
    _ manifest: VirtualMachineManifest
  ) {
    if let index = virtualMachines.firstIndex(where: { $0.id == manifest.id }) {
      virtualMachines[index] = manifest
    } else {
      virtualMachines.append(manifest)
    }
    virtualMachines.sort {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    updateWorkspaceNavigation()
  }

  private func removeStaleVirtualMachineModels() {
    let currentIdentifiers = Set(virtualMachines.map(\.id))
    for identifier in Array(macVirtualMachineRuntimeModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineRuntimeModels.removeValue(forKey: identifier)?.stopObserving()
    }
    for identifier in Array(macVirtualMachineUSBModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineUSBModels.removeValue(forKey: identifier)?.stopObserving()
    }
    for identifier in Array(linuxVirtualMachineRuntimeModels.keys)
    where !currentIdentifiers.contains(identifier) {
      linuxVirtualMachineRuntimeModels.removeValue(forKey: identifier)?.stopObserving()
    }
    for identifier in Array(macVirtualMachineAudioModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineAudioModels.removeValue(forKey: identifier)
    }
    for identifier in Array(macVirtualMachineNetworkModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineNetworkModels.removeValue(forKey: identifier)
    }
    for identifier in Array(linuxVirtualMachineNetworkModels.keys)
    where !currentIdentifiers.contains(identifier) {
      linuxVirtualMachineNetworkModels.removeValue(forKey: identifier)
    }
    for identifier in Array(virtualMachineComputeModels.keys)
    where !currentIdentifiers.contains(identifier) {
      virtualMachineComputeModels.removeValue(forKey: identifier)
    }
    for identifier in Array(virtualMachineNameModels.keys)
    where !currentIdentifiers.contains(identifier) {
      virtualMachineNameModels.removeValue(forKey: identifier)
    }
    for identifier in Array(macVirtualMachineDiskSnapshotModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineDiskSnapshotModels.removeValue(forKey: identifier)
    }
    for identifier in Array(macVirtualMachineSharedDirectoryModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineSharedDirectoryModels.removeValue(forKey: identifier)
    }
    for identifier in Array(linuxVirtualMachineSharedDirectoryModels.keys)
    where !currentIdentifiers.contains(identifier) {
      linuxVirtualMachineSharedDirectoryModels.removeValue(forKey: identifier)
    }
    for identifier in Array(virtualMachineDiskImageMaintenanceModels.keys)
    where !currentIdentifiers.contains(identifier) {
      virtualMachineDiskImageMaintenanceModels.removeValue(forKey: identifier)?
        .cancelMaintenance()
    }
  }

  private func updateWorkspaceNavigation(reconcileMissingRoute: Bool = true) {
    workspaceNavigation.update(
      WorkspaceResourceSnapshot(
        composeProjects: composeProjects,
        containers: containers,
        images: images,
        volumes: volumes,
        networks: networks,
        linuxMachines: linuxMachines,
        macOSVirtualMachines: virtualMachines
      ),
      reconcileMissingRoute: reconcileMissingRoute
    )
  }

  private func shouldReconcileWorkspaceRoute(
    didLoadContainerInventory: Bool,
    didLoadVirtualMachineLibrary: Bool
  ) -> Bool {
    switch workspaceRoute {
    case .container, .composeProject, .image, .volume, .network, .linuxMachine:
      didLoadContainerInventory
    case .macOSVirtualMachine:
      didLoadVirtualMachineLibrary
    case .overview, .containers, .composeProjects, .images, .builds, .volumes, .networks,
      .linuxMachines, .kubernetes, .macOSVirtualMachines, .settings:
      true
    }
  }

  private func performMutation(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    do {
      try await operation()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
