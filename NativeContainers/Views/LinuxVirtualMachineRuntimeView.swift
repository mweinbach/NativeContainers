import SwiftUI

struct LinuxVirtualMachineRuntimeView: View {
  let machine: VirtualMachineManifest
  let model: LinuxVirtualMachineRuntimeModel

  @State private var capturesSystemKeys = false
  @State private var isConfirmingForceStop = false
  @State private var isConfirmingStartFresh = false
  @State private var isConfirmingDiscardSavedState = false
  @State private var isConfirmingInstallationCompletion = false

  var body: some View {
    VStack(spacing: 0) {
      LinuxVirtualMachineRuntimeHeader(
        machineName: machine.name,
        snapshot: model.snapshot,
        capturesSystemKeys: $capturesSystemKeys,
        start: { Task { await model.start() } },
        pause: { Task { await model.pause() } },
        resume: { Task { await model.resume() } },
        suspend: { Task { await model.suspend() } },
        requestStop: { Task { await model.requestStop() } },
        confirmInstallationCompletion: {
          isConfirmingInstallationCompletion = true
        },
        confirmForceStop: { isConfirmingForceStop = true },
        confirmStartFresh: { isConfirmingStartFresh = true },
        confirmDiscardSavedState: {
          isConfirmingDiscardSavedState = true
        }
      )
      LinuxVirtualMachineSavedStateBanner(snapshot: model.snapshot)
      Divider()
      LinuxVirtualMachineConsoleContent(
        model: model,
        capturesSystemKeys: capturesSystemKeys
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))

      if let errorMessage = model.errorMessage {
        LinuxVirtualMachineRuntimeErrorBanner(
          message: errorMessage,
          dismiss: model.clearActionError
        )
      }
    }
    .frame(
      minWidth: 900,
      maxWidth: .infinity,
      minHeight: 620,
      maxHeight: .infinity,
      alignment: .top
    )
    .task { await model.observe() }
    .confirmationDialog(
      "Force stop \(machine.name)?",
      isPresented: $isConfirmingForceStop
    ) {
      Button("Force Stop", role: .destructive) {
        Task { await model.forceStop() }
      }
    } message: {
      Text("This immediately powers off the VM and may lose unsaved guest data.")
    }
    .confirmationDialog(
      "Start \(machine.name) without its saved state?",
      isPresented: $isConfirmingStartFresh
    ) {
      Button("Start Fresh", role: .destructive) {
        Task { await model.startFresh() }
      }
    } message: {
      Text("The suspended session is permanently discarded before Linux starts.")
    }
    .confirmationDialog(
      "Discard the saved state for \(machine.name)?",
      isPresented: $isConfirmingDiscardSavedState
    ) {
      Button("Discard Saved State", role: .destructive) {
        Task { await model.discardSavedState() }
      }
    } message: {
      Text("The VM remains powered off, but its suspended session cannot be resumed.")
    }
    .confirmationDialog(
      "Finish installing \(machine.name)?",
      isPresented: $isConfirmingInstallationCompletion
    ) {
      Button("Eject Installer and Finish") {
        Task { await model.ejectInstallationMedia() }
      }
    } message: {
      Text(
        "This safely ejects the installer from the running guest and prevents the ISO from attaching on future boots."
      )
    }
  }
}

private struct LinuxVirtualMachineRuntimeHeader: View {
  let machineName: String
  let snapshot: LinuxVirtualMachineRuntimeSnapshot
  @Binding var capturesSystemKeys: Bool
  let start: () -> Void
  let pause: () -> Void
  let resume: () -> Void
  let suspend: () -> Void
  let requestStop: () -> Void
  let confirmInstallationCompletion: () -> Void
  let confirmForceStop: () -> Void
  let confirmStartFresh: () -> Void
  let confirmDiscardSavedState: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(machineName)
          .font(.headline)
        HStack(spacing: 6) {
          LinuxVirtualMachineRuntimeStatusIndicator(state: snapshot.state)
          Text(snapshot.state.label)
            .foregroundStyle(.secondary)
          if snapshot.isForceStopCompleteAwaitingCleanup {
            Text("Force Stopped — Finishing Cleanup")
              .foregroundStyle(.orange)
          } else if snapshot.isForceStopQueued {
            Text("Force Stop Queued")
              .foregroundStyle(.orange)
          } else if snapshot.state == .stopping {
            Text("Automatic Force Stop Armed")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption)
      }

      Spacer()
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          LinuxVirtualMachineRuntimeControls(
            snapshot: snapshot,
            start: start,
            pause: pause,
            resume: resume,
            suspend: suspend,
            requestStop: requestStop,
            confirmInstallationCompletion: confirmInstallationCompletion,
            confirmForceStop: confirmForceStop,
            confirmStartFresh: confirmStartFresh,
            confirmDiscardSavedState: confirmDiscardSavedState
          )
          LinuxVirtualMachineShortcutCaptureToggle(
            isEnabled: $capturesSystemKeys
          )
        }
        VStack(alignment: .trailing, spacing: 8) {
          LinuxVirtualMachineRuntimeControls(
            snapshot: snapshot,
            start: start,
            pause: pause,
            resume: resume,
            suspend: suspend,
            requestStop: requestStop,
            confirmInstallationCompletion: confirmInstallationCompletion,
            confirmForceStop: confirmForceStop,
            confirmStartFresh: confirmStartFresh,
            confirmDiscardSavedState: confirmDiscardSavedState
          )
          LinuxVirtualMachineShortcutCaptureToggle(
            isEnabled: $capturesSystemKeys
          )
        }
      }
    }
    .padding(14)
  }
}

