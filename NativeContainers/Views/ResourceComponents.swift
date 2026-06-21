import SwiftUI

struct RuntimeStatusIndicator: View {
  let state: RuntimeState

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 10, height: 10)
      .shadow(color: color.opacity(0.45), radius: state.isRunning ? 3 : 0)
      .accessibilityLabel(accessibilityLabel)
  }

  private var color: Color {
    switch state {
    case .running: .green
    case .stopping: .orange
    case .stopped: .secondary
    case .unknown: .yellow
    }
  }

  private var accessibilityLabel: LocalizedStringResource {
    switch state {
    case .running: "Running"
    case .stopping: "Stopping"
    case .stopped: "Stopped"
    case .unknown: "Unknown state"
    }
  }
}

struct RuntimeStateBadge: View {
  let state: RuntimeState

  var body: some View {
    Text(title)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(.quaternary, in: Capsule())
  }

  private var title: LocalizedStringResource {
    switch state {
    case .running: "Running"
    case .stopping: "Stopping"
    case .stopped: "Stopped"
    case .unknown: "Unknown"
    }
  }
}

struct ResourceActionMenu: View {
  let isRunning: Bool
  let onStart: () -> Void
  let onStop: () -> Void
  var onRestart: (() -> Void)? = nil
  var onForceStop: (() -> Void)? = nil
  var canDelete = true
  let onDelete: () -> Void

  var body: some View {
    Menu("Actions", systemImage: "ellipsis.circle") {
      if isRunning {
        Button("Stop", systemImage: "stop.fill", action: onStop)
        if let onRestart {
          Button("Restart", systemImage: "arrow.trianglehead.2.clockwise", action: onRestart)
        }
        if let onForceStop {
          Button("Force Stop", systemImage: "bolt.fill", role: .destructive, action: onForceStop)
        }
      } else {
        Button("Start", systemImage: "play.fill", action: onStart)
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        .disabled(!canDelete)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}
