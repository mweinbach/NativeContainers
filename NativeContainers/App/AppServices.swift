import ContainerAPIClient
import Foundation

struct AppServices: Sendable {
  let inventory: any ContainerInventoryLoading
  let composeTopology: any ComposeTopologyDeriving
  let containerLifecycle: any ContainerLifecycleManaging
  let containerCreator: any ContainerCreating
  let containerInspector: any ContainerInspecting
  let containerTools: any ContainerTooling
  let containerTerminal: any ContainerTerminalOpening
  let containerAttachments: any ContainerAttachmentEnvironmentLoading
  let machineCreator: any MachineCreating
  let machineLifecycle: any MachineLifecycleManaging
  let machineCommands: any MachineCommandRunning
  let machineTerminal: any MachineTerminalOpening
  let images: any ImageManaging
  let volumes: any VolumeManaging
  let networks: any NetworkManaging
  let browser: any ContainerBrowserResolving
  let imageBuild: any ImageBuilding
  let imageBuildHistory: any ImageBuildHistoryStoring
  let builder: any ContainerBuilderManaging
  let appOwnedBuildCache: any AppOwnedBuildCacheManaging
  let registry: any RegistryManaging
  let dockerCompatibility: any DockerCompatibilityManaging
  let composeBridgeConformance: any ComposeBridgeConformanceReporting
  let dockerComposeClient: any DockerComposeClientInstalling
  let composeProjectLifecycle: any ComposeProjectLifecycleManaging
  let virtualMachineLibrary: any VirtualMachineLibraryProtocol
  let virtualMachineCloner: any VirtualMachineCloning
  let virtualMachineInstaller: any MacVirtualMachineInstalling
  let virtualMachineRuntime: any MacVirtualMachineRuntimeManaging
  let virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging
  let virtualMachineAvailability: any MacVirtualMachineAvailabilityChecking
  let restoreImageDiscovery: any MacRestoreImageDiscovering
  let restoreImageDownloader: any MacRestoreImageDownloading
  let restoreImageImporter: any MacRestoreImageImporting

