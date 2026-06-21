import ContainerAPIClient
import Foundation

struct VirtualMachineDiskImageMaintenanceServices: Sendable {
  let migration: any VirtualMachineDiskImageMigrationManaging
  let rewrite: any VirtualMachineDiskImageRewriting
  let recovery: any VirtualMachineDiskImageReplacementRecovering

  static var unavailable: Self {
    Self(
      migration: UnavailableVirtualMachineDiskImageMigrationService(),
      rewrite: UnavailableVirtualMachineDiskImageRewriteService(),
      recovery: UnavailableVirtualMachineDiskImageReplacementRecoveryService()
    )
  }
}

struct AppServices: Sendable {
  let inventory: any ContainerInventoryLoading
  let launchAtLogin: any LaunchAtLoginManaging
  let notifications: any AppNotificationManaging
  let composeTopology: any ComposeTopologyDeriving
  let storageUsage: any StorageUsageLoading
  let storageReclamation: any StorageReclamationManaging
  let virtualMachineStorageReclamation: any VirtualMachineStorageReclamationManaging
  let containerLifecycle: any ContainerLifecycleManaging
  let containerCreator: any ContainerCreating
  let containerInspector: any ContainerInspecting
  let containerTools: any ContainerTooling
  let containerShell: any ContainerShellDiscovering
  let containerTerminal: any ContainerTerminalOpening
  let terminalPresets: any TerminalPresetManaging
  let terminalTargets: any TerminalTargetOpening
  let containerAttachments: any ContainerAttachmentPreparing
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
  let virtualMachineTransfer: any VirtualMachinePackageTransferring
  let virtualMachineInstaller: any MacVirtualMachineInstalling
  let virtualMachineRuntime: any MacVirtualMachineRuntimeManaging
  let virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging
  let virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices
  let virtualMachineAvailability: any MacVirtualMachineAvailabilityChecking
  let restoreImageDiscovery: any MacRestoreImageDiscovering
  let restoreImageAcquisition: any RestoreImageAcquiring
  let restoreImageStoreRecovery: any RestoreImageStoreRecovering

  init(
    inventory: any ContainerInventoryLoading,
    launchAtLogin: any LaunchAtLoginManaging = UnavailableLaunchAtLoginService(),
    notifications: any AppNotificationManaging = UnavailableAppNotificationService(),
    composeTopology: any ComposeTopologyDeriving = ComposeTopologyService(),
    storageUsage: any StorageUsageLoading = UnavailableStorageUsageService(),
    storageReclamation: any StorageReclamationManaging =
      UnavailableStorageReclamationService(),
    virtualMachineStorageReclamation:
      any VirtualMachineStorageReclamationManaging =
      UnavailableVirtualMachineStorageReclamationService(),
    containerLifecycle: any ContainerLifecycleManaging,
    containerCreator: any ContainerCreating,
    containerInspector: any ContainerInspecting,
    containerTools: any ContainerTooling,
    containerShell: any ContainerShellDiscovering = UnavailableContainerShellService(),
    containerTerminal: any ContainerTerminalOpening,
    terminalPresets: any TerminalPresetManaging = EphemeralTerminalPresetStore(),
    terminalTargets: any TerminalTargetOpening = UnavailableTerminalTargetService(),
    containerAttachments: any ContainerAttachmentPreparing,
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
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageAcquisition: any RestoreImageAcquiring,
    restoreImageStoreRecovery: any RestoreImageStoreRecovering =
      NoopRestoreImageStoreRecoveryService()
  ) {
    self.inventory = inventory
    self.launchAtLogin = launchAtLogin
    self.notifications = notifications
    self.composeTopology = composeTopology
    self.storageUsage = storageUsage
    self.storageReclamation = storageReclamation
    self.virtualMachineStorageReclamation = virtualMachineStorageReclamation
    self.containerLifecycle = containerLifecycle
    self.containerCreator = containerCreator
    self.containerInspector = containerInspector
    self.containerTools = containerTools
    self.containerShell = containerShell
    self.containerTerminal = containerTerminal
    self.terminalPresets = terminalPresets
    self.terminalTargets = terminalTargets
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
    self.virtualMachineTransfer = virtualMachineTransfer
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.virtualMachineDiskImages = virtualMachineDiskImages
    self.virtualMachineAvailability = virtualMachineAvailability
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageAcquisition = restoreImageAcquisition
    self.restoreImageStoreRecovery = restoreImageStoreRecovery
  }

