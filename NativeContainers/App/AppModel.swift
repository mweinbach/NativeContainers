import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  var selection: SidebarDestination = .overview

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
  private var hasLoaded = false
  private var refreshRequested = false
  private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    services: AppServices,
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.services = services
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
  }

  convenience init(
    containerService: any ContainerManaging = AppleContainerService(),
    imageBuildService: any ImageBuilding = AppleContainerBuildService(),
    registryService: any RegistryManaging = AppleRegistryService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol = VirtualMachineLibrary(),
    restoreImageDiscovery: any MacRestoreImageDiscovering = MacRestoreImageService(),
    restoreImageDownloader: any MacRestoreImageDownloading = RestoreImageDownloadService(),
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.init(
      services: AppServices(
        containerService: containerService,
        imageBuild: imageBuildService,
        registry: registryService,
        virtualMachineLibrary: virtualMachineLibrary,
        restoreImageDiscovery: restoreImageDiscovery,
        restoreImageDownloader: restoreImageDownloader
      ),
      initialInventory: initialInventory,
      initialVirtualMachines: initialVirtualMachines
    )
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await refresh()
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
    var messages: [String] = []

    do {
      let inventory = try await services.inventory.loadInventory()
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
    } catch {
      messages.append("Virtual machine library: \(error.localizedDescription)")
    }

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

  func startMachine(id: String) async {
    await performMutation {
      try await self.services.machineLifecycle.startMachine(id: id)
    }
  }

  func stopMachine(id: String) async {
    await performMutation {
      try await self.services.machineLifecycle.stopMachine(id: id)
    }
  }

  func deleteMachine(id: String) async {
    await performMutation {
      try await self.services.machineLifecycle.deleteMachine(id: id)
    }
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
  }

  func prepareMacVirtualMachine(id: UUID, restoreImageURL: URL) async throws {
    _ = try await services.virtualMachineLibrary.prepareMacVM(
      id: id,
      restoreImageURL: restoreImageURL
    )
    virtualMachines = try await services.virtualMachineLibrary.list()
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

  func makeImageBuildModel() -> ImageBuildModel {
    ImageBuildModel(service: services.imageBuild) { [weak self] in
      await self?.refresh()
    }
  }

  func makeContainerBuilderManagementModel() -> ContainerBuilderManagementModel {
    ContainerBuilderManagementModel(service: services.builder) { [weak self] in
      await self?.refresh()
    }
  }

  func makeRegistrySettingsModel() -> RegistrySettingsModel {
    RegistrySettingsModel(service: services.registry)
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
      downloader: services.restoreImageDownloader
    ) { [self] restoreImageURL in
      try await prepareMacVirtualMachine(
        id: machine.id,
        restoreImageURL: restoreImageURL
      )
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
