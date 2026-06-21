import SwiftUI

struct LinuxVirtualMachineConfigurationView: View {
  let machine: VirtualMachineManifest
  let runtime: LinuxVirtualMachineRuntimeModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LinuxVirtualMachineConfigurationHeader(
          machine: machine,
          snapshot: runtime.snapshot
        )
        LinuxVirtualMachineResourcesSection(resources: machine.resources)
        LinuxVirtualMachineBootSection(
          installState: machine.installState,
          configuration: machine.linuxConfiguration,
          hasLiveInstallationMedia: runtime.snapshot.hasInstallationMedia
        )
        LinuxVirtualMachineConnectivitySection(
          configuration: machine.linuxConfiguration
        )
        if let errorMessage = runtime.errorMessage {
          LinuxVirtualMachineConfigurationErrorBanner(
            message: errorMessage,
            dismiss: runtime.clearActionError
          )
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle(machine.name)
    .task { runtime.observe() }
  }
}

private struct LinuxVirtualMachineConfigurationHeader: View {
  let machine: VirtualMachineManifest
  let snapshot: LinuxVirtualMachineRuntimeSnapshot

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: "display")
        .font(.system(size: 34))
        .foregroundStyle(.mint)
        .frame(width: 46, height: 46)
        .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 7) {
        Text(machine.name)
          .font(.title2.weight(.semibold))
        HStack(spacing: 7) {
          LinuxVirtualMachineRuntimeStatusIndicator(state: snapshot.state)
          Text(snapshot.state.label)
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
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct LinuxVirtualMachineResourcesSection: View {
  let resources: VirtualMachineResources

  var body: some View {
    GroupBox("Hardware") {
      VirtualMachineResourceSummary(resources: resources)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
  }
}

private struct LinuxVirtualMachineBootSection: View {
  let installState: VirtualMachineInstallState
  let configuration: LinuxVirtualMachineConfiguration?
  let hasLiveInstallationMedia: Bool

  var body: some View {
    GroupBox("Boot & Installation") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Firmware", value: "UEFI")
        LabeledContent("Installation") {
          Text(installationLabel)
        }
        LabeledContent("Installer ISO") {
          Text(installerLabel)
        }
        if configuration != nil {
          LabeledContent("Machine identity", value: "Persistent generic platform")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    }
  }

  private var installationLabel: LocalizedStringResource {
    switch installState {
    case .draft:
      "Needs installation media"
    case .readyToInstall:
      "Ready to install"
    case .installing:
      "Installing"
    case .stopped:
      "Installed"
    case .failed:
      "Needs attention"
    }
  }

  private var installerLabel: LocalizedStringResource {
    if hasLiveInstallationMedia { return "Attached to running guest" }
    return configuration?.installationMediaPath == nil
      ? "Ejected from future boots"
      : "Attached on next boot"
  }
}

private struct LinuxVirtualMachineConnectivitySection: View {
  let configuration: LinuxVirtualMachineConfiguration?

  var body: some View {
    GroupBox("Connectivity") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Network", value: "NAT")
        LabeledContent("MAC address") {
          if let macAddress = configuration?.macAddress {
            Text(macAddress)
          } else {
            Text("Not prepared")
          }
        }
        LabeledContent("Shared clipboard") {
          Text(sharedClipboardLabel)
        }
        LabeledContent("Display", value: "Virtio GPU")
        LabeledContent("Audio", value: "Host output")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    }
  }

  private var sharedClipboardLabel: LocalizedStringResource {
    configuration?.sharesClipboard == true ? "Enabled" : "Disabled"
  }
}

private struct LinuxVirtualMachineConfigurationErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
      Spacer()
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .padding(12)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct LinuxVirtualMachineRuntimeStatusIndicator: View {
  let state: LinuxVirtualMachineRuntimeState

  var body: some View {
    switch state {
    case .running:
      Image(systemName: "circle.fill")
        .foregroundStyle(.green)
    case .paused:
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.yellow)
    case .starting, .pausing, .resuming, .ejectingInstallationMedia, .stopping:
      ProgressView()
        .controlSize(.mini)
    case .stopped, .ownedElsewhere:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }
}
