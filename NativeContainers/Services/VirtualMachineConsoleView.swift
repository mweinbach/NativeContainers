import SwiftUI
@preconcurrency import Virtualization

#if arch(arm64)
  struct VirtualMachineConsoleView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let capturesSystemKeys: Bool
    let automaticallyReconfiguresDisplay: Bool

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
      let view = VZVirtualMachineView()
      configure(view, coordinator: context.coordinator)
      return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
      configure(view, coordinator: context.coordinator)
    }

    private func configure(_ view: VZVirtualMachineView, coordinator: Coordinator) {
      if #available(macOS 27.0, *) {
        let adaptor: VZVirtualMachineViewAdaptor
        let identifier = ObjectIdentifier(virtualMachine)
        if let existing = coordinator.adaptorStorage as? VZVirtualMachineViewAdaptor,
          coordinator.virtualMachineIdentifier == identifier
        {
          adaptor = existing
        } else {
          adaptor = VZVirtualMachineViewAdaptor(virtualMachine: virtualMachine)
          coordinator.adaptorStorage = adaptor
          coordinator.virtualMachineIdentifier = identifier
        }
        view.adaptor = adaptor
      } else {
        view.virtualMachine = virtualMachine
      }
      view.capturesSystemKeys = capturesSystemKeys
      view.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
    }

    @MainActor
    final class Coordinator {
      var adaptorStorage: Any?
      var virtualMachineIdentifier: ObjectIdentifier?
    }
  }
#endif
