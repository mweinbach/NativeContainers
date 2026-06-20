import SwiftUI
@preconcurrency import Virtualization

struct VirtualMachineConsoleView: NSViewRepresentable {
  let virtualMachine: VZVirtualMachine
  let capturesSystemKeys: Bool
  let automaticallyReconfiguresDisplay: Bool

  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = VZVirtualMachineView()
    configure(view)
    return view
  }

  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    configure(view)
  }

  private func configure(_ view: VZVirtualMachineView) {
    if #available(macOS 27.0, *) {
      view.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: virtualMachine)
    } else {
      view.virtualMachine = virtualMachine
    }
    view.capturesSystemKeys = capturesSystemKeys
    view.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
  }
}
