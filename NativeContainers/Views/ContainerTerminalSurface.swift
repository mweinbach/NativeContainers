import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

struct ContainerTerminalSurface: NSViewRepresentable {
  let model: ContainerTerminalModel
  let targetKind: String

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> TerminalView {
    let terminal = TerminalView(
      frame: .zero,
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    terminal.terminalDelegate = context.coordinator
    terminal.configureNativeColors()
    terminal.changeScrollback(10_000)
    terminal.optionAsMetaKey = true
    terminal.allowMouseReporting = true
    terminal.setAccessibilityRole(.group)
    terminal.setAccessibilityLabel("Interactive terminal for \(targetKind) \(model.containerID)")
    terminal.setAccessibilityHelp(
      "Type commands in the running \(targetKind). Control-C interrupts and Control-D exits."
    )
    context.coordinator.attach(to: terminal)

    DispatchQueue.main.async { [weak terminal] in
      guard let terminal else { return }
      terminal.window?.makeFirstResponder(terminal)
    }
    return terminal
  }

  func updateNSView(_ nsView: TerminalView, context: Context) {}

  static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
    nsView.terminalDelegate = nil
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
    private let model: ContainerTerminalModel
    private weak var terminal: TerminalView?
    private var outputTask: Task<Void, Never>?

    init(model: ContainerTerminalModel) {
      self.model = model
    }

    func attach(to terminal: TerminalView) {
      self.terminal = terminal
      outputTask = Task { [weak self] in
        guard let self else { return }
        for await data in model.output {
          guard !Task.isCancelled else { return }
          terminal.feed(byteArray: Array(data)[...])
        }
      }
    }

    func detach() {
      outputTask?.cancel()
      outputTask = nil
      terminal = nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
      guard newCols > 0, newRows > 0 else { return }
      model.scheduleResize(columns: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
      model.updateTerminalTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
      model.updateCurrentDirectory(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
      model.enqueueInput(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
      guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased())
      else { return }
      NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
      NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
      // Deliberately block guest-initiated OSC 52 clipboard writes.
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }
}
