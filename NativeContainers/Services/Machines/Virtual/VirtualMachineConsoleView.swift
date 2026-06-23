import SwiftUI
@preconcurrency import Virtualization

struct VirtualMachineConsoleView: NSViewRepresentable {
  let console: VirtualMachineConsole
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

  private func configure(
    _ view: VZVirtualMachineView,
    coordinator: Coordinator
  ) {
    guard let virtualMachine = console.virtualMachine else {
      detach(view, coordinator: coordinator)
      return
    }
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

  private func detach(
    _ view: VZVirtualMachineView,
    coordinator: Coordinator
  ) {
    if #available(macOS 27.0, *) {
      view.adaptor = nil
    } else {
      view.virtualMachine = nil
    }
    coordinator.adaptorStorage = nil
    coordinator.virtualMachineIdentifier = nil
  }

  static func dismantleNSView(
    _ view: VZVirtualMachineView,
    coordinator: Coordinator
  ) {
    if #available(macOS 27.0, *) {
      view.adaptor = nil
    } else {
      view.virtualMachine = nil
    }
    coordinator.adaptorStorage = nil
    coordinator.virtualMachineIdentifier = nil
  }

  @MainActor
  final class Coordinator {
    var adaptorStorage: Any?
    var virtualMachineIdentifier: ObjectIdentifier?
  }
}
