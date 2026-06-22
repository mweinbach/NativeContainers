import SwiftUI

struct LinuxVirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let runtime: LinuxVirtualMachineRuntimeModel
  let isSelected: Bool
  let onSelect: () -> Void
  let open: () -> Void
  let confirmForceStop: () -> Void
  let discard: () -> Void

  @State private var isConfirmingInstallationCompletion = false

  var body: some View {
    HStack(spacing: 14) {
      Button(action: onSelect) {
        HStack(spacing: 14) {
          Image(systemName: "display")
            .font(.title2)
            .foregroundStyle(.mint)
            .frame(width: 30)

          VStack(alignment: .leading, spacing: 4) {
            Text(machine.name)
              .font(.headline)
            Text(statusLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
            VirtualMachineResourceSummary(resources: machine.resources)
            if let errorMessage = runtime.errorMessage {
              Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(errorMessage)
            }
          }

          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityInputLabels([Text(machine.name)])
      .accessibilityHint("Selects this virtual machine")
      .accessibilityValue(isSelected ? "Selected" : "Not selected")

      HStack(spacing: 8) {
        primaryAction
        Menu {
          runtimeActions
          if runtime.snapshot.target == nil,
            runtime.snapshot.state != .ownedElsewhere
          {
            Divider()
            Button("Discard VM…", role: .destructive, action: discard)
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("More Linux virtual machine actions")
        .accessibilityLabel("More Linux virtual machine actions")
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 8)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .task { runtime.observe() }
    .confirmationDialog(
      "Finish installing \(machine.name)?",
      isPresented: $isConfirmingInstallationCompletion
    ) {
      Button("Eject Installer and Finish") {
        Task { await runtime.ejectInstallationMedia() }
      }
    } message: {
      Text(
        "This safely ejects the installer from the running guest and prevents the ISO from attaching on future boots."
      )
    }
  }

  @ViewBuilder
  private var primaryAction: some View {
    switch machine.installState {
    case .draft:
      Label("Needs installer", systemImage: "opticaldisc")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .readyToInstall, .stopped:
      switch runtime.snapshot.state {
      case .stopped, .ownedElsewhere:
        Button(startTitle) {
          Task { await runtime.start() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!runtime.snapshot.canStart)
      case .running, .paused, .stopping:
        Button("Open", action: open)
          .buttonStyle(.borderedProminent)
      case .starting, .pausing, .resuming, .ejectingInstallationMedia:
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(runtime.snapshot.state.label)
            .font(.caption)
        }
      }
    case .installing:
      ProgressView()
        .controlSize(.small)
    case .failed:
      Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var runtimeActions: some View {
    if runtime.snapshot.canPause {
      Button("Pause", systemImage: "pause.fill") {
        Task { await runtime.pause() }
      }
    }
    if runtime.snapshot.canResume {
      Button("Resume", systemImage: "play.fill") {
        Task { await runtime.resume() }
      }
    }
    if runtime.snapshot.canRequestStop {
      Button("Shut Down", systemImage: "power") {
        Task { await runtime.requestStop() }
      }
    }
    if runtime.snapshot.canEjectInstallationMedia {
      Button("Finish Installation & Eject ISO…", systemImage: "eject.fill") {
        isConfirmingInstallationCompletion = true
      }
    }
    if runtime.snapshot.canForceStop {
      Button(
        forceStopTitle,
        systemImage: "exclamationmark.octagon",
        role: .destructive,
        action: confirmForceStop
      )
      .disabled(runtime.snapshot.isForceStopQueued)
    }
  }

  private var statusLabel: LocalizedStringResource {
    switch machine.installState {
    case .draft:
      "Needs installation media"
    case .readyToInstall:
      runtime.snapshot.target == nil
        ? "Ready to install • ISO attached"
        : runtime.snapshot.state.label
    case .installing:
      "Installing Linux"
    case .stopped:
      runtime.snapshot.target == nil ? "Installed" : runtime.snapshot.state.label
    case .failed:
      "Needs attention"
    }
  }

  private var startTitle: LocalizedStringResource {
    runtime.snapshot.state == .ownedElsewhere ? "Retry" : "Start"
  }

  private var forceStopTitle: LocalizedStringResource {
    if runtime.snapshot.isForceStopCompleteAwaitingCleanup {
      return "Force Stopped"
    }
    if runtime.snapshot.isForceStopQueued { return "Force Stop Queued" }
    return "Force Stop…"
  }
}
