import ContainerAPIClient
import MachineAPIClient

struct AppServices: Sendable {
  let inventory: any ContainerInventoryLoading
  let containerLifecycle: any ContainerLifecycleManaging
  let containerCreator: any ContainerCreating
  let containerInspector: any ContainerInspecting
  let containerTools: any ContainerTooling
  let containerTerminal: any ContainerTerminalOpening
  let machineLifecycle: any MachineLifecycleManaging
  let images: any ImageManaging
  let volumes: any VolumeManaging
  let networks: any NetworkManaging
  let browser: any ContainerBrowserResolving
  let imageBuild: any ImageBuilding
  let registry: any RegistryManaging
  let virtualMachineLibrary: any VirtualMachineLibraryProtocol
  let restoreImageDiscovery: any MacRestoreImageDiscovering
  let restoreImageDownloader: any MacRestoreImageDownloading

  init(
    inventory: any ContainerInventoryLoading,
    containerLifecycle: any ContainerLifecycleManaging,
    containerCreator: any ContainerCreating,
    containerInspector: any ContainerInspecting,
    containerTools: any ContainerTooling,
    containerTerminal: any ContainerTerminalOpening,
    machineLifecycle: any MachineLifecycleManaging,
    images: any ImageManaging,
    volumes: any VolumeManaging,
    networks: any NetworkManaging,
    browser: any ContainerBrowserResolving,
    imageBuild: any ImageBuilding,
    registry: any RegistryManaging,
    virtualMachineLibrary: any VirtualMachineLibraryProtocol,
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageDownloader: any MacRestoreImageDownloading
  ) {
    self.inventory = inventory
    self.containerLifecycle = containerLifecycle
    self.containerCreator = containerCreator
    self.containerInspector = containerInspector
    self.containerTools = containerTools
    self.containerTerminal = containerTerminal
    self.machineLifecycle = machineLifecycle
    self.images = images
    self.volumes = volumes
    self.networks = networks
    self.browser = browser
    self.imageBuild = imageBuild
    self.registry = registry
    self.virtualMachineLibrary = virtualMachineLibrary
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
  }

  init(
    containerService: any ContainerManaging,
    imageBuild: any ImageBuilding,
    registry: any RegistryManaging,
    virtualMachineLibrary: any VirtualMachineLibraryProtocol,
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageDownloader: any MacRestoreImageDownloading
  ) {
    inventory = containerService
    containerLifecycle = containerService
    containerCreator = containerService
    containerInspector = containerService
    containerTools = containerService
    containerTerminal = containerService
    machineLifecycle = containerService
    images = containerService
    volumes = containerService
    networks = containerService
    browser = containerService
    self.imageBuild = imageBuild
    self.registry = registry
    self.virtualMachineLibrary = virtualMachineLibrary
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
  }
}

enum AppCompositionRoot {
  static func live() -> AppServices {
    let mutationCoordinator = RuntimeMutationCoordinator.shared
    let containerClient = ContainerClient()
    let machineClient = MachineClient()
    let infrastructureClient = AppleInfrastructureClient()
    let cleanupClient = AppleContainerCleanupClient()
    let containerReader = AppleContainerSnapshotReader(client: containerClient)
    let inventoryService = AppleRuntimeInventoryService(
      infrastructureClient: infrastructureClient,
      containerReader: containerReader,
      machineClient: machineClient
    )
    let infrastructureService = AppleInfrastructureService(
      infrastructureClient: infrastructureClient,
      containerReader: containerReader,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let imageService = AppleImageService(
      containerReader: containerReader,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let recoveryService = AppleOwnedContainerRecoveryService(
      cleanupClient: cleanupClient,
      ownershipLabel: AppleContainerOwnership.creationOperationLabel
    )
    let lifecycleService = AppleContainerLifecycleService(containerClient: containerClient)
    let inspectionService = AppleContainerInspectionService(containerClient: containerClient)
    let toolService = AppleContainerToolService(containerClient: containerClient)
    let terminalService = AppleContainerTerminalService(
      terminalProcessLauncher: AppleContainerTerminalProcessLauncher(
        containerClient: containerClient
      )
    )
    let machineLifecycleService = AppleMachineLifecycleService(machineClient: machineClient)
    let creationService = AppleContainerCreationService(
      containerClient: containerClient,
      infrastructureService: infrastructureService,
      lifecycleService: lifecycleService,
      ownedContainerRecovery: recoveryService,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let containerService = AppleContainerService(
      containerClient: containerClient,
      machineClient: machineClient,
      infrastructureClient: infrastructureClient,
      containerCleanupClient: cleanupClient,
      inventoryService: inventoryService,
      infrastructureService: infrastructureService,
      lifecycleService: lifecycleService,
      inspectionService: inspectionService,
      toolService: toolService,
      terminalService: terminalService,
      machineLifecycleService: machineLifecycleService,
      creationService: creationService,
      imageService: imageService,
      ownedContainerRecovery: recoveryService,
      runtimeMutationCoordinator: mutationCoordinator
    )

    return AppServices(
      inventory: inventoryService,
      containerLifecycle: lifecycleService,
      containerCreator: creationService,
      containerInspector: inspectionService,
      containerTools: toolService,
      containerTerminal: terminalService,
      machineLifecycle: machineLifecycleService,
      images: imageService,
      volumes: infrastructureService,
      networks: infrastructureService,
      browser: infrastructureService,
      imageBuild: AppleContainerBuildService(
        runtimeMutationCoordinator: mutationCoordinator
      ),
      registry: AppleRegistryService(),
      virtualMachineLibrary: VirtualMachineLibrary(),
      restoreImageDiscovery: MacRestoreImageService(),
      restoreImageDownloader: RestoreImageDownloadService()
    )
  }
}
