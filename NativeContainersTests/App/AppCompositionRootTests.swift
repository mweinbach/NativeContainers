import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("App composition root")
struct AppCompositionRootTests {
  @Test
  func liveGraphExposesFocusedRuntimeFacets() {
    let services = AppCompositionRoot.live()

    #expect(services.inventory is VerifiedRuntimeInventoryService)
    #expect(services.appleContainerRuntimeSetup is VerifiedDualRuntimeSetupService)
    #expect(
      services.runtimeDistribution
        is NativeRuntimeDistributionManagementService
    )
    let verifiedInventory = services.inventory as? VerifiedRuntimeInventoryService
    let verifiedSetup =
      services.appleContainerRuntimeSetup as? VerifiedDualRuntimeSetupService
    if let verifiedInventory, let verifiedSetup {
      #expect(verifiedInventory.usesRuntimeVerifier(verifiedSetup))
    } else {
      Issue.record("Expected the production inventory and setup verification graph.")
    }
    #expect(services.workloadCreationDefaults is HostResourceDefaultService)
    #expect(services.performanceBenchmarks is PerformanceBenchmarkService)
    #expect(services.kubernetes is AppleKubernetesClusterService)
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
    #expect(
      services.dockerCompatibility is DemandStartedDockerCompatibilityService
    )
    #expect(services.composeBridgeConformance is SocktainerComposeConformanceService)
    #expect(
      services.dockerComposeClient is DemandStartedDockerComposeClientService
    )
    #expect(
      services.composeProjectLifecycle
        is DemandStartedComposeProjectLifecycleService
    )

    let dockerCompatibility =
      services.dockerCompatibility as? DemandStartedDockerCompatibilityService
    let dockerComposeClient =
      services.dockerComposeClient as? DemandStartedDockerComposeClientService
    let composeProjectLifecycle =
      services.composeProjectLifecycle as? DemandStartedComposeProjectLifecycleService

    #expect(dockerCompatibility?.hasStarted == false)
    #expect(dockerComposeClient?.hasStarted == false)
    #expect(composeProjectLifecycle?.hasStarted == false)

    _ = dockerComposeClient?.release

    #expect(dockerCompatibility?.hasStarted == true)
    #expect(dockerComposeClient?.hasStarted == true)
    #expect(composeProjectLifecycle?.hasStarted == true)
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
      let snapshot = services.virtualMachineUSB.snapshot(for: UUID())
      guard case .unavailable(let reason) = snapshot.discoveryStatus else {
        Issue.record("Expected the USB service to publish its activation blocker.")
        return
      }
      if #available(macOS 27.0, *) {
        #expect(reason.contains("com.apple.developer.accessory-access.usb"))
        #expect(reason.contains("code signature"))
      }
    }
    #expect(services.linuxVirtualMachineRuntime is LinuxVirtualMachineRuntimeService)
    #expect(services.virtualMachineName is MacVirtualMachineNameService)
    #expect(services.linuxVirtualMachineName is LinuxVirtualMachineNameService)
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
