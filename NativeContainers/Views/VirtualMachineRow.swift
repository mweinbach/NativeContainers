import SwiftUI

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let availability: MacVirtualMachineAvailability
  let runtime: MacVirtualMachineRuntimeModel
  let prepare: () -> Void
  let install: () -> Void
  let open: () -> Void
  let forceStop: () -> Void
  let discard: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: machine.guest == .macOS ? "macwindow" : "display")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 4) {
        Text(machine.name)
          .font(.headline)
        Text(installStateLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        VirtualMachineResourceSummary(resources: machine.resources)
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
              if runtime.snapshot.canRequestStop {
                Button("Shut Down", systemImage: "power") {
                  Task { await runtime.requestStop() }
                }
              }
              if runtime.snapshot.canForceStop {
                Button(
                  "Force Stop…",
                  systemImage: "exclamationmark.octagon",
                  role: .destructive,
                  action: forceStop
                )
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
        }
      }
    }
    .padding(.vertical, 7)
    .task { await runtime.observe() }
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
      Button(runtime.snapshot.state == .ownedElsewhere ? "Retry" : "Start") {
        Task { await runtime.start() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(availability != .available)
      .help(availability.unavailableReason ?? "Start macOS")
    case .running, .paused, .stopping:
      Button("Open", action: open)
        .buttonStyle(.borderedProminent)
    case .starting, .pausing, .resuming:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text(runtime.snapshot.state.label)
          .font(.caption)
      }
    }
  }

  private var installStateLabel: String {
    switch machine.installState {
    case .draft:
      "Needs restore image"
    case .readyToInstall:
      "Ready to install"
    case .installing:
      "Installing macOS"
    case .stopped:
      runtime.snapshot.state.label
    case .failed:
      machine.installationFailure?.message ?? "Needs attention"
    }
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
