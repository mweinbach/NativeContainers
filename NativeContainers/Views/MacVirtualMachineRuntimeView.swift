import SwiftUI

struct MacVirtualMachineRuntimeView: View {
  let machine: VirtualMachineManifest
  let model: MacVirtualMachineRuntimeModel
  let usb: MacVirtualMachineUSBModel

  @State private var capturesSystemKeys = false
  @State private var isConfirmingForceStop = false
  @State private var isConfirmingStartFresh = false
  @State private var isConfirmingDiscardSavedState = false
  @State private var isPresentingGuestProvisioning = false
  @State private var guestProvisioningModel = MacGuestProvisioningFormModel()

  var body: some View {
    VStack(spacing: 0) {
      MacVirtualMachineRuntimeHeader(
        machineName: machine.name,
        snapshot: model.snapshot,
        usb: usb,
        capturesSystemKeys: $capturesSystemKeys,
        start: { Task { await model.start() } },
        pause: { Task { await model.pause() } },
        resume: { Task { await model.resume() } },
        suspend: { Task { await model.suspend() } },
        requestStop: { Task { await model.requestStop() } },
        confirmForceStop: { isConfirmingForceStop = true },
        confirmStartFresh: { isConfirmingStartFresh = true },
        confirmDiscardSavedState: { isConfirmingDiscardSavedState = true }
      )

      if canOfferGuestProvisioning,
        let operatingSystem = machine.macOSGuestOperatingSystem
      {
        MacGuestProvisioningCallout(
          operatingSystem: operatingSystem
        ) {
          guestProvisioningModel.clearError()
          isPresentingGuestProvisioning = true
        }
      }

      MacVirtualMachineSavedStateBanner(snapshot: model.snapshot)

      Divider()
      MacVirtualMachineConsoleContent(
        model: model,
        capturesSystemKeys: capturesSystemKeys
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))

      if let errorMessage = model.errorMessage {
        MacVirtualMachineRuntimeErrorBanner(message: errorMessage)
      }
    }
    .frame(
      minWidth: 900,
      maxWidth: .infinity,
      minHeight: 620,
      maxHeight: .infinity,
      alignment: .top
    )
    .task {
      usb.observe()
      await model.observe()
    }
    .sheet(isPresented: $isPresentingGuestProvisioning) {
      if let operatingSystem = machine.macOSGuestOperatingSystem {
        MacGuestProvisioningView(
          machineName: machine.name,
          operatingSystem: operatingSystem,
          runtimeModel: model,
          model: guestProvisioningModel
        )
      }
    }
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
      Text("The suspended session is permanently discarded before macOS starts.")
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
  }

  private var canOfferGuestProvisioning: Bool {
    guard !model.hasStartedSinceLoad,
      model.snapshot.canStart,
      model.snapshot.savedStateStatus == .none
    else {
      return false
    }
    return MacGuestProvisioningPolicy().isEligible(manifest: machine)
  }
}

private struct MacVirtualMachineRuntimeHeader: View {
  let machineName: String
  let snapshot: MacVirtualMachineRuntimeSnapshot
  let usb: MacVirtualMachineUSBModel
  @Binding var capturesSystemKeys: Bool
  let start: () -> Void
  let pause: () -> Void
  let resume: () -> Void
  let suspend: () -> Void
  let requestStop: () -> Void
  let confirmForceStop: () -> Void
  let confirmStartFresh: () -> Void
  let confirmDiscardSavedState: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(machineName)
          .font(.headline)
        HStack(spacing: 6) {
          MacVirtualMachineRuntimeStatusIndicator(state: snapshot.state)
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
          MacVirtualMachineRuntimeControls(
            snapshot: snapshot,
            start: start,
            pause: pause,
            resume: resume,
            suspend: suspend,
            requestStop: requestStop,
            confirmForceStop: confirmForceStop,
            confirmStartFresh: confirmStartFresh,
            confirmDiscardSavedState: confirmDiscardSavedState
          )
          MacVirtualMachineRuntimeAccessoryControls(
            machineName: machineName,
            usb: usb,
            capturesSystemKeys: $capturesSystemKeys
          )
        }
        VStack(alignment: .trailing, spacing: 8) {
          MacVirtualMachineRuntimeControls(
            snapshot: snapshot,
            start: start,
            pause: pause,
            resume: resume,
            suspend: suspend,
            requestStop: requestStop,
            confirmForceStop: confirmForceStop,
            confirmStartFresh: confirmStartFresh,
            confirmDiscardSavedState: confirmDiscardSavedState
          )
          MacVirtualMachineRuntimeAccessoryControls(
            machineName: machineName,
            usb: usb,
            capturesSystemKeys: $capturesSystemKeys
          )
        }
      }
    }
    .padding(14)
  }
}

