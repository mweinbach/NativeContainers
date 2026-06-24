import SwiftUI

struct LinuxVirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let runtime: LinuxVirtualMachineRuntimeModel
  let diskMaintenance: VirtualMachineDiskImageMaintenanceModel
  let isSelected: Bool
  let onSelect: () -> Void
  let open: () -> Void
  let confirmForceStop: () -> Void
  let clone: () -> Void
  let export: () -> Void
  let discard: () -> Void

  @State private var isConfirmingInstallationCompletion = false
  @State private var isConfirmingStartFresh = false
  @State private var isConfirmingDiscardSavedState = false

  var body: some View {
    HStack(spacing: 14) {
      Button(action: onSelect) {
        HStack(spacing: 14) {
          Image(systemName: guestIcon)
            .font(.title2)
            .foregroundStyle(guestTint)
            .frame(width: 30)

          VStack(alignment: .leading, spacing: 4) {
            Text(machine.name)
              .font(.headline)
            Text(statusLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
            VirtualMachineResourceSummary(resources: machine.resources)
            if let runtimeDiagnostic {
              Label(runtimeDiagnostic, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(runtimeDiagnostic)
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
          if machine.installState == .stopped,
            runtime.snapshot.target == nil,
            runtime.snapshot.state == .stopped
          {
            Divider()
            Button("Clone VM…", systemImage: "square.on.square", action: clone)
            Button("Export VM…", systemImage: "square.and.arrow.up", action: export)
          }
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
        .disabled(diskMaintenance.isBusy)
        .help(moreActionsLabel)
        .accessibilityLabel(moreActionsLabel)
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 8)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .task { await runtime.observe() }
    .confirmationDialog(
      "Start \(machine.name) without its saved state?",
      isPresented: $isConfirmingStartFresh
    ) {
      Button("Start Fresh", role: .destructive) {
        Task { await runtime.startFresh() }
      }
    } message: {
      Text(startFreshMessage)
    }
    .confirmationDialog(
      "Discard the saved state for \(machine.name)?",
      isPresented: $isConfirmingDiscardSavedState
    ) {
      Button("Discard Saved State", role: .destructive) {
        Task { await runtime.discardSavedState() }
      }
    } message: {
      Text("The VM remains powered off, but its suspended session cannot be resumed.")
    }
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
    if diskMaintenance.isBusy {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(diskMaintenance.operation?.progressLabel ?? "Refreshing disk")
          .font(.caption)
      }
    } else {
      switch machine.installState {
      case .draft:
        Label("Needs installer", systemImage: "opticaldisc")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .readyToInstall, .stopped:
        switch runtime.snapshot.state {
        case .stopped, .ownedElsewhere:
          if case .incompatible = runtime.snapshot.savedStateStatus {
            Button("Start Fresh…") {
              isConfirmingStartFresh = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!runtime.snapshot.canStartFresh)
          } else {
            Button(startTitle) {
              Task { await runtime.start() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!runtime.snapshot.canStart)
          }
        case .running, .paused, .stopping:
          Button("Open", action: open)
            .buttonStyle(.borderedProminent)
        case .inspectingSavedState, .starting, .pausing, .resuming, .saving,
          .restoring, .discardingSavedState, .ejectingInstallationMedia:
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
    if runtime.snapshot.canSuspend {
      Button("Suspend", systemImage: "moon.zzz.fill") {
        Task { await runtime.suspend() }
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
    if runtime.snapshot.canDiscardSavedState {
      Divider()
      Button("Start Fresh…", systemImage: "play.fill") {
        isConfirmingStartFresh = true
      }
      Button(
        "Discard Saved State…",
        systemImage: "trash",
        role: .destructive
      ) {
        isConfirmingDiscardSavedState = true
      }
    }
  }

  private var statusLabel: LocalizedStringResource {
    if let operation = diskMaintenance.operation {
      return operation.progressLabel
    }
    if diskMaintenance.isRefreshing {
      return "Refreshing virtual disk state"
    }
    return switch machine.installState {
    case .draft:
      "Needs installation media"
    case .readyToInstall:
      readyToInstallStateLabel
    case .installing:
      installingLabel
    case .stopped:
      stoppedStateLabel
    case .failed:
      "Needs attention"
    }
  }

  private var startTitle: LocalizedStringResource {
    if runtime.snapshot.state == .ownedElsewhere { return "Retry" }
    if case .available = runtime.snapshot.savedStateStatus { return "Resume" }
    return "Start"
  }

  private var stoppedStateLabel: LocalizedStringResource {
    guard runtime.snapshot.target == nil else {
      return runtime.snapshot.state.label
    }
    switch runtime.snapshot.savedStateStatus {
    case .available:
      return "Suspended"
    case .incompatible:
      return "Saved state needs attention"
    case .unknown, .none:
      return "Installed"
    }
  }

  private var readyToInstallStateLabel: LocalizedStringResource {
    guard runtime.snapshot.target == nil else {
      return runtime.snapshot.state.label
    }
    switch runtime.snapshot.savedStateStatus {
    case .available:
      return "Suspended • ISO attached"
    case .incompatible:
      return "Saved state needs attention • ISO attached"
    case .unknown, .none:
      return "Ready to install • ISO attached"
    }
  }

  private var runtimeDiagnostic: String? {
    if let errorMessage = diskMaintenance.errorMessage { return errorMessage }
    if let errorMessage = runtime.errorMessage { return errorMessage }
    if case .incompatible(let reason) = runtime.snapshot.savedStateStatus {
      return reason
    }
    return nil
  }

  private var forceStopTitle: LocalizedStringResource {
    if runtime.snapshot.isForceStopCompleteAwaitingCleanup {
      return "Force Stopped"
    }
    if runtime.snapshot.isForceStopQueued { return "Force Stop Queued" }
    return "Force Stop…"
  }

  private var guestIcon: String {
    machine.guest == .windows ? "rectangle" : "display"
  }

  private var guestTint: Color {
    machine.guest == .windows ? .blue : .mint
  }

  private var moreActionsLabel: LocalizedStringResource {
    machine.guest == .windows
      ? "More Windows virtual machine actions"
      : "More Linux virtual machine actions"
  }

  private var startFreshMessage: LocalizedStringResource {
    machine.guest == .windows
      ? "The suspended session is permanently discarded before Windows starts."
      : "The suspended session is permanently discarded before Linux starts."
  }

  private var installingLabel: LocalizedStringResource {
    machine.guest == .windows ? "Installing Windows" : "Installing Linux"
  }
}
