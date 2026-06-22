import SwiftUI

struct TerminalWorkspaceContent: View {
  let model: TerminalWorkspaceModel

  var body: some View {
    ZStack {
      ForEach(model.tabs) { tab in
        TerminalWorkspaceSessionPane(
          tab: tab,
          target: model.windowRequest.target,
          isSelected: model.selectedTabID == tab.id
        )
        .opacity(model.selectedTabID == tab.id ? 1 : 0)
        .allowsHitTesting(model.selectedTabID == tab.id)
        .accessibilityHidden(model.selectedTabID != tab.id)
      }

      if model.isLoading {
        ProgressView("Restoring terminal workspace…")
          .padding(18)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct TerminalWorkspaceSessionPane: View {
  let tab: TerminalWorkspaceTabModel
  let target: TerminalTargetIdentity
  let isSelected: Bool

  var body: some View {
    VStack(spacing: 0) {
      TerminalWorkspaceStatusBar(model: tab.terminal)
      Divider()
      ZStack {
        ContainerTerminalSurface(
          model: tab.terminal,
          targetKind: targetKind
        )
        if tab.terminal.isConnecting {
          ProgressView(openingMessage)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let errorMessage = tab.terminal.errorMessage {
        TerminalWorkspaceErrorBanner(
          message: errorMessage,
          onDismiss: tab.terminal.clearError
        )
      }
    }
  }

  private var targetKind: String {
    switch target {
    case .container:
      String(localized: "container")
    case .linuxMachine:
      String(localized: "Linux machine")
    case .kubernetesPod:
      String(localized: "Kubernetes Pod")
    }
  }

  private var openingMessage: LocalizedStringKey {
    switch target {
    case .container:
      "Opening container terminal…"
    case .linuxMachine:
      "Starting the Linux machine if needed and opening its terminal…"
    case .kubernetesPod:
      "Opening a terminal in the selected Kubernetes Pod…"
    }
  }
}

struct TerminalWorkspaceStatusBar: View {
  let model: ContainerTerminalModel

  var body: some View {
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
          .help("The live display is complete; only the newest recovery output was retained.")
      }
      Text("Control-C interrupts • Control-D exits")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var statusColor: Color {
    switch model.lifecycle {
    case .running:
      .green
    case .starting:
      .yellow
    case .exited, .closed:
      .secondary
    case .failed:
      .red
    }
  }
}

struct TerminalWorkspaceErrorBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(message)
          .font(.caption)
          .textSelection(.enabled)
        Spacer()
        Button("Dismiss", action: onDismiss)
          .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }
}
