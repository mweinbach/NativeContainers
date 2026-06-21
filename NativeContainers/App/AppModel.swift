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
  private lazy var composeProjectWorkspaceModel = ComposeProjectWorkspaceModel(
    service: services.composeProjectLifecycle
  ) { [weak self] in
    await self?.refresh()
  }

  @ObservationIgnored
  private var macVirtualMachineRuntimeModels: [UUID: MacVirtualMachineRuntimeModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineSharedDirectoryModels:
    [UUID: MacVirtualMachineSharedDirectoriesModel] = [:]

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
  }

  convenience init(
    containerService: any ContainerManaging = AppleContainerService(),
    containerShellService: any ContainerShellDiscovering = UnavailableContainerShellService(),
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
    virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging =
      UnavailableMacVirtualMachineSharedDirectoryService(),
    virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices = .unavailable,
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
        launchAtLogin: launchAtLoginService,
        notifications: notificationService,
        composeTopology: composeTopologyService,
        storageUsage: storageUsageService,
        storageReclamation: storageReclamationService,
        virtualMachineStorageReclamation:
          virtualMachineStorageReclamationService,
        machineService: machineService,
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
        virtualMachineSharedDirectories: virtualMachineSharedDirectories,
        virtualMachineDiskImages: virtualMachineDiskImages,
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
      try await services.restoreImageStoreRecovery.recover()
      if let failure = diskRecovery.failures.first {
        virtualMachineRecoveryErrorMessage =
          "Disk replacement recovery needs attention for \(diskRecovery.failures.count) virtual machine(s): \(failure.diagnostic)"
      } else if !diskRecovery.deferredMachineIDs.isEmpty {
        virtualMachineRecoveryErrorMessage =
          "Disk replacement recovery is waiting for another NativeContainers process to release \(diskRecovery.deferredMachineIDs.count) virtual machine(s)."
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
      removeStaleMacVirtualMachineRuntimeModels()
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
      removeStaleMacVirtualMachineRuntimeModels()
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
    if let index = virtualMachines.firstIndex(where: { $0.id == imported.id }) {
      virtualMachines[index] = imported
    } else {
      virtualMachines.append(imported)
    }
    virtualMachines.sort {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    updateWorkspaceNavigation()
    navigate(to: .macOSVirtualMachine(imported.id))
    return imported
  }

  func prepareMacVirtualMachine(id: UUID, restoreImageURL: URL) async throws {
    let prepared = try await services.virtualMachineLibrary.prepareMacVM(
      id: id,
      restoreImageURL: restoreImageURL
    )
    if let index = virtualMachines.firstIndex(where: { $0.id == prepared.id }) {
      virtualMachines[index] = prepared
    } else {
      virtualMachines.append(prepared)
    }
    virtualMachines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    updateWorkspaceNavigation()
  }

  func clearError() {
    errorMessage = nil
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
      lifecycle: services.machineLifecycle
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
      attachmentEnvironmentLoader: services.containerAttachments
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

  func makeVirtualMachineDiskImageMaintenanceModel(
    for machine: VirtualMachineManifest
  ) -> VirtualMachineDiskImageMaintenanceModel {
    if let model = virtualMachineDiskImageMaintenanceModels[machine.id] {
      return model
    }
    let runtime = makeMacVirtualMachineRuntimeModel(for: machine)
    let model = VirtualMachineDiskImageMaintenanceModel(
      machineID: machine.id,
      migration: services.virtualMachineDiskImages.migration,
      rewrite: services.virtualMachineDiskImages.rewrite
    ) { [weak self] in
      await self?.refreshVirtualMachineStorageAfterMutation()
    } didSettle: {
      await runtime.refreshSavedState()
    }
    virtualMachineDiskImageMaintenanceModels[machine.id] = model
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

  private func removeStaleMacVirtualMachineRuntimeModels() {
    let currentIdentifiers = Set(virtualMachines.map(\.id))
    for identifier in Array(macVirtualMachineRuntimeModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineRuntimeModels.removeValue(forKey: identifier)?.stopObserving()
    }
    for identifier in Array(macVirtualMachineSharedDirectoryModels.keys)
    where !currentIdentifiers.contains(identifier) {
      macVirtualMachineSharedDirectoryModels.removeValue(forKey: identifier)
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
      .linuxMachines, .macOSVirtualMachines, .settings:
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
