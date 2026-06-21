@preconcurrency import Virtualization

@MainActor
final class VirtualMachineConsole {
  let target: VirtualMachineRuntimeTarget
  let virtualMachine: VZVirtualMachine

  init(
    target: VirtualMachineRuntimeTarget,
    virtualMachine: VZVirtualMachine
  ) {
    self.target = target
    self.virtualMachine = virtualMachine
  }
}

typealias MacVirtualMachineConsole = VirtualMachineConsole
typealias LinuxVirtualMachineConsole = VirtualMachineConsole
