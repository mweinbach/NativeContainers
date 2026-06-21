import Testing

@testable import NativeContainers

@MainActor
@Suite("App composition root")
struct AppCompositionRootTests {
  @Test
  func liveGraphExposesFocusedRuntimeFacets() {
    let services = AppCompositionRoot.live()

    #expect(services.inventory is AppleRuntimeInventoryService)
    #expect(services.composeTopology is ComposeTopologyService)
    #expect(services.storageUsage is StorageUsageService)
    #expect(services.storageReclamation is StorageReclamationService)
    #expect(
      services.virtualMachineStorageReclamation
        is VirtualMachineStorageReclamationService
    )
    #expect(services.containerLifecycle is AppleContainerLifecycleService)
    #expect(services.containerCreator is AppleContainerCreationService)
    #expect(services.containerInspector is AppleContainerInspectionService)
    #expect(services.containerTools is AppleContainerToolService)
    #expect(services.containerShell is AppleContainerShellService)
    #expect(services.containerTerminal is AppleContainerTerminalService)
    #expect(services.terminalPresets is TerminalPresetStore)
    #expect(services.terminalTargets is IdentityPinnedTerminalTargetService)
    #expect(services.containerAttachments is AppleContainerAttachmentService)
    #expect(services.machineCreator is AppleMachineManagementService)
    #expect(services.machineLifecycle is AppleMachineManagementService)
    #expect(services.machineConfiguration is AppleLinuxMachineConfigurationService)
    #expect(services.machineCommands is AppleLinuxMachineProcessService)
    #expect(services.machineTerminal is AppleLinuxMachineProcessService)
    #expect(services.images is AppleImageService)
    #expect(services.volumes is AppleInfrastructureService)
    #expect(services.networks is AppleInfrastructureService)
    #expect(services.browser is AppleInfrastructureService)
    #expect(services.imageBuild is RecordingImageBuildService)
    #expect(services.imageBuildHistory is ImageBuildHistoryStore)
    #expect(services.builder is AppleContainerBuilderManagementService)
    #expect(services.appOwnedBuildCache is AppleAppOwnedBuildCacheService)
    #expect(services.dockerCompatibility is DockerCompatibilityService)
    #expect(services.composeBridgeConformance is SocktainerComposeConformanceService)
    #expect(services.dockerComposeClient is DockerComposeClientInstallService)
    #expect(services.virtualMachineLibrary is VirtualMachineLibrary)
    #expect(services.virtualMachineTransfer is VirtualMachineTransferService)
    #expect(services.virtualMachineInstaller is MacVirtualMachineInstallationService)
    #expect(services.virtualMachineRuntime is MacVirtualMachineRuntimeService)
    if #available(macOS 27.0, *),
      AppleProcessEntitlementChecker().hasBooleanEntitlement(
        "com.apple.developer.accessory-access.usb"
      )
    {
      #expect(services.virtualMachineUSB is MacVirtualMachineUSBService)
    } else {
      #expect(
        services.virtualMachineUSB is UnavailableMacVirtualMachineUSBService
      )
    }
    #expect(services.linuxVirtualMachineRuntime is LinuxVirtualMachineRuntimeService)
    #expect(
      services.linuxVirtualMachineSharedDirectories
        is LinuxVirtualMachineSharedDirectoryService
    )
    #expect(
      services.virtualMachineDiskImages.migration
        is VirtualMachineDiskImageMigrationService
    )
    #expect(
      services.virtualMachineDiskImages.rewrite
        is VirtualMachineDiskImageRewriteService
    )
    #expect(
      services.virtualMachineDiskImages.recovery
        is VirtualMachineDiskImageReplacementCoordinator
    )
    #expect(
      services.virtualMachineDiskSnapshots
        is MacVirtualMachineDiskSnapshotService
    )
    #expect(
      services.virtualMachineAvailability
        is AppleMacVirtualMachineAvailabilityChecker
    )
    #expect(services.restoreImageAcquisition is RestoreImageAcquisitionService)
    #expect(services.restoreImageStoreRecovery is RestoreImageStoreRecoveryService)
  }
}
