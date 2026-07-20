import SwiftUI

struct LinuxVirtualMachineConfigurationView: View {
  let machine: VirtualMachineManifest
  let runtime: LinuxVirtualMachineRuntimeModel
  let naming: VirtualMachineNameModel
  let compute: VirtualMachineComputeModel
  let diskMaintenance: VirtualMachineDiskImageMaintenanceModel
  let diskSnapshots: VirtualMachineDiskSnapshotModel
  let network: LinuxVirtualMachineNetworkModel
  let sharedDirectories: LinuxVirtualMachineSharedDirectoriesModel
  @State private var isConfirmingDiscardSavedState = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LinuxVirtualMachineConfigurationHeader(
          machine: machine,
          snapshot: runtime.snapshot,
          diskMaintenanceOperation: diskMaintenance.operation,
          diskSnapshotOperation: diskSnapshots.operation,
          isRefreshingDiskState: diskMaintenance.isRefreshing
        )
        VirtualMachineNameSection(
          naming: naming,
          refreshToken: machine.updatedAt,
          editMessage: runtimeEditMessage
        )
        VirtualMachineComputeSection(
          compute: compute,
          refreshToken: machine.updatedAt,
          editMessage: topologyEditMessage,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        LinuxVirtualMachineDiskImageMaintenanceView(
          machine: machine,
          runtime: runtime,
          maintenance: diskMaintenance,
          snapshotOperationIsBusy: diskSnapshots.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        VirtualMachineDiskSnapshotsSection(
          snapshots: diskSnapshots,
          editMessage: snapshotEditMessage,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        LinuxVirtualMachineBootSection(
          installState: machine.installState,
          configuration: machine.linuxConfiguration,
          hasLiveInstallationMedia: runtime.snapshot.hasInstallationMedia
        )
        LinuxVirtualMachineNetworkSection(
          editMessage: hardenedTopologyEditMessage,
          network: network,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        LinuxVirtualMachineConnectivitySection(
          macAddress: machine.linuxConfiguration?.macAddress,
          sharesClipboard: machine.linuxConfiguration?.sharesClipboard == true,
          isHardened: machine.isHardenedLinuxBox
        )
        LinuxVirtualMachineSharedDirectoriesView(
          runtimeState: runtime.snapshot.state,
          hasActiveRuntime: runtime.snapshot.target != nil,
          editMessage: hardenedTopologyEditMessage,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil,
          sharedDirectories: sharedDirectories
        )
        if let errorMessage =
          naming.errorMessage
          ?? compute.errorMessage
          ?? diskMaintenance.errorMessage
          ?? diskSnapshots.errorMessage
          ?? diskSnapshots.warningMessage
          ?? network.errorMessage
          ?? runtime.errorMessage
        {
          LinuxVirtualMachineConfigurationErrorBanner(
            message: errorMessage,
            dismiss: {
              naming.clearError()
              compute.clearError()
              diskMaintenance.clearError()
              diskSnapshots.clearMessages()
              network.clearError()
              runtime.clearActionError()
            }
          )
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle(machine.name)
    .task { await runtime.observe() }
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

  private var runtimeEditMessage: LocalizedStringResource? {
    guard !diskMaintenance.isBusy, !diskSnapshots.isBusy else {
      return "Wait for virtual disk maintenance to finish."
    }
    guard machine.linuxConfiguration != nil,
      machine.installState == .readyToInstall || machine.installState == .stopped
    else {
      return "Finish preparing this VM before changing its configuration."
    }
    guard runtime.snapshot.target == nil else {
      return "Shut down this VM before changing its configuration."
    }
    switch runtime.snapshot.state {
    case .stopped:
      return nil
    case .ownedElsewhere:
      return "Another NativeContainers process owns this VM."
    case .inspectingSavedState, .starting, .running, .pausing, .paused,
      .resuming, .saving, .restoring, .discardingSavedState,
      .ejectingInstallationMedia, .stopping:
      return "Wait for this VM to finish changing state."
    }
  }

  private var topologyEditMessage: LocalizedStringResource? {
    if let runtimeEditMessage { return runtimeEditMessage }
    return switch runtime.snapshot.savedStateStatus {
    case .none:
      nil
    case .unknown:
      "Checking the VM’s saved state…"
    case .available, .incompatible:
      "Discard the saved state before changing this VM’s configuration."
    }
  }

  private var hardenedTopologyEditMessage: LocalizedStringResource? {
    if machine.isHardenedLinuxBox {
      return "The Residential profile fixes networking to NAT, disables the shared clipboard, and prevents host folder sharing."
    }
    return topologyEditMessage
  }

  private var snapshotEditMessage: LocalizedStringResource? {
    guard !diskMaintenance.isBusy else {
      return "Wait for virtual disk maintenance to finish."
    }
    guard machine.installState == .stopped else {
      return "Finish installing this VM before creating disk snapshots."
    }
    guard runtime.snapshot.target == nil else {
      return "Shut down this VM before changing disk snapshots."
    }
    switch runtime.snapshot.state {
    case .stopped:
      break
    case .ownedElsewhere:
      return "Another NativeContainers process owns this VM."
    case .inspectingSavedState:
      return "Checking the VM’s saved state…"
    case .starting, .running, .pausing, .paused, .resuming, .saving,
      .restoring, .discardingSavedState, .ejectingInstallationMedia,
      .stopping:
      return "Wait for this VM to finish changing state."
    }
    return switch runtime.snapshot.savedStateStatus {
    case .none:
      nil
    case .unknown:
      "Checking the VM’s saved state…"
    case .available, .incompatible:
      "Discard the saved state before changing disk snapshots."
    }
  }

  private var canDiscardSavedState: Bool {
    !diskMaintenance.isBusy && !diskSnapshots.isBusy
      && runtime.snapshot.canDiscardSavedState
  }
}

private struct LinuxVirtualMachineNetworkSection: View {
  let editMessage: LocalizedStringResource?
  let network: LinuxVirtualMachineNetworkModel
  let discardSavedState: (() -> Void)?

  var body: some View {
    VirtualMachineNetworkContent(
      guest: .linux,
      attachment: network.attachment,
      isLoading: network.isLoading,
      isWorking: network.isWorking,
      editMessage: editMessage,
      select: { attachment in
        Task { await network.use(attachment) }
      },
      discardSavedState: discardSavedState
    )
    .task {
      await network.load()
    }
  }

}

private struct LinuxVirtualMachineConfigurationHeader: View {
  let machine: VirtualMachineManifest
  let snapshot: LinuxVirtualMachineRuntimeSnapshot
  let diskMaintenanceOperation: VirtualMachineDiskImageMaintenanceOperation?
  let diskSnapshotOperation: VirtualMachineDiskSnapshotOperation?
  let isRefreshingDiskState: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: "display")
        .font(.system(size: 34))
        .foregroundStyle(.mint)
        .frame(width: 46, height: 46)
        .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8) {
          Text(machine.name)
            .font(.title2.weight(.semibold))
          if let profile = machine.linuxConfiguration?.linuxBoxDescriptor?.profile {
            LinuxBoxProfileBadge(profile: profile)
          }
        }
        HStack(spacing: 7) {
          Group {
            if isRefreshingDiskState {
              ProgressView()
                .controlSize(.small)
              Text("Refreshing virtual disk state")
            } else if let diskMaintenanceOperation {
              ProgressView()
                .controlSize(.small)
              Text(diskMaintenanceOperation.progressLabel)
            } else if let diskSnapshotOperation {
              ProgressView()
                .controlSize(.small)
              Text(diskSnapshotOperation.progressLabel)
            } else {
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
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
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
  let macAddress: String?
  let sharesClipboard: Bool
  let isHardened: Bool

  var body: some View {
    GroupBox("Connectivity") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("MAC address") {
          if let macAddress {
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
    if isHardened { return "Disabled by Residential profile" }
    return sharesClipboard ? "Enabled" : "Disabled"
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
    case .inspectingSavedState, .starting, .pausing, .resuming, .saving,
      .restoring, .discardingSavedState, .ejectingInstallationMedia,
      .stopping:
      ProgressView()
        .controlSize(.mini)
    case .stopped, .ownedElsewhere:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }
}
