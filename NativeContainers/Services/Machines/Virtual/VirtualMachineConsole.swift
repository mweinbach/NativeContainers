@preconcurrency import Virtualization

@MainActor
final class VirtualMachineConsole {
  let target: VirtualMachineRuntimeTarget
  private(set) var virtualMachine: VZVirtualMachine?

  init(
    target: VirtualMachineRuntimeTarget,
    virtualMachine: VZVirtualMachine
  ) {
    self.target = target
    self.virtualMachine = virtualMachine
  }

  func invalidate() {
    virtualMachine = nil
  }
}

typealias MacVirtualMachineConsole = VirtualMachineConsole
typealias LinuxVirtualMachineConsole = VirtualMachineConsole
