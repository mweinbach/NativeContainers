import SwiftUI

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let availability: MacVirtualMachineAvailability
  let runtime: MacVirtualMachineRuntimeModel
  let isSelected: Bool
  let onSelect: () -> Void
  let prepare: () -> Void
  let install: () -> Void
  let open: () -> Void
  let forceStop: () -> Void
  let clone: () -> Void
  let discard: () -> Void

  @State private var isConfirmingStartFresh = false
  @State private var isConfirmingDiscardSavedState = false

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: machine.guest == .macOS ? "macwindow" : "display")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 4) {
        Text(machine.name)
          .font(.headline)
        if let installationFailureMessage {
          Text(installationFailureMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(installStateLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
      HStack(spacing: 8) {
        action
        if machine.installState != .installing {
          Menu {
            if machine.installState == .stopped {
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
              if runtime.snapshot.canForceStop {
                Button(
                  forceStopTitle,
                  systemImage: "exclamationmark.octagon",
                  role: .destructive,
                  action: forceStop
                )
                .disabled(runtime.snapshot.isForceStopQueued)
              }
              if runtime.snapshot.canDiscardSavedState {
                Divider()
                Button("Start Fresh…", systemImage: "play.fill") {
                  isConfirmingStartFresh = true
                }
                .disabled(availability != .available)
                Button(
                  "Discard Saved State…",
                  systemImage: "trash",
                  role: .destructive
                ) {
                  isConfirmingDiscardSavedState = true
                }
              }
              if runtime.snapshot.target == nil, runtime.snapshot.state == .stopped {
                Divider()
                Button("Clone VM…", systemImage: "square.on.square", action: clone)
              }
            }
            if runtime.snapshot.target == nil,
              runtime.snapshot.state != .ownedElsewhere
            {
              if machine.installState == .stopped {
                Divider()
              }
              Button("Discard VM…", role: .destructive, action: discard)
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .help("More virtual machine actions")
          .accessibilityLabel("More virtual machine actions")
        }
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 8)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .task { await runtime.observe() }
    .confirmationDialog(
      "Start \(machine.name) without its saved state?",
      isPresented: $isConfirmingStartFresh
    ) {
      Button("Start Fresh", role: .destructive) {
        Task { await runtime.startFresh() }
      }
    } message: {
      Text("The suspended session is permanently discarded before macOS starts.")
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
  }

  @ViewBuilder
  private var action: some View {
    switch machine.installState {
    case .draft:
      Button("Prepare…", action: prepare)
        .buttonStyle(.borderedProminent)
        .disabled(availability != .available)
        .help(availability.unavailableReason ?? "Prepare macOS")
    case .readyToInstall:
      Button("Install…", action: install)
        .buttonStyle(.borderedProminent)
        .disabled(availability != .available)
        .help(availability.unavailableReason ?? "Install macOS")
    case .installing:
      ProgressView()
        .controlSize(.small)
        .help("macOS installation is active.")
    case .stopped:
      runtimeAction
    case .failed:
      Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .help(machine.installationFailure?.message ?? "The VM needs attention.")
    }
  }

  @ViewBuilder
  private var runtimeAction: some View {
    switch runtime.snapshot.state {
    case .stopped, .ownedElsewhere:
      if case .incompatible = runtime.snapshot.savedStateStatus {
        Button("Start Fresh…") {
          isConfirmingStartFresh = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(availability != .available || !runtime.snapshot.canStartFresh)
      } else {
        Button(runtimeActionTitle) {
          Task { await runtime.start() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(availability != .available || !runtime.snapshot.canStart)
        .help(availability.unavailableReason ?? "Start macOS")
      }
    case .running, .paused, .stopping:
      Button("Open", action: open)
        .buttonStyle(.borderedProminent)
    case .inspectingSavedState, .starting, .pausing, .resuming, .saving, .restoring,
      .discardingSavedState:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(runtime.snapshot.state.label)
          .font(.caption)
      }
    }
  }

  private var installStateLabel: LocalizedStringResource {
    switch machine.installState {
    case .draft:
      "Needs restore image"
    case .readyToInstall:
      "Ready to install"
    case .installing:
      "Installing macOS"
    case .stopped:
      stoppedStateLabel
    case .failed:
      "Needs attention"
    }
  }

  private var runtimeActionTitle: LocalizedStringResource {
    if runtime.snapshot.state == .ownedElsewhere { return "Retry" }
    if case .available = runtime.snapshot.savedStateStatus { return "Resume" }
    return "Start"
  }

  private var forceStopTitle: LocalizedStringResource {
    if runtime.snapshot.isForceStopCompleteAwaitingCleanup {
      return "Force Stopped"
    }
    if runtime.snapshot.isForceStopQueued { return "Force Stop Queued" }
    return "Force Stop…"
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
      return runtime.snapshot.state.label
    }
  }

  private var runtimeDiagnostic: String? {
    if let errorMessage = runtime.errorMessage { return errorMessage }
    if case .incompatible(let reason) = runtime.snapshot.savedStateStatus {
      return reason
    }
    return nil
  }

  private var installationFailureMessage: String? {
    guard machine.installState == .failed else { return nil }
    return machine.installationFailure?.message
  }
}

struct VirtualMachineResourceSummary: View {
  let resources: VirtualMachineResources

  var body: some View {
    HStack(spacing: 12) {
      Label("\(resources.cpuCount) CPUs", systemImage: "cpu")
      Label {
        Text(Int64(clamping: resources.memoryBytes), format: .byteCount(style: .memory))
      } icon: {
        Image(systemName: "memorychip")
      }
      Label {
        Text(Int64(clamping: resources.diskBytes), format: .byteCount(style: .file))
      } icon: {
        Image(systemName: "internaldrive")
      }
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
  }
}