private struct LinuxVirtualMachineRuntimeControls: View {
  let snapshot: LinuxVirtualMachineRuntimeSnapshot
  let start: () -> Void
  let pause: () -> Void
  let resume: () -> Void
  let suspend: () -> Void
  let requestStop: () -> Void
  let confirmInstallationCompletion: () -> Void
  let confirmForceStop: () -> Void
  let confirmStartFresh: () -> Void
  let confirmDiscardSavedState: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if snapshot.canStart {
        Button(startTitle, systemImage: "play.fill", action: start)
          .buttonStyle(.borderedProminent)
      } else if snapshot.canStartFresh,
        case .incompatible = snapshot.savedStateStatus
      {
        Button("Start Fresh…", systemImage: "play.fill", action: confirmStartFresh)
          .buttonStyle(.borderedProminent)
      }
      if snapshot.canPause {
        Button("Pause", systemImage: "pause.fill", action: pause)
      }
      if snapshot.canResume {
        Button("Resume", systemImage: "play.fill", action: resume)
      }
      if snapshot.canSuspend {
        Button("Suspend", systemImage: "moon.zzz.fill", action: suspend)
      }
      if snapshot.canRequestStop {
        Button("Shut Down", systemImage: "power", action: requestStop)
      }
      if snapshot.canEjectInstallationMedia {
        Button(
          "Finish Installation",
          systemImage: "eject.fill",
          action: confirmInstallationCompletion
        )
      }
      if snapshot.canForceStop {
        Button(
          forceStopTitle,
          systemImage: "exclamationmark.octagon",
          role: .destructive,
          action: confirmForceStop
        )
        .disabled(snapshot.isForceStopQueued)
      }
      if snapshot.canDiscardSavedState {
        Menu {
          Button("Start Fresh…", systemImage: "play.fill", action: confirmStartFresh)
          Button(
            "Discard Saved State…",
            systemImage: "trash",
            role: .destructive,
            action: confirmDiscardSavedState
          )
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("More saved-state actions")
        .accessibilityLabel("More saved-state actions")
      }
    }
  }

  private var startTitle: LocalizedStringResource {
    if case .available = snapshot.savedStateStatus { return "Resume" }
    return "Start"
  }

  private var forceStopTitle: LocalizedStringResource {
    if snapshot.isForceStopCompleteAwaitingCleanup {
      return "Force Stopped"
    }
    if snapshot.isForceStopQueued { return "Force Stop Queued" }
    return "Force Stop…"
  }
}

private struct LinuxVirtualMachineSavedStateBanner: View {
  let snapshot: LinuxVirtualMachineRuntimeSnapshot

  var body: some View {
    switch snapshot.savedStateStatus {
    case .available(let summary):
      HStack(spacing: 8) {
        Image(systemName: "moon.zzz.fill")
        Text(savedStateTitle)
          .fontWeight(.medium)
        Text(
          Int64(clamping: summary.stateSizeBytes),
          format: .byteCount(style: .file)
        )
        if snapshot.target != nil {
          Text("Resuming this live session discards the checkpoint.")
        }
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(
        snapshot.target == nil
          ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)
      )
      .padding(.horizontal, 14)
      .padding(.bottom, 10)
    case .incompatible(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    case .unknown, .none:
      if case .unsupported(let reason) = snapshot.saveRestoreSupport,
        snapshot.target != nil
      {
        Label("Suspend is unavailable: \(reason)", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.bottom, 10)
      }
    }
  }

  private var savedStateTitle: LocalizedStringResource {
    snapshot.target == nil ? "Suspended" : "Saved checkpoint"
  }
}

private struct LinuxVirtualMachineShortcutCaptureToggle: View {
  @Binding var isEnabled: Bool

  var body: some View {
    Toggle("Capture Mac Shortcuts", isOn: $isEnabled)
      .toggleStyle(.switch)
      .help("Send system keyboard shortcuts to the guest instead of the host Mac.")
  }
}

private struct LinuxVirtualMachineConsoleContent: View {
  let model: LinuxVirtualMachineRuntimeModel
  let capturesSystemKeys: Bool

  var body: some View {
    if let console = model.console {
      VirtualMachineConsoleView(
        console: console,
        capturesSystemKeys: capturesSystemKeys,
        automaticallyReconfiguresDisplay: true
      )
      .id(console.target.generation)
      .background(.black)
    } else {
      ContentUnavailableView {
        Label(model.snapshot.state.label, systemImage: "display")
      } description: {
        Text(placeholder)
      }
    }
  }

  private var placeholder: LocalizedStringResource {
    switch model.snapshot.state {
    case .stopped:
      if case .available = model.snapshot.savedStateStatus {
        "Resume the suspended VM to attach its native display and keyboard."
      } else {
        "Start the VM to attach its native display and keyboard."
      }
    case .ownedElsewhere:
      "This VM is active in another NativeContainers process."
    case .inspectingSavedState, .starting, .pausing, .paused, .resuming,
      .saving, .restoring, .discardingSavedState, .running,
      .ejectingInstallationMedia, .stopping:
      "The native display is becoming available."
    }
  }
}

private struct LinuxVirtualMachineRuntimeErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    Divider()
    HStack(spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
      Spacer()
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.caption)
    .foregroundStyle(.orange)
    .padding(12)
  }
}
