import Testing

@testable import NativeContainers

@Suite("Workload creation defaults integration")
struct WorkloadCreationDefaultsIntegrationTests {
  @Test
  func containerDraftUsesInjectedResourceDefaults() {
    let draft = ContainerCreationDraft(
      resourceDefaults: WorkloadResourceDefaults(
        cpuCount: 2,
        memoryMiB: 512
      )
    )

    #expect(draft.cpuCount == 2)
    #expect(draft.memoryMiB == 512)
  }

  @Test
  func linuxMachineDraftUsesInjectedResourceDefaults() {
    let draft = LinuxMachineCreationDraft(
      resourceDefaults: WorkloadResourceDefaults(
        cpuCount: 2,
        memoryMiB: 1_024
      )
    )

    #expect(draft.cpuCount == 2)
    #expect(draft.memoryMiB == 1_024)
  }
}
