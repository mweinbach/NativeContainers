import ContainerAPIClient
import Foundation

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
    let machineInventoryService = AppleLinuxMachineInventoryService(
      machineTransport: machineTransport
    )
    let inventoryService = AppleRuntimeInventoryService(
      infrastructureClient: infrastructureClient,
      containerReader: containerReader,
      machineInventory: machineInventoryService
    )
    let performanceBenchmarkService = PerformanceBenchmarkService(
      scenarios: [
        InventoryPerformanceBenchmarkScenario(inventory: inventoryService),
        PrivateDiskPerformanceBenchmarkScenario(
          workspaceDirectoryURL: FileManager.default.temporaryDirectory
            .appending(path: "NativeContainers-Performance")
        ),
        LoopbackNetworkPerformanceBenchmarkScenario(),
      ]
    )
    let fieldDiagnosticService: any FieldDiagnosticManaging =
      AppExecutionContext.current.allowsSystemReportCollection
      ? MetricKitFieldDiagnosticService()
      : UnavailableFieldDiagnosticService()
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
    let machineConfigurationService = AppleLinuxMachineConfigurationService(
      machineTransport: machineTransport,
      runtimeMutationCoordinator: mutationCoordinator
    )
    let machineProcessTargetResolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: machineService,
      machineTransport: machineTransport
    )
    let machineProcessService = AppleLinuxMachineProcessService(
      targetResolver: machineProcessTargetResolver,
      commandExecutor: commandExecutor,
      processClient: processClient
    )
    let kubernetesStore = KubernetesClusterDescriptorStore()
    let kubernetesRootCommands = AppleKubernetesMachineRootCommandService(
      targetResolver: machineProcessTargetResolver,
      commandExecutor: commandExecutor
    )
    let kubernetesRunningTargetResolver =
      AppleKubernetesRunningClusterTargetResolver(
        store: kubernetesStore,
        machineInventory: machineInventoryService
      )
    let kubernetesPodTerminal = AppleKubernetesPodTerminalService(
      runningTargetResolver: kubernetesRunningTargetResolver,
      rootCommands: kubernetesRootCommands,
      machineProcessTargetResolver: machineProcessTargetResolver,
      sessionLauncher: AppleKubernetesPodTerminalSessionLauncher(
        processClient: processClient
      )
    )
    let kubernetesService = AppleKubernetesClusterService(
      machineCreator: machineService,
      machineLifecycle: machineService,
      machineInventory: machineInventoryService,
      rootCommands: kubernetesRootCommands,
      store: kubernetesStore
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
    let linuxVirtualMachineCreator = LinuxVirtualMachineCreationService(
      library: virtualMachineLibrary
    )
    let virtualMachineCloner = VirtualMachineCloneService(
      store: virtualMachineLibrary,
      copier: FileVirtualMachineBundleCopier(preparer: virtualMachineBundlePreparer)
    )
    let virtualMachineTransfer = VirtualMachineTransferService(
      exportStore: virtualMachineLibrary,
      importStore: virtualMachineLibrary,
      preparer: virtualMachineBundlePreparer
    )
    let virtualMachineNetworkPool = AppleVirtualMachineVmnetNetworkPool()
    let virtualMachineNetworkDeviceFactory = AppleVirtualMachineNetworkDeviceFactory(
      vmnetNetworks: virtualMachineNetworkPool
    )
    let virtualMachineComputeLimits = AppleVirtualMachineComputeLimits.current()
    let virtualMachineConfigurationFactory = AppleMacVirtualMachineConfigurationFactory(
      networkDeviceFactory: virtualMachineNetworkDeviceFactory
    )
    let linuxVirtualMachineConfigurationFactory =
      AppleLinuxVirtualMachineConfigurationFactory(
        networkDeviceFactory: virtualMachineNetworkDeviceFactory
      )
    let virtualMachineInstaller = MacVirtualMachineInstallationService(
      store: virtualMachineLibrary,
      engine: AppleMacVirtualMachineInstallationEngine(
        configurationFactory: virtualMachineConfigurationFactory
      )
    )
    let virtualMachineSavedStateStore = MacVirtualMachineSavedStateStore()
    let virtualMachineSavedState = MacVirtualMachineSavedStateService(
      store: virtualMachineSavedStateStore
    )
    let linuxVirtualMachineSavedStateStore =
      LinuxVirtualMachineSavedStateStore()
    let linuxVirtualMachineSavedState =
      LinuxVirtualMachineSavedStateService(
        store: linuxVirtualMachineSavedStateStore
      )
    let virtualMachineDiskImageResize =
      VirtualMachineDiskImageResizeService(
        store: virtualMachineLibrary,
        macSavedStates: virtualMachineSavedState,
        linuxSavedStates: linuxVirtualMachineSavedState
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
        savedStates: GuestAwareVirtualMachineSavedStateReclamationService(
          inventory: virtualMachineLibrary,
          macOS: MacVirtualMachineSavedStateReclamationService(
            leasingStore: virtualMachineLibrary,
            store: virtualMachineSavedStateStore
          ),
          linux: LinuxVirtualMachineSavedStateReclamationService(
            leasingStore: virtualMachineLibrary,
            store: linuxVirtualMachineSavedStateStore
          )
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
      engine: AppleMacVirtualMachineRuntimeEngine(
        configurationFactory: virtualMachineConfigurationFactory
      ),
      savedStateService: virtualMachineSavedState,
      firstBootService: MacVirtualMachineFirstBootService(
        persistence: virtualMachineLibrary
      )
    )
    let virtualMachineUSB: any MacVirtualMachineUSBManaging = {
      guard #available(macOS 27.0, *) else {
        return UnavailableMacVirtualMachineUSBService()
      }
      guard
        AppleProcessEntitlementChecker().hasBooleanEntitlement(
          "com.apple.developer.accessory-access.usb"
        )
      else {
        return UnavailableMacVirtualMachineUSBService(
          reason:
            "Physical USB is blocked in this build because its code signature does not contain com.apple.developer.accessory-access.usb. Discovery and attachment cannot run until Xcode can provision that capability."
        )
      }
      return MacVirtualMachineUSBService(
        discovery: AppleMacVirtualMachineUSBAccessoryDiscovery(),
        controllerProvider: virtualMachineRuntime
      )
    }()
    let linuxVirtualMachineRuntime = LinuxVirtualMachineRuntimeService(
      leasingStore: virtualMachineLibrary,
      installationStore: virtualMachineLibrary,
      engine: AppleLinuxVirtualMachineRuntimeEngine(
        configurationFactory: linuxVirtualMachineConfigurationFactory
      ),
      savedStateService: linuxVirtualMachineSavedState
    )
    let virtualMachineAudio = MacVirtualMachineAudioService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState
    )
    let virtualMachineNetwork = MacVirtualMachineNetworkService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState
    )
    let linuxVirtualMachineNetwork = LinuxVirtualMachineNetworkService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: linuxVirtualMachineSavedState
    )
    let virtualMachineCompute = MacVirtualMachineComputeService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState,
      platformLimits: virtualMachineComputeLimits
    )
    let linuxVirtualMachineCompute = LinuxVirtualMachineComputeService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: linuxVirtualMachineSavedState,
      platformLimits: virtualMachineComputeLimits
    )
    let virtualMachineName = MacVirtualMachineNameService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary
    )
    let linuxVirtualMachineName = LinuxVirtualMachineNameService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary
    )
    let virtualMachineDiskSnapshots = MacVirtualMachineDiskSnapshotService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState
    )
    let linuxVirtualMachineDiskSnapshots = LinuxVirtualMachineDiskSnapshotService(
      linuxLeasingStore: virtualMachineLibrary,
      linuxPersistence: virtualMachineLibrary,
      linuxSavedStateService: linuxVirtualMachineSavedState
    )
    let virtualMachineSharedDirectories = MacVirtualMachineSharedDirectoryService(
      leasingStore: virtualMachineLibrary,
      persistence: virtualMachineLibrary,
      savedStateService: virtualMachineSavedState
    )
    let linuxVirtualMachineSharedDirectories =
      LinuxVirtualMachineSharedDirectoryService(
        leasingStore: virtualMachineLibrary,
        persistence: virtualMachineLibrary,
        savedStateService: linuxVirtualMachineSavedState
      )
    let optionalIntegrations = DemandStartedOptionalIntegrationServices {
      OptionalIntegrationServiceModule.live(
        containerClient: containerClient,
        infrastructure: infrastructureClient,
        inventory: inventoryService,
        runtimeMutationCoordinator: mutationCoordinator
      )
    }
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
      appleContainerRuntimeSetup: AppleContainerRuntimeSetupService(),
      launchAtLogin: SMAppServiceLaunchAtLoginService(),
      notifications: UserNotificationService(),
      performanceBenchmarks: performanceBenchmarkService,
      fieldDiagnostics: fieldDiagnosticService,
      kubernetes: kubernetesService,
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
        machineTerminal: machineProcessService,
        podTerminal: kubernetesPodTerminal
      ),
      containerAttachments: attachmentService,
      machineCreator: machineService,
      machineLifecycle: machineService,
      machineConfiguration: machineConfigurationService,
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
      dockerCompatibility: optionalIntegrations.dockerCompatibility,
      composeBridgeConformance: SocktainerComposeConformanceService(),
      dockerComposeClient: optionalIntegrations.dockerComposeClient,
      composeProjectLifecycle: optionalIntegrations.composeProjectLifecycle,
      virtualMachineLibrary: virtualMachineLibrary,
      linuxVirtualMachineCreator: linuxVirtualMachineCreator,
      virtualMachineCloner: virtualMachineCloner,
      virtualMachineTransfer: virtualMachineTransfer,
      virtualMachineInstaller: virtualMachineInstaller,
      virtualMachineRuntime: virtualMachineRuntime,
      virtualMachineUSB: virtualMachineUSB,
      linuxVirtualMachineRuntime: linuxVirtualMachineRuntime,
      virtualMachineAudio: virtualMachineAudio,
      virtualMachineNetwork: virtualMachineNetwork,
      linuxVirtualMachineNetwork: linuxVirtualMachineNetwork,
      virtualMachineCompute: virtualMachineCompute,
      linuxVirtualMachineCompute: linuxVirtualMachineCompute,
      virtualMachineName: virtualMachineName,
      linuxVirtualMachineName: linuxVirtualMachineName,
      virtualMachineSharedDirectories: virtualMachineSharedDirectories,
      linuxVirtualMachineSharedDirectories: linuxVirtualMachineSharedDirectories,
      virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices(
        migration: virtualMachineDiskImageMigration,
        rewrite: virtualMachineDiskImageRewrite,
        recovery: virtualMachineDiskImageReplacement,
        resize: virtualMachineDiskImageResize,
        resizeRecovery: virtualMachineDiskImageResize
      ),
      virtualMachineDiskSnapshots: virtualMachineDiskSnapshots,
      linuxVirtualMachineDiskSnapshots: linuxVirtualMachineDiskSnapshots,
      virtualMachineAvailability:
        AppleMacVirtualMachineAvailabilityChecker(),
      restoreImageDiscovery: MacRestoreImageService(),
      restoreImageAcquisition: restoreImageAcquisition,
      restoreImageStoreRecovery: restoreImageStoreRecovery
    )
  }
}
