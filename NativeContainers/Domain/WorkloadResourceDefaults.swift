import Foundation

enum HostThermalCondition: Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical

  var requiresReducedResourceDefaults: Bool {
    self == .serious || self == .critical
  }
}

struct HostResourceState: Equatable, Sendable {
  let activeProcessorCount: Int
  let isLowPowerModeEnabled: Bool
  let thermalCondition: HostThermalCondition
}

enum ResourceDefaultConstraint: Equatable, Sendable {
  case lowPowerMode
  case elevatedThermalState
  case lowPowerModeAndElevatedThermalState

  var notice: LocalizedStringResource {
    switch self {
    case .lowPowerMode:
      "Low Power Mode is on, so this workload starts with fewer CPUs. Existing workloads are unchanged."
    case .elevatedThermalState:
      "Thermal pressure is high, so this workload starts with fewer CPUs. Existing workloads are unchanged."
    case .lowPowerModeAndElevatedThermalState:
      "Low Power Mode and thermal pressure are active, so this workload starts with fewer CPUs. Existing workloads are unchanged."
    }
  }
}

struct WorkloadResourceDefaults: Equatable, Sendable {
  let cpuCount: Int
  let memoryMiB: Int
}

struct VirtualMachineResourceDefaults: Equatable, Sendable {
  let cpuCount: Int
  let memoryGiB: Int
  let diskGiB: Int
}

struct WorkloadCreationDefaults: Equatable, Sendable {
  let container: WorkloadResourceDefaults
  let linuxMachine: WorkloadResourceDefaults
  let virtualMachine: VirtualMachineResourceDefaults
  let constraint: ResourceDefaultConstraint?
}
