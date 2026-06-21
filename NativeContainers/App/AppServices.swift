import ContainerAPIClient
import Foundation

struct AppServices: Sendable {
  let inventory: any ContainerInventoryLoading
  let containerLifecycle: any ContainerLifecycleManaging
  let containerCreator: any ContainerCreating
  let containerInspector: any ContainerInspecting
  let containerTools: any ContainerTooling
  let containerTerminal: any ContainerTerminalOpening
  let containerAttachments: any ContainerAttachmentEnvironmentLoading
  let machineCreator: any MachineCreating
  let machineLifecycle: any MachineLifecycleManaging
  let images: any ImageManaging
  let volumes: any VolumeManaging
  let networks: any NetworkManaging
  let browser: any ContainerBrowserResolving
  let imageBuild: any ImageBuilding
  let imageBuildHistory: any ImageBuildHistoryStoring
  let builder: any ContainerBuilderManaging
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
    containerAttachments: any ContainerAttachmentEnvironmentLoading,
    machineCreator: any MachineCreating,
    machineLifecycle: any MachineLifecycleManaging,
    images: any ImageManaging,
    volumes: any VolumeManaging,
    networks: any NetworkManaging,
    browser: any ContainerBrowserResolving,
    imageBuild: any ImageBuilding,
    imageBuildHistory: any ImageBuildHistoryStoring = NoopImageBuildHistoryStore(),
    builder: any ContainerBuilderManaging = AppleContainerBuilderManagementService(),
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
    self.containerAttachments = containerAttachments
    self.machineCreator = machineCreator
    self.machineLifecycle = machineLifecycle
    self.images = images
    self.volumes = volumes
    self.networks = networks
    self.browser = browser
    self.imageBuild = imageBuild
    self.imageBuildHistory = imageBuildHistory
    self.builder = builder
    self.registry = registry
    self.virtualMachineLibrary = virtualMachineLibrary
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
  }

  init(
    containerService: any ContainerManaging,
    machineService: any MachineManaging = AppleMachineManagementService(),
    imageBuild: any ImageBuilding,
    imageBuildHistory: any ImageBuildHistoryStoring = NoopImageBuildHistoryStore(),
    builder: any ContainerBuilderManaging = AppleContainerBuilderManagementService(),
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
    containerAttachments = containerService
    machineCreator = machineService
    machineLifecycle = machineService
    images = containerService
    volumes = containerService
    networks = containerService
    browser = containerService
    self.imageBuild = imageBuild
    self.imageBuildHistory = imageBuildHistory
    self.builder = builder
    self.registry = registry
    self.virtualMachineLibrary = virtualMachineLibrary
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
  }
}

enum AppCompositionRoot {
  static func live() -> AppServices {
    let mutationCoordinator = RuntimeMutationCoordinator.shared
    let buildExecutionCoordinator = RuntimeMutationCoordinator.imageBuilds
    let containerClient = ContainerClient()
    let machineTransport = AppleMachineXPCTransport()
    let infrastructureClient = AppleInfrastructureClient()
    let cleanupClient = AppleContainerCleanupClient()
    let containerReader = AppleContainerSnapshotReader(client: containerClient)
    let inventoryService = AppleRuntimeInventoryService(
      infrastructureClient: infrastructureClient,
      containerReader: containerReader,
      machineInventory: AppleLinuxMachineInventoryService(
        machineTransport: machineTransport
      )
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
    let attachmentService = AppleContainerAttachmentService(
      infrastructureClient: infrastructureClient,
      containerReader: containerReader
    )
    let lifecycleService = AppleContainerLifecycleService(
      containerClient: containerClient,
      attachmentService: attachmentService
    )
    let inspectionService = AppleContainerInspectionService(containerClient: containerClient)
    let toolService = AppleContainerToolService(containerClient: containerClient)
    let terminalService = AppleContainerTerminalService(
      terminalProcessLauncher: AppleContainerTerminalProcessLauncher(
        containerClient: containerClient
      )
    )
    let machineService = AppleMachineManagementService(
      runtime: AppleMachineRuntimeClient(
        machineTransport: machineTransport,
        containerKillClient: cleanupClient
      ),
      runtimeMutationCoordinator: mutationCoordinator
    )
    let builderManagementService = AppleContainerBuilderManagementService(
      runtimeMutationCoordinator: mutationCoordinator,
      buildExecutionCoordinator: buildExecutionCoordinator
    )
    let creationService = AppleContainerCreationService(
      containerClient: containerClient,
      attachmentService: attachmentService,
      lifecycleService: lifecycleService,
      ownedContainerRecovery: recoveryService,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let launchID = UUID()
    let imageBuildHistory = ImageBuildHistoryStore(launchID: launchID)
    let imageBuildService = RecordingImageBuildService(
      base: AppleContainerBuildService(
        runtimeMutationCoordinator: mutationCoordinator,
        buildExecutionCoordinator: buildExecutionCoordinator
      ),
      history: imageBuildHistory,
      launchID: launchID
    )
    return AppServices(
      inventory: inventoryService,
      containerLifecycle: lifecycleService,
      containerCreator: creationService,
      containerInspector: inspectionService,
      containerTools: toolService,
      containerTerminal: terminalService,
      containerAttachments: attachmentService,
      machineCreator: machineService,
      machineLifecycle: machineService,
      images: imageService,
      volumes: infrastructureService,
      networks: infrastructureService,
      browser: infrastructureService,
      imageBuild: imageBuildService,
      imageBuildHistory: imageBuildHistory,
      builder: builderManagementService,
      registry: AppleRegistryService(),
      virtualMachineLibrary: VirtualMachineLibrary(),
      restoreImageDiscovery: MacRestoreImageService(),
      restoreImageDownloader: RestoreImageDownloadService()
    )
  }
}
