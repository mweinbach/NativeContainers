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
  private(set) var virtualMachines: [VirtualMachineManifest] = []
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?
  private(set) var errorMessage: String?

  private let services: AppServices

  @ObservationIgnored
  private lazy var imageBuildWorkspaceModel = ImageBuildModel(
    service: services.imageBuild
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
  private lazy var dockerCompatibilitySettingsModel = DockerCompatibilityModel(
    service: services.dockerCompatibility
  )

  @ObservationIgnored
  private var macVirtualMachineRuntimeModels: [UUID: MacVirtualMachineRuntimeModel] = [:]

  @ObservationIgnored
  private var macVirtualMachineSharedDirectoryModels:
    [UUID: MacVirtualMachineSharedDirectoriesModel] = [:]

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
      systemInfo = initialInventory.system
      containers = initialInventory.containers
      images = initialInventory.images
      volumes = initialInventory.volumes
      networks = initialInventory.networks
      linuxMachines = initialInventory.machines
      virtualMachines = initialVirtualMachines
      hasLoaded = true
      lastRefresh = Date()
    }
    updateWorkspaceNavigation()
  }

  convenience init(
    containerService: any ContainerManaging = AppleContainerService(),
    machineService: any MachineManaging = AppleMachineManagementService(),
    imageBuildService: any ImageBuilding = AppleContainerBuildService(),
    registryService: any RegistryManaging = AppleRegistryService(),
    dockerCompatibilityService: any DockerCompatibilityManaging =
      UnavailableDockerCompatibilityService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol = VirtualMachineLibrary(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging =
      UnavailableMacVirtualMachineSharedDirectoryService(),
    virtualMachineAvailability:
      any MacVirtualMachineAvailabilityChecking =
      StaticMacVirtualMachineAvailabilityChecker(value: .available),
    restoreImageDiscovery: any MacRestoreImageDiscovering = MacRestoreImageService(),
    restoreImageDownloader: any MacRestoreImageDownloading = RestoreImageDownloadService(),
    restoreImageImporter: any MacRestoreImageImporting = RestoreImageImportService(),
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.init(
      services: AppServices(
        containerService: containerService,
        machineService: machineService,
        imageBuild: imageBuildService,
        registry: registryService,
        dockerCompatibility: dockerCompatibilityService,
        virtualMachineLibrary: virtualMachineLibrary,
        virtualMachineInstaller: virtualMachineInstaller,
        virtualMachineRuntime: virtualMachineRuntime,
        virtualMachineSharedDirectories: virtualMachineSharedDirectories,
        virtualMachineAvailability: virtualMachineAvailability,
        restoreImageDiscovery: restoreImageDiscovery,
        restoreImageDownloader: restoreImageDownloader,
        restoreImageImporter: restoreImageImporter
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
      let referencedRestoreImages = Set(
        try await services.virtualMachineLibrary.list().compactMap(\.restoreImageURL)
      )
      try await services.restoreImageImporter.recoverPendingImports(
        referencedURLs: referencedRestoreImages
      )
      virtualMachineRecoveryErrorMessage = nil
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
      didLoadContainerInventory = true
      systemInfo = inventory.system
      containers = inventory.containers
      images = inventory.images
      volumes = inventory.volumes
      networks = inventory.networks
      linuxMachines = inventory.machines
    } catch is CancellationError {
      return
    } catch {
      systemInfo = nil
      containers = []
      images = []
      volumes = []
      networks = []
      linuxMachines = []
      messages.append("Apple container services: \(error.localizedDescription)")
    }

    do {
      virtualMachines = try await services.virtualMachineLibrary.list()
      didLoadVirtualMachineLibrary = true
      removeStaleMacVirtualMachineRuntimeModels()
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

  func makeImageBuildModel() -> ImageBuildModel {
    imageBuildWorkspaceModel
  }

  func makeImageBuildHistoryModel() -> ImageBuildHistoryModel {
    ImageBuildHistoryModel(service: services.imageBuildHistory)
  }

  func makeContainerBuilderManagementModel() -> ContainerBuilderManagementModel {
    builderWorkspaceModel
  }

  func makeRegistrySettingsModel() -> RegistrySettingsModel {
    RegistrySettingsModel(service: services.registry)
  }

  func makeDockerCompatibilityModel() -> DockerCompatibilityModel {
    dockerCompatibilitySettingsModel
  }

  func makeContainerToolsModel(containerID: String) -> ContainerToolsModel {
    ContainerToolsModel(containerID: containerID, service: services.containerTools)
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
      downloader: services.restoreImageDownloader,
      importer: services.restoreImageImporter
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
      installer: services.virtualMachineInstaller
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
  }

  private func updateWorkspaceNavigation(reconcileMissingRoute: Bool = true) {
    workspaceNavigation.update(
      WorkspaceResourceSnapshot(
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
    case .container, .image, .volume, .network, .linuxMachine:
      didLoadContainerInventory
    case .macOSVirtualMachine:
      didLoadVirtualMachineLibrary
    case .overview, .containers, .images, .builds, .volumes, .networks,
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
