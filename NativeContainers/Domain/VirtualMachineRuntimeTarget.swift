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

typealias MacVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
typealias LinuxVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
typealias MacVirtualMachineRuntimeEvent = VirtualMachineRuntimeEvent
typealias LinuxVirtualMachineRuntimeEvent = VirtualMachineRuntimeEvent
