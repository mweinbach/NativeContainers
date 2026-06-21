import SwiftUI

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let prepare: () -> Void
  let install: () -> Void

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
      action
    }
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private var action: some View {
    switch machine.installState {
    case .draft:
      Button("Prepare…", action: prepare)
        .buttonStyle(.borderedProminent)
    case .readyToInstall:
      Button("Install…", action: install)
        .buttonStyle(.borderedProminent)
    case .installing:
      ProgressView()
        .controlSize(.small)
        .help("macOS installation is active.")
    case .stopped:
      Button("Open") {}
        .disabled(true)
        .help("VM lifecycle and console ownership are the next implementation slice.")
    case .failed:
      Label("Reset required", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .help(machine.installationFailure?.message ?? "The VM needs attention.")
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
      "Stopped"
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
