import SwiftUI

struct LinuxVirtualMachineRuntimeView: View {
  let machine: VirtualMachineManifest
  let model: LinuxVirtualMachineRuntimeModel

  @State private var capturesSystemKeys = false
  @State private var isConfirmingForceStop = false
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
        requestStop: { Task { await model.requestStop() } },
        confirmInstallationCompletion: {
          isConfirmingInstallationCompletion = true
        },
        confirmForceStop: { isConfirmingForceStop = true }
      )
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
    .task { model.observe() }
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
  let requestStop: () -> Void
  let confirmInstallationCompletion: () -> Void
  let confirmForceStop: () -> Void

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
            requestStop: requestStop,
            confirmInstallationCompletion: confirmInstallationCompletion,
            confirmForceStop: confirmForceStop
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
            requestStop: requestStop,
            confirmInstallationCompletion: confirmInstallationCompletion,
            confirmForceStop: confirmForceStop
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
  let requestStop: () -> Void
  let confirmInstallationCompletion: () -> Void
  let confirmForceStop: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if snapshot.canStart {
        Button("Start", systemImage: "play.fill", action: start)
          .buttonStyle(.borderedProminent)
      }
      if snapshot.canPause {
        Button("Pause", systemImage: "pause.fill", action: pause)
      }
      if snapshot.canResume {
        Button("Resume", systemImage: "play.fill", action: resume)
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
    }
  }

  private var forceStopTitle: LocalizedStringResource {
    if snapshot.isForceStopCompleteAwaitingCleanup {
      return "Force Stopped"
    }
    if snapshot.isForceStopQueued { return "Force Stop Queued" }
    return "Force Stop…"
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
      "Start the VM to attach its native display and keyboard."
    case .ownedElsewhere:
      "This VM is active in another NativeContainers process."
    case .starting, .pausing, .paused, .resuming, .running,
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
