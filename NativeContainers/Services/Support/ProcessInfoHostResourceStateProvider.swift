import Foundation

struct ProcessInfoHostResourceStateProvider: HostResourceStateProviding {
  func currentState() -> HostResourceState {
    let processInfo = ProcessInfo.processInfo
    return HostResourceState(
      activeProcessorCount: processInfo.activeProcessorCount,
      isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
      thermalCondition: HostThermalCondition(processInfo.thermalState)
    )
  }
}

private extension HostThermalCondition {
  init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal:
      self = .nominal
    case .fair:
      self = .fair
    case .serious:
      self = .serious
    case .critical:
      self = .critical
    @unknown default:
      self = .critical
    }
  }
}
