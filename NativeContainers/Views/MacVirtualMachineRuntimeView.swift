import SwiftUI

struct MacVirtualMachineRuntimeView: View {
  let machine: VirtualMachineManifest
  let model: MacVirtualMachineRuntimeModel

  @State private var capturesSystemKeys = false
  @State private var isConfirmingForceStop = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(machine.name)
            .font(.headline)
          HStack(spacing: 6) {
            runtimeStatus
            Text(model.snapshot.state.label)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
        }

        Spacer()
        controls
        Toggle("Capture Mac Shortcuts", isOn: $capturesSystemKeys)
          .toggleStyle(.switch)
          .help("Send system keyboard shortcuts to the guest instead of the host Mac.")
      }
      .padding(14)

      Divider()
      console
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))

      if let errorMessage = model.errorMessage {
        Divider()
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
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
  }

  @ViewBuilder
  private var controls: some View {
    HStack(spacing: 8) {
      if model.snapshot.canStart {
        Button("Start", systemImage: "play.fill") {
          Task { await model.start() }
        }
        .buttonStyle(.borderedProminent)
      }
      if model.snapshot.canPause {
        Button("Pause", systemImage: "pause.fill") {
          Task { await model.pause() }
        }
      }
      if model.snapshot.canResume {
        Button("Resume", systemImage: "play.fill") {
          Task { await model.resume() }
        }
      }
      if model.snapshot.canRequestStop {
        Button("Shut Down", systemImage: "power") {
          Task { await model.requestStop() }
        }
      }
      if model.snapshot.canForceStop {
        Button("Force Stop…", systemImage: "exclamationmark.octagon", role: .destructive) {
          isConfirmingForceStop = true
        }
      }
    }
  }

  @ViewBuilder
  private var console: some View {
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
          Text(consolePlaceholder)
        } actions: {
          if model.snapshot.canStart {
            Button("Start VM") { Task { await model.start() } }
              .buttonStyle(.borderedProminent)
          }
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

  @ViewBuilder
  private var runtimeStatus: some View {
    switch model.snapshot.state {
    case .running:
      Image(systemName: "circle.fill")
        .foregroundStyle(.green)
    case .paused:
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.yellow)
    case .starting, .pausing, .resuming, .stopping:
      ProgressView()
        .controlSize(.mini)
    case .stopped, .ownedElsewhere:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }

  private var consolePlaceholder: String {
    switch model.snapshot.state {
    case .stopped:
      "Start the VM to attach its native display and keyboard."
    case .ownedElsewhere:
      "This VM is active in another NativeContainers process."
    case .starting, .pausing, .paused, .resuming, .running, .stopping:
      "The native display is becoming available."
    }
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
  MacVirtualMachineRuntimeView(
    machine: machine,
    model: MacVirtualMachineRuntimeModel(
      machineID: machine.id,
      service: UnavailableMacVirtualMachineRuntimeService()
    )
  )
}
