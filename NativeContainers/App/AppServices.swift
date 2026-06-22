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
  let workloadCreationDefaults: any WorkloadCreationDefaultsProviding
  let performanceBenchmarks: any PerformanceBenchmarking
  let fieldDiagnostics: any FieldDiagnosticManaging
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
  let machineConfiguration: any MachineConfigurationManaging
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
  let linuxVirtualMachineCreator: any LinuxVirtualMachineCreating
  let virtualMachineCloner: any VirtualMachineCloning
  let virtualMachineTransfer: any VirtualMachinePackageTransferring
  let virtualMachineInstaller: any MacVirtualMachineInstalling
  let virtualMachineRuntime: any MacVirtualMachineRuntimeManaging
  let virtualMachineUSB: any MacVirtualMachineUSBManaging
  let linuxVirtualMachineRuntime: any LinuxVirtualMachineRuntimeManaging
  let virtualMachineAudio: any MacVirtualMachineAudioManaging
  let virtualMachineNetwork: any MacVirtualMachineNetworkManaging
  let virtualMachineSharedDirectories: any MacVirtualMachineSharedDirectoryManaging
  let linuxVirtualMachineSharedDirectories: any LinuxVirtualMachineSharedDirectoryManaging
  let virtualMachineDiskImages: VirtualMachineDiskImageMaintenanceServices
  let virtualMachineDiskSnapshots: any MacVirtualMachineDiskSnapshotManaging
  let virtualMachineAvailability: any MacVirtualMachineAvailabilityChecking
  let restoreImageDiscovery: any MacRestoreImageDiscovering
  let restoreImageAcquisition: any RestoreImageAcquiring
  let restoreImageStoreRecovery: any RestoreImageStoreRecovering

  init(
    inventory: any ContainerInventoryLoading,
    launchAtLogin: any LaunchAtLoginManaging = UnavailableLaunchAtLoginService(),
    notifications: any AppNotificationManaging = UnavailableAppNotificationService(),
    workloadCreationDefaults: any WorkloadCreationDefaultsProviding =
      HostResourceDefaultService(),
    performanceBenchmarks: any PerformanceBenchmarking =
      UnavailablePerformanceBenchmarkService(),
    fieldDiagnostics: any FieldDiagnosticManaging =
      UnavailableFieldDiagnosticService(),
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
    machineConfiguration: any MachineConfigurationManaging =
      UnavailableLinuxMachineConfigurationService(),
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
    linuxVirtualMachineCreator: any LinuxVirtualMachineCreating =
      UnavailableLinuxVirtualMachineCreationService(),
    virtualMachineCloner: any VirtualMachineCloning = UnavailableVirtualMachineCloneService(),
    virtualMachineTransfer: any VirtualMachinePackageTransferring =
      UnavailableVirtualMachineTransferService(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineUSB: any MacVirtualMachineUSBManaging =
      UnavailableMacVirtualMachineUSBService(),
    linuxVirtualMachineRuntime: any LinuxVirtualMachineRuntimeManaging =
      UnavailableLinuxVirtualMachineRuntimeService(),
    virtualMachineAudio: any MacVirtualMachineAudioManaging =
      UnavailableMacVirtualMachineAudioService(),
    virtualMachineNetwork: any MacVirtualMachineNetworkManaging =
      UnavailableMacVirtualMachineNetworkService(),
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
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageAcquisition: any RestoreImageAcquiring,
    restoreImageStoreRecovery: any RestoreImageStoreRecovering =
      NoopRestoreImageStoreRecoveryService()
  ) {
    self.inventory = inventory
    self.launchAtLogin = launchAtLogin
    self.notifications = notifications
    self.workloadCreationDefaults = workloadCreationDefaults
    self.performanceBenchmarks = performanceBenchmarks
    self.fieldDiagnostics = fieldDiagnostics
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
    self.machineConfiguration = machineConfiguration
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
    self.linuxVirtualMachineCreator = linuxVirtualMachineCreator
    self.virtualMachineCloner = virtualMachineCloner
    self.virtualMachineTransfer = virtualMachineTransfer
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineUSB = virtualMachineUSB
    self.linuxVirtualMachineRuntime = linuxVirtualMachineRuntime
    self.virtualMachineAudio = virtualMachineAudio
    self.virtualMachineNetwork = virtualMachineNetwork
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.linuxVirtualMachineSharedDirectories = linuxVirtualMachineSharedDirectories
    self.virtualMachineDiskImages = virtualMachineDiskImages
    self.virtualMachineDiskSnapshots = virtualMachineDiskSnapshots
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
    workloadCreationDefaults: any WorkloadCreationDefaultsProviding =
      HostResourceDefaultService(),
    performanceBenchmarks: any PerformanceBenchmarking =
      UnavailablePerformanceBenchmarkService(),
    fieldDiagnostics: any FieldDiagnosticManaging =
      UnavailableFieldDiagnosticService(),
    composeTopology: any ComposeTopologyDeriving = ComposeTopologyService(),
    storageUsage: any StorageUsageLoading = UnavailableStorageUsageService(),
    storageReclamation: any StorageReclamationManaging =
      UnavailableStorageReclamationService(),
    virtualMachineStorageReclamation:
      any VirtualMachineStorageReclamationManaging =
      UnavailableVirtualMachineStorageReclamationService(),
    machineService: any MachineManaging = AppleMachineManagementService(),
    machineConfiguration: any MachineConfigurationManaging =
      UnavailableLinuxMachineConfigurationService(),
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
    linuxVirtualMachineCreator: any LinuxVirtualMachineCreating =
      UnavailableLinuxVirtualMachineCreationService(),
    virtualMachineCloner: any VirtualMachineCloning = UnavailableVirtualMachineCloneService(),
    virtualMachineTransfer: any VirtualMachinePackageTransferring =
      UnavailableVirtualMachineTransferService(),
    virtualMachineInstaller: any MacVirtualMachineInstalling =
      UnavailableMacVirtualMachineInstaller(),
    virtualMachineRuntime: any MacVirtualMachineRuntimeManaging =
      UnavailableMacVirtualMachineRuntimeService(),
    virtualMachineUSB: any MacVirtualMachineUSBManaging =
      UnavailableMacVirtualMachineUSBService(),
    linuxVirtualMachineRuntime: any LinuxVirtualMachineRuntimeManaging =
      UnavailableLinuxVirtualMachineRuntimeService(),
    virtualMachineAudio: any MacVirtualMachineAudioManaging =
      UnavailableMacVirtualMachineAudioService(),
    virtualMachineNetwork: any MacVirtualMachineNetworkManaging =
      UnavailableMacVirtualMachineNetworkService(),
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
    restoreImageDiscovery: any MacRestoreImageDiscovering,
    restoreImageAcquisition: any RestoreImageAcquiring,
    restoreImageStoreRecovery: any RestoreImageStoreRecovering =
      NoopRestoreImageStoreRecoveryService()
  ) {
    inventory = containerService
    self.launchAtLogin = launchAtLogin
    self.notifications = notifications
    self.workloadCreationDefaults = workloadCreationDefaults
    self.performanceBenchmarks = performanceBenchmarks
    self.fieldDiagnostics = fieldDiagnostics
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
    self.machineConfiguration = machineConfiguration
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
    self.linuxVirtualMachineCreator = linuxVirtualMachineCreator
    self.virtualMachineCloner = virtualMachineCloner
    self.virtualMachineTransfer = virtualMachineTransfer
    self.virtualMachineInstaller = virtualMachineInstaller
    self.virtualMachineRuntime = virtualMachineRuntime
    self.virtualMachineUSB = virtualMachineUSB
    self.linuxVirtualMachineRuntime = linuxVirtualMachineRuntime
    self.virtualMachineAudio = virtualMachineAudio
    self.virtualMachineNetwork = virtualMachineNetwork
    self.virtualMachineSharedDirectories = virtualMachineSharedDirectories
    self.linuxVirtualMachineSharedDirectories = linuxVirtualMachineSharedDirectories
    self.virtualMachineDiskImages = virtualMachineDiskImages
    self.virtualMachineDiskSnapshots = virtualMachineDiskSnapshots
    self.virtualMachineAvailability = virtualMachineAvailability
    self.restoreImageDiscovery = restoreImageDiscovery
    self.restoreImageAcquisition = restoreImageAcquisition
    self.restoreImageStoreRecovery = restoreImageStoreRecovery
  }
}
