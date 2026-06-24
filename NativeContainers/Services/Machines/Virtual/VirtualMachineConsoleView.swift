import AppKit
import SwiftUI
@preconcurrency import Virtualization

struct VirtualMachineConsoleView: NSViewRepresentable {
  let console: VirtualMachineConsole
  let capturesSystemKeys: Bool
  let automaticallyReconfiguresDisplay: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> VirtualMachineConsoleContainerView {
    let view = VirtualMachineConsoleContainerView()
    configure(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(
    _ view: VirtualMachineConsoleContainerView,
    context: Context
  ) {
    configure(view, coordinator: context.coordinator)
  }

  private func configure(
    _ container: VirtualMachineConsoleContainerView,
    coordinator: Coordinator
  ) {
    let view = container.virtualMachineView
    guard let virtualMachine = console.virtualMachine else {
      detach(container, coordinator: coordinator)
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
    container.requestsAutomaticDisplayReconfiguration =
      automaticallyReconfiguresDisplay
  }

  private func detach(
    _ container: VirtualMachineConsoleContainerView,
    coordinator: Coordinator
  ) {
    let view = container.virtualMachineView
    container.requestsAutomaticDisplayReconfiguration = false
    if #available(macOS 27.0, *) {
      view.adaptor = nil
    } else {
      view.virtualMachine = nil
    }
    coordinator.adaptorStorage = nil
    coordinator.virtualMachineIdentifier = nil
  }

  static func dismantleNSView(
    _ container: VirtualMachineConsoleContainerView,
    coordinator: Coordinator
  ) {
    let view = container.virtualMachineView
    container.requestsAutomaticDisplayReconfiguration = false
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

@MainActor
final class VirtualMachineConsoleContainerView: NSView {
  let virtualMachineView = VZVirtualMachineView()

  var requestsAutomaticDisplayReconfiguration = false {
    didSet { updateAutomaticDisplayReconfiguration() }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(virtualMachineView)
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    virtualMachineView.frame = bounds
    updateAutomaticDisplayReconfiguration()
  }

  nonisolated static func shouldAutomaticallyReconfigureDisplay(
    requested: Bool,
    size: CGSize
  ) -> Bool {
    requested && size.width > 0 && size.height > 0
  }

  private func updateAutomaticDisplayReconfiguration() {
    virtualMachineView.automaticallyReconfiguresDisplay =
      Self
      .shouldAutomaticallyReconfigureDisplay(
        requested: requestsAutomaticDisplayReconfiguration,
        size: bounds.size
      )
  }
}
