import Foundation

enum MacVirtualMachineConfigurationEditBlock: Equatable, Sendable {
  case diskMaintenance
  case installationIncomplete
  case running
  case ownedElsewhere
  case inspectingSavedState
  case transitionInProgress
  case savedStatePresent

  var message: LocalizedStringResource {
    switch self {
    case .diskMaintenance:
      "Wait for virtual disk maintenance to finish."
    case .installationIncomplete:
      "Finish preparing and installing this VM before changing its configuration."
    case .running:
      "Shut down this VM before changing its configuration."
    case .ownedElsewhere:
      "Another NativeContainers process owns this VM."
    case .inspectingSavedState:
      "Checking the VM’s saved state…"
    case .transitionInProgress:
      "Wait for this VM to finish changing state."
    case .savedStatePresent:
      "Discard the saved state before changing this VM’s configuration."
    }
  }
}

struct MacVirtualMachineConfigurationEditPolicy: Sendable {
  func block(
    installState: VirtualMachineInstallState,
    runtime: MacVirtualMachineRuntimeSnapshot,
    diskMaintenanceIsBusy: Bool
  ) -> MacVirtualMachineConfigurationEditBlock? {
    guard !diskMaintenanceIsBusy else { return .diskMaintenance }
    guard installState == .stopped else { return .installationIncomplete }
    guard runtime.target == nil else { return .running }

    switch runtime.state {
    case .stopped:
      break
    case .ownedElsewhere:
      return .ownedElsewhere
    case .inspectingSavedState:
      return .inspectingSavedState
    default:
      return .transitionInProgress
    }

    switch runtime.savedStateStatus {
    case .none:
      return nil
    case .unknown:
      return .inspectingSavedState
    case .available, .incompatible:
      return .savedStatePresent
    }
  }
}
