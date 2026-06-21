import SwiftUI

struct MenuBarQuickControlsView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      MenuBarQuickControlsHeader(
        runtimeIsAvailable: model.systemInfo != nil,
        runningContainerCount: model.runningContainerCount,
        totalContainerCount: model.containers.count,
        runningLinuxMachineCount: model.runningLinuxMachineCount,
        totalLinuxMachineCount: model.linuxMachines.count,
        virtualMachineCount: model.virtualMachines.count
      )

      if let errorMessage = model.errorMessage {
        Divider()
        MenuBarQuickControlsError(
          model: model,
          message: errorMessage
        )
      }

      Divider()

      MenuBarContainerQuickControls(model: model)

      Divider()

      MenuBarQuickControlsFooter(model: model)
    }
    .frame(width: 360)
    .task {
      await model.loadIfNeeded()
    }
  }
}

private struct MenuBarQuickControlsError: View {
  let model: AppModel
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      Text(message)
        .font(.caption)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        model.clearError()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss error")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.08))
  }
}

private struct MenuBarQuickControlsHeader: View {
  let runtimeIsAvailable: Bool
  let runningContainerCount: Int
  let totalContainerCount: Int
  let runningLinuxMachineCount: Int
  let totalLinuxMachineCount: Int
  let virtualMachineCount: Int

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "shippingbox.fill")
        .font(.title2)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("NativeContainers")
            .font(.headline)

          MenuBarRuntimeAvailabilityIndicator(
            isAvailable: runtimeIsAvailable
          )
        }

        Text(
          "Running: \(runningContainerCount)/\(totalContainerCount) containers",
          comment: "Menu bar running and total container counts."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(
          "\(runningLinuxMachineCount)/\(totalLinuxMachineCount) Linux machines, \(virtualMachineCount) virtual machines",
          comment: "Menu bar Linux machine and native virtual machine counts."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(14)
  }
}

private struct MenuBarRuntimeAvailabilityIndicator: View {
  let isAvailable: Bool

  var body: some View {
    ZStack {
      if isAvailable {
        Circle()
          .fill(.green)
          .accessibilityLabel("Apple container runtime available")
      } else {
        Circle()
          .fill(.red)
          .accessibilityLabel("Apple container runtime unavailable")
      }
    }
    .frame(width: 7, height: 7)
  }
}

private struct MenuBarContainerQuickControls: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Containers")
        .font(.caption)
        .foregroundStyle(.secondary)

      if model.containers.isEmpty {
        MenuBarEmptyContainerState(runtimeIsAvailable: model.systemInfo != nil)
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(model.containers.prefix(8)) { container in
              MenuBarContainerQuickControlRow(
                model: model,
                containerID: container.id,
                imageReference: container.imageReference,
                state: container.state,
                appIsRefreshing: model.isRefreshing
              )
            }
          }
        }
        .frame(maxHeight: 320)

        if model.containers.count > 8 {
          Text(
            "\(model.containers.count - 8) more containers in the main window",
            comment: "Menu bar overflow count for containers not shown in quick controls."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
  }
}

private struct MenuBarEmptyContainerState: View {
  let runtimeIsAvailable: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if runtimeIsAvailable {
        Label("No containers", systemImage: "shippingbox")
          .font(.subheadline)
        Text("Create a container in the main window to manage it here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label("Runtime unavailable", systemImage: "exclamationmark.triangle")
          .font(.subheadline)
        Text("Open the main window for diagnostics and recovery controls.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }
}

private struct MenuBarContainerQuickControlRow: View {
  let model: AppModel
  let containerID: String
  let imageReference: String
  let state: RuntimeState
  let appIsRefreshing: Bool

  @Environment(\.openWindow) private var openWindow
  @State private var activeActions: Set<ContainerQuickAction> = []

  var body: some View {
    HStack(spacing: 8) {
      Button {
        openContainer()
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(containerID)
            .lineLimit(1)
          Text(imageReference)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)

      if !activeActions.isEmpty || state == .stopping {
        ProgressView()
          .controlSize(.small)
          .frame(width: 24, height: 24)
      } else if state.isRunning {
        Button {
          perform(.stop)
        } label: {
          Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderless)
        .help("Stop container")
        .accessibilityLabel("Stop container")
        .disabled(appIsRefreshing)
      } else {
        Button {
          perform(.start)
        } label: {
          Image(systemName: "play.fill")
        }
        .buttonStyle(.borderless)
        .help("Start container")
        .accessibilityLabel("Start container")
        .disabled(state == .unknown || appIsRefreshing)
      }

      Menu {
        Button("Open Details", systemImage: "rectangle.and.text.magnifyingglass") {
          openContainer()
        }

        if state.isRunning {
          Button("Restart", systemImage: "arrow.clockwise") {
            perform(.restart)
          }
          .disabled(!activeActions.isEmpty || appIsRefreshing)
        }

        if canForceStop {
          Divider()

          Button("Force Stop", systemImage: "xmark.octagon", role: .destructive) {
            perform(.forceStop)
          }
          .disabled(activeActions.contains(.forceStop))
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.borderless)
      .fixedSize()
      .accessibilityLabel("More container actions")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  private var canForceStop: Bool {
    state.isRunning
      || state == .stopping
      || activeActions.contains(.stop)
      || activeActions.contains(.restart)
  }

  private func openContainer() {
    _ = model.navigate(to: .container(containerID))
    openWindow(id: "main")
  }

  private func perform(_ action: ContainerQuickAction) {
    guard !activeActions.contains(action) else { return }
    guard action == .forceStop || activeActions.isEmpty else { return }
    activeActions.insert(action)

    Task {
      switch action {
      case .start:
        await model.startContainer(id: containerID)
      case .stop:
        await model.stopContainer(id: containerID)
      case .restart:
        await model.restartContainer(id: containerID)
      case .forceStop:
        await model.forceStopContainer(id: containerID)
      }

      if action == .forceStop {
        activeActions.removeAll()
      } else {
        activeActions.remove(action)
      }
    }
  }
}

private enum ContainerQuickAction: Hashable {
  case start
  case stop
  case restart
  case forceStop
}

private struct MenuBarQuickControlsFooter: View {
  let model: AppModel

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    HStack(spacing: 8) {
      Button("Open NativeContainers", systemImage: "macwindow") {
        _ = model.navigate(to: .overview)
        openWindow(id: "main")
      }

      Spacer()

      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Refresh all resources")
      .accessibilityLabel("Refresh all resources")
      .disabled(model.isRefreshing)

      SettingsLink {
        Image(systemName: "gearshape")
      }
      .help("Open Settings")
      .accessibilityLabel("Open Settings")
    }
    .padding(12)
  }
}

#Preview("Menu Bar Quick Controls") {
  MenuBarQuickControlsView(model: .preview)
}
