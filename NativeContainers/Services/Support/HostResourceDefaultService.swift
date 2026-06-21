import Foundation

struct HostResourceDefaultService: WorkloadCreationDefaultsProviding {
  private let stateProvider: any HostResourceStateProviding

  init(
    stateProvider: any HostResourceStateProviding = ProcessInfoHostResourceStateProvider()
  ) {
    self.stateProvider = stateProvider
  }

  func currentDefaults() -> WorkloadCreationDefaults {
    let state = stateProvider.currentState()
    let availableProcessorCount = max(1, state.activeProcessorCount)
    let constraint = constraint(for: state)
    let defaultCPUCount = min(4, availableProcessorCount)
    let reducedCPUCount = min(2, availableProcessorCount)
    let virtualMachineCPUCount = min(
      8,
      min(availableProcessorCount, max(2, availableProcessorCount / 2))
    )
    let selectedCPUCount = constraint == nil ? defaultCPUCount : reducedCPUCount

    return WorkloadCreationDefaults(
      container: WorkloadResourceDefaults(
        cpuCount: selectedCPUCount,
        memoryMiB: 1_024
      ),
      linuxMachine: WorkloadResourceDefaults(
        cpuCount: selectedCPUCount,
        memoryMiB: 2_048
      ),
      virtualMachine: VirtualMachineResourceDefaults(
        cpuCount: constraint == nil ? virtualMachineCPUCount : reducedCPUCount,
        memoryGiB: 8,
        diskGiB: 64
      ),
      constraint: constraint
    )
  }

  private func constraint(for state: HostResourceState) -> ResourceDefaultConstraint? {
    switch (
      state.isLowPowerModeEnabled,
      state.thermalCondition.requiresReducedResourceDefaults
    ) {
    case (false, false):
      nil
    case (true, false):
      .lowPowerMode
    case (false, true):
      .elevatedThermalState
    case (true, true):
      .lowPowerModeAndElevatedThermalState
    }
  }
}
