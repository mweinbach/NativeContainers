import Foundation

struct VirtualMachineRuntimeTarget: Equatable, Hashable, Sendable {
  let machineID: UUID
  let generation: UUID
}

typealias MacVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
typealias LinuxVirtualMachineRuntimeTarget = VirtualMachineRuntimeTarget
