import Testing

@testable import NativeContainers

@Suite("App composition root")
struct AppCompositionRootTests {
  @Test
  func liveGraphExposesFocusedRuntimeFacets() {
    let services = AppCompositionRoot.live()

    #expect(services.inventory is AppleRuntimeInventoryService)
    #expect(services.containerLifecycle is AppleContainerLifecycleService)
    #expect(services.containerCreator is AppleContainerCreationService)
    #expect(services.containerInspector is AppleContainerInspectionService)
    #expect(services.containerTools is AppleContainerToolService)
    #expect(services.containerTerminal is AppleContainerTerminalService)
    #expect(services.machineLifecycle is AppleMachineLifecycleService)
    #expect(services.images is AppleImageService)
    #expect(services.volumes is AppleInfrastructureService)
    #expect(services.networks is AppleInfrastructureService)
    #expect(services.browser is AppleInfrastructureService)
  }
}
