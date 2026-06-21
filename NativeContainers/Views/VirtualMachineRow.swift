import SwiftUI

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let installationAvailability: MacVirtualMachineInstallationAvailability
  let prepare: () -> Void
  let install: () -> Void
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
            Button("Discard VM…", role: .destructive, action: discard)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .help("More virtual machine actions")
        }
      }
    }
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private var action: some View {
    switch machine.installState {
    case .draft:
      Button("Prepare…", action: prepare)
        .buttonStyle(.borderedProminent)
        .disabled(installationAvailability != .available)
        .help(installationAvailability.unavailableReason ?? "Prepare macOS")
    case .readyToInstall:
      Button("Install…", action: install)
        .buttonStyle(.borderedProminent)
        .disabled(installationAvailability != .available)
        .help(installationAvailability.unavailableReason ?? "Install macOS")
    case .installing:
      ProgressView()
        .controlSize(.small)
        .help("macOS installation is active.")
    case .stopped:
      Button("Open") {}
        .disabled(true)
        .help("VM lifecycle and console ownership are the next implementation slice.")
    case .failed:
      Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
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