  init(
    inventory: any ContainerInventoryLoading,
    composeTopology: any ComposeTopologyDeriving = ComposeTopologyService(),
    containerLifecycle: any ContainerLifecycleManaging,
    containerCreator: any ContainerCreating,
    containerInspector: any ContainerInspecting,
    containerTools: any ContainerTooling,
    containerTerminal: any ContainerTerminalOpening,
    containerAttachments: any ContainerAttachmentEnvironmentLoading,
    machineCreator: any MachineCreating,
    machineLifecycle: any MachineLifecycleManaging,
    machineCommands: any MachineCommandRunning = UnavailableLinuxMachineToolService(),
    machineTerminal: any MachineTerminalOpening = UnavailableLinuxMachineToolService(),
    images: any ImageManaging,
    volumes: any VolumeManaging,
    networks: any NetworkManaging,
    browser: any ContainerBrowserResolving,
    imageBuild: any ImageBuilding,
    imageBuildHistory: any ImageBuildHistoryStoring = NoopImageBuildHistoryStore(),
    builder: any ContainerBuilderManaging = AppleContainerBuilderManagementService(),
    appOwnedBuildCache: any AppOwnedBuildCacheManaging = AppleAppOwnedBuildCacheService(),
    registry: any RegistryManaging,
    dockerCompatibility: any DockerCompatibilityManaging =
      UnavailableDockerCompatibilityService(),
    composeBridgeConformance: any ComposeBridgeConformanceReporting =
      SocktainerComposeConformanceService(),
    dockerComposeClient: any DockerComposeClientInstalling =
      UnavailableDockerComposeClientService(),
    composeProjectLifecycle: any ComposeProjectLifecycleManaging =
      UnavailableComposeProjectLifecycleService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol,
    virtualMachineCloner: any VirtualMachineCloning = UnavailableVirtualMachineCloneService(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging =
      UnavailableMacVirtualMachineSharedDirectoryService(),
    virtualMachineAvailability:
      any MacVirtualMachineAvailabilityChecking =
      StaticMacVirtualMachineAvailabilityChecker(value: .available),
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageDownloader: any MacRestoreImageDownloading,
    restoreImageImporter: any MacRestoreImageImporting = RestoreImageImportService()
  ) {
    self.inventory = inventory
    self.composeTopology = composeTopology
    self.containerLifecycle = containerLifecycle
    self.containerCreator = containerCreator
    self.containerInspector = containerInspector
    self.containerTools = containerTools
    self.containerTerminal = containerTerminal
    self.containerAttachments = containerAttachments
    self.machineCreator = machineCreator
    self.machineLifecycle = machineLifecycle
    self.machineCommands = machineCommands
    self.machineTerminal = machineTerminal
    self.images = images
    self.volumes = volumes
    self.networks = networks
    self.browser = browser
    self.imageBuild = imageBuild
    self.imageBuildHistory = imageBuildHistory
    self.builder = builder
    self.appOwnedBuildCache = appOwnedBuildCache
    self.registry = registry
    self.dockerCompatibility = dockerCompatibility
    self.composeBridgeConformance = composeBridgeConformance
    self.dockerComposeClient = dockerComposeClient
    self.composeProjectLifecycle = composeProjectLifecycle
    self.virtualMachineLibrary = virtualMachineLibrary
    self.virtualMachineCloner = virtualMachineCloner
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.virtualMachineAvailability = virtualMachineAvailability
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
    self.restoreImageImporter = restoreImageImporter
  }

  init(
    containerService: any ContainerManaging,
    composeTopology: any ComposeTopologyDeriving = ComposeTopologyService(),
    machineService: any MachineManaging = AppleMachineManagementService(),
    machineCommands: any MachineCommandRunning = UnavailableLinuxMachineToolService(),
    machineTerminal: any MachineTerminalOpening = UnavailableLinuxMachineToolService(),
    imageBuild: any ImageBuilding,
    imageBuildHistory: any ImageBuildHistoryStoring = NoopImageBuildHistoryStore(),
    builder: any ContainerBuilderManaging = AppleContainerBuilderManagementService(),
    appOwnedBuildCache: any AppOwnedBuildCacheManaging = AppleAppOwnedBuildCacheService(),
    registry: any RegistryManaging,
    dockerCompatibility: any DockerCompatibilityManaging =
      UnavailableDockerCompatibilityService(),
    composeBridgeConformance: any ComposeBridgeConformanceReporting =
      SocktainerComposeConformanceService(),
    dockerComposeClient: any DockerComposeClientInstalling =
      UnavailableDockerComposeClientService(),
    composeProjectLifecycle: any ComposeProjectLifecycleManaging =
      UnavailableComposeProjectLifecycleService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol,
    virtualMachineCloner: any VirtualMachineCloning = UnavailableVirtualMachineCloneService(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging =
      UnavailableMacVirtualMachineSharedDirectoryService(),
    virtualMachineAvailability:
      any MacVirtualMachineAvailabilityChecking =
      StaticMacVirtualMachineAvailabilityChecker(value: .available),
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageDownloader: any MacRestoreImageDownloading,
    restoreImageImporter: any MacRestoreImageImporting = RestoreImageImportService()
  ) {
    inventory = containerService
    self.composeTopology = composeTopology
    containerLifecycle = containerService
    containerCreator = containerService
    containerInspector = containerService
    containerTools = containerService
    containerTerminal = containerService
    containerAttachments = containerService
    machineCreator = machineService
    machineLifecycle = machineService
    self.machineCommands = machineCommands
    self.machineTerminal = machineTerminal
    images = containerService
    volumes = containerService
    networks = containerService
    browser = containerService
    self.imageBuild = imageBuild
    self.imageBuildHistory = imageBuildHistory
    self.builder = builder
    self.appOwnedBuildCache = appOwnedBuildCache
    self.registry = registry
    self.dockerCompatibility = dockerCompatibility
    self.composeBridgeConformance = composeBridgeConformance
    self.dockerComposeClient = dockerComposeClient
    self.composeProjectLifecycle = composeProjectLifecycle
    self.virtualMachineLibrary = virtualMachineLibrary
    self.virtualMachineCloner = virtualMachineCloner
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.virtualMachineAvailability = virtualMachineAvailability
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageDownloader = restoreImageDownloader
    self.restoreImageImporter = restoreImageImporter
  }
}

enum AppCompositionRoot {
  @MainActor
  static func live() -> AppServices {
    let mutationCoordinator = RuntimeMutationCoordinator.shared
    let buildExecutionCoordinator = RuntimeMutationCoordinator.imageBuilds
    let containerClient = ContainerClient()
    let machineTransport = AppleMachineXPCTransport()
    let infrastructureClient = AppleInfrastructureClient()
    let cleanupClient = AppleContainerCleanupClient()
    let processClient = AppleContainerProcessXPCClient()
    let commandExecutor = AppleRuntimeCommandExecutor(processClient: processClient)
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
    let toolService = AppleContainerToolService(
      containerClient: containerClient,
      commandExecutor: commandExecutor
    )
    let terminalService = AppleContainerTerminalService(
      terminalProcessLauncher: AppleContainerTerminalProcessLauncher(
        containerClient: containerClient,
        processClient: processClient
      )
    )
    let machineService = AppleMachineManagementService(
      runtime: AppleMachineRuntimeClient(
        machineTransport: machineTransport,
        processClient: processClient,
        containerKillClient: cleanupClient
      ),
      runtimeMutationCoordinator: mutationCoordinator
    )
    let machineProcessService = AppleLinuxMachineProcessService(
      targetResolver: AppleLinuxMachineProcessTargetResolver(
        lifecycle: machineService,
        machineTransport: machineTransport
      ),
      commandExecutor: commandExecutor,
      processClient: processClient
    )
    let builderManagementService = AppleContainerBuilderManagementService(
      runtimeMutationCoordinator: mutationCoordinator,
      buildExecutionCoordinator: buildExecutionCoordinator
    )
    let appOwnedBuildCacheService = AppleAppOwnedBuildCacheService(
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
    let virtualMachineLibrary = VirtualMachineLibrary()
    let virtualMachineCloner = VirtualMachineCloneService(store: virtualMachineLibrary)
    let virtualMachineInstaller = MacVirtualMachineInstallationService(
      store: virtualMachineLibrary,
      engine: AppleMacVirtualMachineInstallationEngine()
    )
    let virtualMachineSavedState = MacVirtualMachineSavedStateService(
      store: MacVirtualMachineSavedStateStore()
    )
    let virtualMachineRuntime = MacVirtualMachineRuntimeService(
      leasingStore: virtualMachineLibrary,
      engine: AppleMacVirtualMachineRuntimeEngine(),
      savedStateService: virtualMachineSavedState
    )
    let virtualMachineSharedDirectories = MacVirtualMachineSharedDirectoryService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState
    )
    let socktainerInstaller = SocktainerInstallService()
    let socktainerProcess = SocktainerProcessService()
    let dockerCompatibility = DockerCompatibilityService(
      installer: socktainerInstaller,
      process: socktainerProcess,
      dockerContext: DockerContextService(socketURL: socktainerProcess.socketURL)
    )
    let dockerComposeClient = DockerComposeClientInstallService()
    let composeConfigService = DockerComposeConfigService(
      composeClient: dockerComposeClient
    )
    let composeJournal = ComposeOperationJournal(
      directoryURL: FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0].appending(
        path: "NativeContainers-Compose-Operations",
        directoryHint: .isDirectory
      )
    )
    let composeMutationExecutor = AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: mutationCoordinator,
      containers: AppleComposeContainerMutationClient(client: containerClient),
      infrastructure: infrastructureClient,
      inventory: inventoryService,
      journal: composeJournal
    )
    let composeProjectLifecycle = ComposeProjectLifecycleService(
      configRenderer: composeConfigService,
      inventory: inventoryService,
      executionTool: composeConfigService,
      mutationExecutor: composeMutationExecutor,
      journal: composeJournal
    )
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
      composeTopology: ComposeTopologyService(),
      containerLifecycle: lifecycleService,
      containerCreator: creationService,
      containerInspector: inspectionService,
      containerTools: toolService,
      containerTerminal: terminalService,
      containerAttachments: attachmentService,
      machineCreator: machineService,
      machineLifecycle: machineService,
      machineCommands: machineProcessService,
      machineTerminal: machineProcessService,
      images: imageService,
      volumes: infrastructureService,
      networks: infrastructureService,
      browser: infrastructureService,
      imageBuild: imageBuildService,
      imageBuildHistory: imageBuildHistory,
      builder: builderManagementService,
      appOwnedBuildCache: appOwnedBuildCacheService,
      registry: AppleRegistryService(),
      dockerCompatibility: dockerCompatibility,
      composeBridgeConformance: SocktainerComposeConformanceService(),
      dockerComposeClient: dockerComposeClient,
      composeProjectLifecycle: composeProjectLifecycle,
      virtualMachineLibrary: virtualMachineLibrary,
      virtualMachineCloner: virtualMachineCloner,
      virtualMachineInstaller: virtualMachineInstaller,
      virtualMachineRuntime: virtualMachineRuntime,
      virtualMachineSharedDirectories: virtualMachineSharedDirectories,
      virtualMachineAvailability:
        AppleMacVirtualMachineAvailabilityChecker(),
      restoreImageDiscovery: MacRestoreImageService(),
      restoreImageDownloader: RestoreImageDownloadService(),
      restoreImageImporter: RestoreImageImportService()
    )
  }
}