  init(
    containerService: any ContainerManaging,
    containerShell: any ContainerShellDiscovering = UnavailableContainerShellService(),
    terminalPresets: any TerminalPresetManaging = EphemeralTerminalPresetStore(),
    terminalTargets: any TerminalTargetOpening = UnavailableTerminalTargetService(),
    launchAtLogin: any LaunchAtLoginManaging = UnavailableLaunchAtLoginService(),
    notifications: any AppNotificationManaging = UnavailableAppNotificationService(),
    composeTopology: any ComposeTopologyDeriving = ComposeTopologyService(),
    storageUsage: any StorageUsageLoading = UnavailableStorageUsageService(),
    storageReclamation: any StorageReclamationManaging =
      UnavailableStorageReclamationService(),
    virtualMachineStorageReclamation:
      any VirtualMachineStorageReclamationManaging =
      UnavailableVirtualMachineStorageReclamationService(),
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
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageAcquisition: any RestoreImageAcquiring,
    restoreImageStoreRecovery: any RestoreImageStoreRecovering =
      NoopRestoreImageStoreRecoveryService()
  ) {
    inventory = containerService
    self.launchAtLogin = launchAtLogin
    self.notifications = notifications
    self.composeTopology = composeTopology
    self.storageUsage = storageUsage
    self.storageReclamation = storageReclamation
    self.virtualMachineStorageReclamation = virtualMachineStorageReclamation
    containerLifecycle = containerService
    containerCreator = containerService
    containerInspector = containerService
    containerTools = containerService
    self.containerShell = containerShell
    containerTerminal = containerService
    self.terminalPresets = terminalPresets
    self.terminalTargets = terminalTargets
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
    self.virtualMachineTransfer = virtualMachineTransfer
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.virtualMachineDiskImages = virtualMachineDiskImages
    self.virtualMachineAvailability = virtualMachineAvailability
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageAcquisition = restoreImageAcquisition
    self.restoreImageStoreRecovery = restoreImageStoreRecovery
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
    let sshAgentService = AppleContainerSSHAgentService()
    let commandExecutor = AppleRuntimeCommandExecutor(processClient: processClient)
    let containerReader = AppleContainerSnapshotReader(client: containerClient)
    let shellService = AppleContainerShellService(
      configurationLoader: AppleContainerShellConfigurationLoader(
        snapshotReader: containerReader
      ),
      commandExecutor: commandExecutor
    )
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
      containerReader: containerReader,
      sshAgentService: sshAgentService
    )
    let lifecycleService = AppleContainerLifecycleService(
      containerClient: containerClient,
      attachmentService: attachmentService,
      sshAgentService: sshAgentService
    )
    let inspectionService = AppleContainerInspectionService(containerClient: containerClient)
    let toolService = AppleContainerToolService(
      containerClient: containerClient,
      commandExecutor: commandExecutor
    )
    let terminalService = AppleContainerTerminalService(
      shellDiscovery: shellService,
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
      sshAgentService: sshAgentService,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let launchID = UUID()
    let imageBuildHistory = ImageBuildHistoryStore(launchID: launchID)
    let virtualMachineLibrary = VirtualMachineLibrary()
    let restoreImageStoreLocations = RestoreImageStoreLocations.standard()
    let restoreImageCacheURL = restoreImageStoreLocations.current
    let restoreImageCache = RestoreImageCacheService(
      cacheDirectoryURL: restoreImageCacheURL,
      excludesFromBackup: true
    )
    let legacyRestoreImageCache = RestoreImageCacheService(
      cacheDirectoryURL: restoreImageStoreLocations.legacyCache,
      excludesFromBackup: false
    )
    let restoreImageAcquisition = RestoreImageAcquisitionService(
      downloader: RestoreImageDownloadService(
        downloadDirectoryURL: restoreImageCacheURL,
        cache: restoreImageCache
      ),
      importer: RestoreImageImportService(
        cacheDirectoryURL: restoreImageCacheURL,
        cache: restoreImageCache
      ),
      cache: restoreImageCache
    )
    let restoreImageStoreMigration = RestoreImageStoreMigrationService(
      locations: restoreImageStoreLocations,
      legacyStore: legacyRestoreImageCache,
      currentStore: restoreImageCache,
      references: virtualMachineLibrary
    )
    let restoreImageStoreRecovery = RestoreImageStoreRecoveryService(
      legacyCache: legacyRestoreImageCache,
      currentCache: restoreImageCache,
      migration: restoreImageStoreMigration,
      references: virtualMachineLibrary
    )
    let storageUsage = StorageUsageService(
      appleRuntime: AppleRuntimeStorageUsageService(),
      virtualMachines: VirtualMachineStorageUsageService(
        inventory: virtualMachineLibrary
      )
    )
    let containerReclamation = AppleContainerReclamationService(
      transport: AppleContainerReclamationClient(),
      attachmentService: attachmentService,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let storageReclamation = StorageReclamationService(
      containers: containerReclamation,
      images: imageService,
      volumes: infrastructureService
    )
    let virtualMachineBundlePreparer = VirtualMachineBundlePreparationService()
    let virtualMachineCloner = VirtualMachineCloneService(
      store: virtualMachineLibrary,
      copier: FileVirtualMachineBundleCopier(preparer: virtualMachineBundlePreparer)
    )
    let virtualMachineTransfer = VirtualMachineTransferService(
      exportStore: virtualMachineLibrary,
      importStore: virtualMachineLibrary,
      preparer: virtualMachineBundlePreparer
    )
    let virtualMachineInstaller = MacVirtualMachineInstallationService(
      store: virtualMachineLibrary,
      engine: AppleMacVirtualMachineInstallationEngine()
    )
    let virtualMachineSavedStateStore = MacVirtualMachineSavedStateStore()
    let virtualMachineSavedState = MacVirtualMachineSavedStateService(
      store: virtualMachineSavedStateStore
    )
    let virtualMachineDiskImageReplacement =
      VirtualMachineDiskImageReplacementCoordinator(
        store: virtualMachineLibrary,
        savedStates: virtualMachineSavedState
      )
    let virtualMachineDiskImageMigration =
      VirtualMachineDiskImageMigrationService(
        coordinator: virtualMachineDiskImageReplacement
      )
    let virtualMachineDiskImageRewrite =
      VirtualMachineDiskImageRewriteService(
        coordinator: virtualMachineDiskImageReplacement
      )
    let virtualMachineStorageReclamation =
      VirtualMachineStorageReclamationService(
        savedStates: MacVirtualMachineSavedStateReclamationService(
          leasingStore: virtualMachineLibrary,
          store: virtualMachineSavedStateStore
        ),
        residue: VirtualMachineResidueReclamationService(
          inventory: virtualMachineLibrary
        ),
        restoreImages: RestoreImageCacheReclamationService(
          store: restoreImageCache
        ) {
          Set(
            try await virtualMachineLibrary.list()
              .compactMap(\.restoreImageURL)
          )
        }
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
      launchAtLogin: SMAppServiceLaunchAtLoginService(),
      notifications: UserNotificationService(),
      composeTopology: ComposeTopologyService(),
      storageUsage: storageUsage,
      storageReclamation: storageReclamation,
      virtualMachineStorageReclamation: virtualMachineStorageReclamation,
      containerLifecycle: lifecycleService,
      containerCreator: creationService,
      containerInspector: inspectionService,
      containerTools: toolService,
      containerShell: shellService,
      containerTerminal: terminalService,
      terminalPresets: TerminalPresetStore.standard(),
      terminalTargets: IdentityPinnedTerminalTargetService(
        inventory: inventoryService,
        containerTerminal: terminalService,
        machineTerminal: machineProcessService
      ),
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
      virtualMachineTransfer: virtualMachineTransfer,
      virtualMachineInstaller: virtualMachineInstaller,
      virtualMachineRuntime: virtualMachineRuntime,
      virtualMachineSharedDirectories: virtualMachineSharedDirectories,
      virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices(
        migration: virtualMachineDiskImageMigration,
        rewrite: virtualMachineDiskImageRewrite,
        recovery: virtualMachineDiskImageReplacement
      ),
      virtualMachineAvailability:
        AppleMacVirtualMachineAvailabilityChecker(),
      restoreImageDiscovery: MacRestoreImageService(),
      restoreImageAcquisition: restoreImageAcquisition,
      restoreImageStoreRecovery: restoreImageStoreRecovery
    )
  }
}
