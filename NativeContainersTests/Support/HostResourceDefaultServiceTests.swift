import Testing

@testable import NativeContainers

@Suite("Host resource defaults")
struct HostResourceDefaultServiceTests {
  @Test
  func usesBalancedDefaultsUnderNominalConditions() {
    let defaults = makeDefaults(
      processorCount: 12,
      thermalCondition: .nominal
    )

    #expect(defaults.container == WorkloadResourceDefaults(cpuCount: 4, memoryMiB: 1_024))
    #expect(defaults.linuxMachine == WorkloadResourceDefaults(cpuCount: 4, memoryMiB: 2_048))
    #expect(
      defaults.virtualMachine
        == VirtualMachineResourceDefaults(cpuCount: 6, memoryGiB: 8, diskGiB: 64)
    )
    #expect(defaults.constraint == nil)
  }

  @Test
  func lowPowerModeReducesOnlyNewCPUDefaults() {
    let defaults = makeDefaults(
      processorCount: 12,
      isLowPowerModeEnabled: true,
      thermalCondition: .nominal
    )

    #expect(defaults.container == WorkloadResourceDefaults(cpuCount: 2, memoryMiB: 1_024))
    #expect(defaults.linuxMachine == WorkloadResourceDefaults(cpuCount: 2, memoryMiB: 2_048))
    #expect(
      defaults.virtualMachine
        == VirtualMachineResourceDefaults(cpuCount: 2, memoryGiB: 8, diskGiB: 64)
    )
    #expect(defaults.constraint == .lowPowerMode)
  }

  @Test(arguments: [HostThermalCondition.serious, .critical])
  func elevatedThermalStatesReduceNewCPUDefaults(
    thermalCondition: HostThermalCondition
  ) {
    let defaults = makeDefaults(
      processorCount: 8,
      thermalCondition: thermalCondition
    )

    #expect(defaults.container.cpuCount == 2)
    #expect(defaults.linuxMachine.cpuCount == 2)
    #expect(defaults.virtualMachine.cpuCount == 2)
    #expect(defaults.constraint == .elevatedThermalState)
  }

  @Test
  func fairThermalStatePreservesUserInitiatedDefaults() {
    let defaults = makeDefaults(
      processorCount: 8,
      thermalCondition: .fair
    )

    #expect(defaults.container.cpuCount == 4)
    #expect(defaults.linuxMachine.cpuCount == 4)
    #expect(defaults.virtualMachine.cpuCount == 4)
    #expect(defaults.constraint == nil)
  }

  @Test
  func combinedConstraintRetainsItsSpecificExplanation() {
    let defaults = makeDefaults(
      processorCount: 8,
      isLowPowerModeEnabled: true,
      thermalCondition: .serious
    )

    #expect(defaults.constraint == .lowPowerModeAndElevatedThermalState)
  }

  @Test
  func defaultsNeverExceedTheActiveProcessorCount() {
    let defaults = makeDefaults(
      processorCount: 1,
      isLowPowerModeEnabled: true,
      thermalCondition: .critical
    )

    #expect(defaults.container.cpuCount == 1)
    #expect(defaults.linuxMachine.cpuCount == 1)
    #expect(defaults.virtualMachine.cpuCount == 1)
  }

  @Test
  func foundationProviderReturnsAUsableSnapshot() {
    let state = ProcessInfoHostResourceStateProvider().currentState()

    #expect(state.activeProcessorCount >= 1)
  }

  private func makeDefaults(
    processorCount: Int,
    isLowPowerModeEnabled: Bool = false,
    thermalCondition: HostThermalCondition
  ) -> WorkloadCreationDefaults {
    HostResourceDefaultService(
      stateProvider: HostResourceStateProviderStub(
        state: HostResourceState(
          activeProcessorCount: processorCount,
          isLowPowerModeEnabled: isLowPowerModeEnabled,
          thermalCondition: thermalCondition
        )
      )
    ).currentDefaults()
  }
}

private struct HostResourceStateProviderStub: HostResourceStateProviding {
  let state: HostResourceState

  func currentState() -> HostResourceState {
    state
  }
}
