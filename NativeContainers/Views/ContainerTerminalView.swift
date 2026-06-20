import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

struct ContainerTerminalView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerTerminalModel
  @State private var connectionTask: Task<Void, Never>?
  @State private var isConfirmingClose = false

  init(containerID: String, appModel: AppModel) {
    _model = State(
      initialValue: appModel.makeContainerTerminalModel(containerID: containerID)
    )
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        statusBar
        Divider()
        ZStack {
          ContainerTerminalSurface(model: model)
          if model.isConnecting {
            ProgressView("Opening terminal…")
              .padding(18)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let errorMessage = model.errorMessage {
          Divider()
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(errorMessage)
              .font(.caption)
              .textSelection(.enabled)
            Spacer()
            Button("Dismiss") {
              model.clearError()
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.bar)
        }
      }
      .navigationTitle("Terminal — \(model.containerID)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            if model.hasActiveSession {
              isConfirmingClose = true
            } else {
              dismiss()
            }
          }
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if model.isRunning {
            Button("Interrupt", systemImage: "stop.circle") {
              model.enqueueInput(Data([0x03]))
            }
            .help("Send Control-C to the foreground terminal process")

            Menu("Session", systemImage: "ellipsis.circle") {
              Button("Send End of File") {
                model.enqueueInput(Data([0x04]))
              }
              Button("Send Hangup") {
                Task { await model.sendSignal(.hangup) }
              }
              Divider()
              Button("Terminate Process", role: .destructive) {
                Task { await model.sendSignal(.terminate) }
              }
              Button("Kill Process", role: .destructive) {
                Task { await model.sendSignal(.kill) }
              }
            }
          } else if !model.isConnecting, !model.hasActiveSession {
            Button(newSessionLabel, systemImage: "arrow.clockwise") {
              connect()
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .interactiveDismissDisabled(model.hasActiveSession || model.isConnecting)
    .confirmationDialog(
      "Close active terminal?",
      isPresented: $isConfirmingClose
    ) {
      Button("Close Terminal", role: .destructive) {
        Task {
          if await model.close() {
            dismiss()
          }
        }
      }
      Button("Keep Open", role: .cancel) {}
    } message: {
      Text("The shell process will receive a hangup signal and be stopped if it does not exit.")
    }
    .task {
      await model.connect()
    }
    .onDisappear {
      connectionTask?.cancel()
      Task { await model.close() }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 9) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
      Text(model.statusLabel)
        .font(.caption.weight(.medium))

      if let terminalTitle = model.terminalTitle {
        Text(terminalTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let currentDirectory = model.currentDirectory {
        Text(currentDirectory)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if model.displayWasTruncated {
        Label("Recovery history truncated", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .help(
            "The live display is complete; the bounded recovery snapshot kept the newest output.")
      }
      Text("Control-C interrupts • Control-D exits")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var statusColor: SwiftUI.Color {
    switch model.lifecycle {
    case .running: .green
    case .starting: .yellow
    case .exited: .secondary
    case .closed: .secondary
    case .failed: .red
    }
  }

  private var newSessionLabel: String {
    if case .failed = model.lifecycle {
      "Retry"
    } else {
      "Start New Shell"
    }
  }

  private func connect() {
    guard connectionTask == nil else { return }
    connectionTask = Task {
      await model.connect()
      connectionTask = nil
    }
  }
}

private struct ContainerTerminalSurface: NSViewRepresentable {
  let model: ContainerTerminalModel

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
    terminal.setAccessibilityLabel("Interactive terminal for \(model.containerID)")
    terminal.setAccessibilityHelp(
      "Type commands in the running container. Control-C interrupts and Control-D exits."
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

#Preview("Interactive container terminal") {
  ContainerTerminalView(containerID: "api", appModel: .preview)
}