private struct MacVirtualMachineRuntimeAccessoryControls: View {
  let machineName: String
  let usb: MacVirtualMachineUSBModel
  @Binding var capturesSystemKeys: Bool

  var body: some View {
    HStack(spacing: 12) {
      MacVirtualMachineShortcutCaptureToggle(
        isEnabled: $capturesSystemKeys
      )
      MacVirtualMachineUSBControl(
        machineName: machineName,
        model: usb
      )
    }
  }
}

private struct MacVirtualMachineShortcutCaptureToggle: View {
  @Binding var isEnabled: Bool

  var body: some View {
    Toggle("Capture Mac Shortcuts", isOn: $isEnabled)
      .toggleStyle(.switch)
      .help("Send system keyboard shortcuts to the guest instead of the host Mac.")
  }
}

private struct MacVirtualMachineRuntimeControls: View {
  let snapshot: MacVirtualMachineRuntimeSnapshot
  let start: () -> Void
  let pause: () -> Void
  let resume: () -> Void
  let suspend: () -> Void
  let requestStop: () -> Void
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

private struct MacVirtualMachineSavedStateBanner: View {
  let snapshot: MacVirtualMachineRuntimeSnapshot

  var body: some View {
    switch snapshot.savedStateStatus {
    case .available(let summary):
      HStack(spacing: 8) {
        Image(systemName: "moon.zzz.fill")
        Text(savedStateTitle)
          .fontWeight(.medium)
        Text(Int64(clamping: summary.stateSizeBytes), format: .byteCount(style: .file))
        if snapshot.target != nil {
          Text("Resuming this live session discards the checkpoint.")
        }
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(snapshot.target == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
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

private struct MacVirtualMachineConsoleContent: View {
  let model: MacVirtualMachineRuntimeModel
  let capturesSystemKeys: Bool

  var body: some View {
    #if arch(arm64)
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
          Label(model.snapshot.state.label, systemImage: "macwindow")
        } description: {
          Text(placeholder)
        }
      }
    #else
      ContentUnavailableView(
        "Apple silicon required",
        systemImage: "macwindow",
        description: Text("macOS virtual machines require a Mac with Apple silicon.")
      )
    #endif
  }

  private var placeholder: LocalizedStringResource {
    switch model.snapshot.state {
    case .stopped:
      if case .available = model.snapshot.savedStateStatus {
        return "Resume the suspended VM to attach its native display and keyboard."
      }
      return "Start the VM to attach its native display and keyboard."
    case .ownedElsewhere:
      return "This VM is active in another NativeContainers process."
    case .inspectingSavedState, .starting, .pausing, .paused, .resuming, .running,
      .saving, .restoring, .discardingSavedState, .stopping:
      return "The native display is becoming available."
    }
  }
}

struct MacVirtualMachineRuntimeStatusIndicator: View {
  let state: MacVirtualMachineRuntimeState

  var body: some View {
    switch state {
    case .running:
      Image(systemName: "circle.fill")
        .foregroundStyle(.green)
    case .paused:
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.yellow)
    case .inspectingSavedState, .starting, .pausing, .resuming, .saving, .restoring,
      .discardingSavedState, .stopping:
      ProgressView()
        .controlSize(.mini)
    case .stopped, .ownedElsewhere:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }
}

private struct MacVirtualMachineRuntimeErrorBanner: View {
  let message: String

  var body: some View {
    Divider()
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
  }
}

#Preview("macOS VM console") {
  let resources = try! VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  let machine = try! VirtualMachineManifest(
    name: "macOS Sequoia",
    guest: .macOS,
    installState: .stopped,
    resources: resources
  )
  let runtime = UnavailableMacVirtualMachineRuntimeService()
  MacVirtualMachineRuntimeView(
    machine: machine,
    model: MacVirtualMachineRuntimeModel(
      machineID: machine.id,
      service: runtime
    ),
    usb: MacVirtualMachineUSBModel(
      machineID: machine.id,
      service: UnavailableMacVirtualMachineUSBService(),
      runtime: runtime
    )
  )
}
