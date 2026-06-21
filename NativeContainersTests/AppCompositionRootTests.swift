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
    #expect(services.containerLifecycle is AppleContainerLifecycleService)
    #expect(services.containerCreator is AppleContainerCreationService)
    #expect(services.containerInspector is AppleContainerInspectionService)
    #expect(services.containerTools is AppleContainerToolService)
    #expect(services.containerTerminal is AppleContainerTerminalService)
    #expect(services.containerAttachments is AppleContainerAttachmentService)
    #expect(services.machineCreator is AppleMachineManagementService)
    #expect(services.machineLifecycle is AppleMachineManagementService)
    #expect(services.machineCommands is AppleLinuxMachineProcessService)
    #expect(services.machineTerminal is AppleLinuxMachineProcessService)
    #expect(services.images is AppleImageService)
    #expect(services.volumes is AppleInfrastructureService)
    #expect(services.networks is AppleInfrastructureService)
    #expect(services.browser is AppleInfrastructureService)
    #expect(services.imageBuild is RecordingImageBuildService)
    #expect(services.imageBuildHistory is ImageBuildHistoryStore)
    #expect(services.builder is AppleContainerBuilderManagementService)
    #expect(services.dockerCompatibility is DockerCompatibilityService)
    #expect(services.virtualMachineLibrary is VirtualMachineLibrary)
    #expect(services.virtualMachineInstaller is MacVirtualMachineInstallationService)
    #expect(services.virtualMachineRuntime is MacVirtualMachineRuntimeService)
    #expect(
      services.virtualMachineAvailability
        is AppleMacVirtualMachineAvailabilityChecker
    )
    #expect(services.restoreImageImporter is RestoreImageImportService)
  }
}
