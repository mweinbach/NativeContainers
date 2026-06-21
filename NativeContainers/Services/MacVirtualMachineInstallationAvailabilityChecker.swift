import Foundation
import Security
@preconcurrency import Virtualization

enum MacVirtualMachineInstallationAvailability: Equatable, Sendable {
  case available
  case requiresAppleSilicon
  case virtualizationUnavailable
  case missingVirtualizationEntitlement

  var unavailableReason: String? {
    switch self {
    case .available:
      nil
    case .requiresAppleSilicon:
      "macOS virtual machines require a Mac with Apple silicon."
    case .virtualizationUnavailable:
      "Virtualization.framework is unavailable on this Mac."
    case .missingVirtualizationEntitlement:
      "Add the Virtualization entitlement to the NativeContainers app target before installing macOS."
    }
  }
}

protocol MacVirtualMachineInstallationAvailabilityChecking: Sendable {
  func availability() -> MacVirtualMachineInstallationAvailability
}

struct AppleMacVirtualMachineInstallationAvailabilityChecker:
  MacVirtualMachineInstallationAvailabilityChecking
{
  func availability() -> MacVirtualMachineInstallationAvailability {
    #if arch(arm64)
      guard VZVirtualMachine.isSupported else {
        return .virtualizationUnavailable
      }
      guard let task = SecTaskCreateFromSelf(nil),
        let value = SecTaskCopyValueForEntitlement(
          task,
          "com.apple.security.virtualization" as CFString,
          nil
        ) as? Bool,
        value
      else {
        return .missingVirtualizationEntitlement
      }
      return .available
    #else
      return .requiresAppleSilicon
    #endif
  }
}

struct StaticMacVirtualMachineInstallationAvailabilityChecker:
  MacVirtualMachineInstallationAvailabilityChecking
{
  let value: MacVirtualMachineInstallationAvailability

  func availability() -> MacVirtualMachineInstallationAvailability {
    value
  }
}
