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
          guest: machine.guest,
          installState: machine.installState,
          hasConfiguration: hasEFIConfiguration,
          installationMediaPath: installationMediaPath,
          securityMode: machine.windowsConfiguration?.securityMode,
          hasLiveInstallationMedia: runtime.snapshot.hasInstallationMedia
        )
        LinuxVirtualMachineNetworkSection(
          guest: machine.guest,
          editMessage: topologyEditMessage,
          network: network,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        LinuxVirtualMachineConnectivitySection(
          guest: machine.guest,
          macAddress: efiMACAddress,
          sharesClipboard: sharesClipboard,
          hasGuestTools: machine.windowsConfiguration?.guestTools != nil
        )
        if let windows = machine.windowsConfiguration {
          WindowsVirtualMachineIntegrationSection(
            securityMode: windows.securityMode,
            media: windows.installationMedia,
            guestTools: windows.guestTools,
            guestToolsMediaAttached: windows.effectiveGuestToolsMediaAttached
          )
        }
        LinuxVirtualMachineSharedDirectoriesView(
          guest: machine.guest,
          runtimeState: runtime.snapshot.state,
          hasActiveRuntime: runtime.snapshot.target != nil,
          editMessage: topologyEditMessage,
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
    guard hasEFIConfiguration,
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

  private var hasEFIConfiguration: Bool {
    machine.linuxConfiguration != nil || machine.windowsConfiguration != nil
  }

  private var installationMediaPath: String? {
    machine.linuxConfiguration?.installationMediaPath
      ?? machine.windowsConfiguration?.installationMediaPath
  }

  private var efiMACAddress: String? {
    machine.linuxConfiguration?.macAddress
      ?? machine.windowsConfiguration?.macAddress
  }

  private var sharesClipboard: Bool {
    machine.linuxConfiguration?.sharesClipboard
      ?? machine.windowsConfiguration?.sharesClipboard
      ?? false
  }
}

private struct LinuxVirtualMachineNetworkSection: View {
  let guest: VirtualMachineGuest
  let editMessage: LocalizedStringResource?
  let network: LinuxVirtualMachineNetworkModel
  let discardSavedState: (() -> Void)?

  var body: some View {
    VirtualMachineNetworkContent(
      guest: guest,
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
      Image(systemName: machine.guest == .windows ? "rectangle" : "display")
        .font(.system(size: 34))
        .foregroundStyle(machine.guest == .windows ? Color.blue : Color.mint)
        .frame(width: 46, height: 46)
        .background(
          (machine.guest == .windows ? Color.blue : Color.mint).opacity(0.12),
          in: RoundedRectangle(cornerRadius: 10)
        )
      VStack(alignment: .leading, spacing: 7) {
        Text(machine.name)
          .font(.title2.weight(.semibold))
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
  let guest: VirtualMachineGuest
  let installState: VirtualMachineInstallState
  let hasConfiguration: Bool
  let installationMediaPath: String?
  let securityMode: WindowsVirtualMachineSecurityMode?
  let hasLiveInstallationMedia: Bool

  var body: some View {
    GroupBox("Boot & Installation") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Firmware") {
          Text(firmwareLabel)
        }
        LabeledContent("Installation") {
          Text(installationLabel)
        }
        LabeledContent("Installer ISO") {
          Text(installerLabel)
        }
        if hasConfiguration {
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
    return installationMediaPath == nil
      ? "Ejected from future boots"
      : "Attached on next boot"
  }

  private var firmwareLabel: LocalizedStringResource {
    guard guest == .windows else { return "UEFI" }
    return securityMode == .productionSecureBoot
      ? "UEFI with Secure Boot"
      : "UEFI with Secure Boot disabled"
  }
}

private struct LinuxVirtualMachineConnectivitySection: View {
  let guest: VirtualMachineGuest
  let macAddress: String?
  let sharesClipboard: Bool
  let hasGuestTools: Bool

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
        LabeledContent("Audio") {
          Text(audioLabel)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    }
  }

  private var sharedClipboardLabel: LocalizedStringResource {
    if guest == .windows, !hasGuestTools {
      return "Requires signed guest tools"
    }
    return sharesClipboard ? "Enabled" : "Disabled"
  }

  private var audioLabel: LocalizedStringResource {
    guest == .windows
      ? "Virtio sound • requires NativeContainers driver"
      : "Host output"
  }
}

private struct WindowsVirtualMachineIntegrationSection: View {
  let securityMode: WindowsVirtualMachineSecurityMode
  let media: WindowsInstallationMediaMetadata
  let guestTools: WindowsGuestToolsReleaseReference?
  let guestToolsMediaAttached: Bool

  var body: some View {
    GroupBox("Windows Compatibility") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Installer architecture", value: "ARM64")
        LabeledContent("Installer volume") {
          Text(media.volumeLabel)
        }
        LabeledContent("Installer size") {
          Text(Int64(clamping: media.byteCount), format: .byteCount(style: .file))
        }
        LabeledContent("Installer SHA-256") {
          Text(verbatim: media.sha256)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(2)
        }
        LabeledContent("TPM 2.0", value: "Unavailable in Virtualization.framework")
        LabeledContent("Setup compatibility", value: "TPM check only")
        LabeledContent("Security mode") {
          Text(securityLabel)
        }
        LabeledContent("Guest tools") {
          Text(guestToolsLabel)
        }
        if securityMode == .developmentTestSigning {
          Label(
            "Secure Boot is disabled. This is the current bootable Windows mode.",
            systemImage: "checkmark.shield.fill"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Label(
            "Booting is disabled until the signed guest drivers pass release validation.",
            systemImage: "lock.shield.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    }
  }

  private var securityLabel: LocalizedStringResource {
    securityMode == .productionSecureBoot
      ? "Secure Boot • boot unavailable"
      : "Secure Boot off • bootable"
  }

  private var guestToolsLabel: LocalizedStringResource {
    guard let guestTools else {
      return "Not attached • production drivers are not yet Microsoft-signed"
    }
    return guestToolsMediaAttached
      ? "Version \(guestTools.version) attached"
      : "Version \(guestTools.version) installed"
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
