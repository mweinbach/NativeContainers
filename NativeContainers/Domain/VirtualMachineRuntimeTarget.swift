import Foundation

struct VirtualMachineRuntimeTarget: Equatable, Hashable, Sendable {
  let machineID: UUID
  let generation: UUID
}

enum VirtualMachineRuntimeEvent: Equatable, Sendable {
  case guestStopped
  case stoppedWithError(String)

  var errorMessage: String? {
    switch self {
    case .guestStopped:
      nil
    case .stoppedWithError(let message):
      message
    }
  }
}

enum VirtualMachineSaveRestoreSupport: Equatable, Sendable {
  case unknown
  case supported
  case unsupported(String)

  var isSupported: Bool {
    self == .supported
  }
}

typealias MacVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
typealias LinuxVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
typealias MacVirtualMachineRuntimeEvent = VirtualMachineRuntimeEvent
typealias LinuxVirtualMachineRuntimeEvent = VirtualMachineRuntimeEvent
typealias MacVirtualMachineSaveRestoreSupport = VirtualMachineSaveRestoreSupport
typealias LinuxVirtualMachineSaveRestoreSupport = VirtualMachineSaveRestoreSupport
