import SwiftUI

struct MacVirtualMachineConfigurationView: View {
  let machine: VirtualMachineManifest
  let runtime: MacVirtualMachineRuntimeModel

  @State private var audio: MacVirtualMachineAudioModel
  @State private var network: MacVirtualMachineNetworkModel
  let naming: VirtualMachineNameModel
  let compute: VirtualMachineComputeModel
  @State private var diskSnapshots: MacVirtualMachineDiskSnapshotModel
  @State private var sharedDirectories: MacVirtualMachineSharedDirectoriesModel
  let diskMaintenance: VirtualMachineDiskImageMaintenanceModel
  @State private var isConfirmingDiscardSavedState = false

  init(
    machine: VirtualMachineManifest,
    runtime: MacVirtualMachineRuntimeModel,
    audio: MacVirtualMachineAudioModel,
    network: MacVirtualMachineNetworkModel,
    naming: VirtualMachineNameModel,
    compute: VirtualMachineComputeModel,
    diskSnapshots: MacVirtualMachineDiskSnapshotModel,
    sharedDirectories: MacVirtualMachineSharedDirectoriesModel,
    diskMaintenance: VirtualMachineDiskImageMaintenanceModel
  ) {
    self.machine = machine
    self.runtime = runtime
    _audio = State(initialValue: audio)
    _network = State(initialValue: network)
    self.naming = naming
    self.compute = compute
    _diskSnapshots = State(initialValue: diskSnapshots)
    _sharedDirectories = State(initialValue: sharedDirectories)
    self.diskMaintenance = diskMaintenance
  }

  var body: some View {
    let computeEditBlock = MacVirtualMachineConfigurationEditPolicy().block(
      installState: machine.installState,
      runtime: runtime.snapshot,
      diskMaintenanceIsBusy: diskMaintenance.isBusy || diskSnapshots.isBusy
    )
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        MacVirtualMachineConfigurationHeader(
          machine: machine,
          runtimeState: runtime.snapshot.state,
          diskMaintenanceOperation: diskMaintenance.operation,
          diskSnapshotOperation: diskSnapshots.operation,
          isRefreshingDiskState: diskMaintenance.isRefreshing
        )
        VirtualMachineNameSection(
          naming: naming,
          refreshToken: machine.updatedAt,
          editMessage: nameEditMessage
        )
        VirtualMachineComputeSection(
          compute: compute,
          refreshToken: machine.updatedAt,
          editMessage: computeEditBlock?.message,
          discardSavedState: computeEditBlock == .savedStatePresent
            && canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        MacVirtualMachineNetworkSection(
          installState: machine.installState,
          runtime: runtime,
          network: network,
          diskMaintenanceIsBusy: diskMaintenance.isBusy || diskSnapshots.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        MacVirtualMachineAudioSection(
          installState: machine.installState,
          runtime: runtime,
          audio: audio,
          diskMaintenanceIsBusy: diskMaintenance.isBusy || diskSnapshots.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        MacVirtualMachineDiskImageMaintenanceView(
          machine: machine,
          runtime: runtime,
          maintenance: diskMaintenance,
          snapshotOperationIsBusy: diskSnapshots.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        MacVirtualMachineDiskSnapshotsSection(
          installState: machine.installState,
          runtime: runtime,
          snapshots: diskSnapshots,
          diskMaintenanceIsBusy: diskMaintenance.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        MacVirtualMachineSharedDirectoriesView(
          machine: machine,
          runtime: runtime,
          sharedDirectories: sharedDirectories,
          diskMaintenanceIsBusy: diskMaintenance.isBusy || diskSnapshots.isBusy,
          discardSavedState: canDiscardSavedState
            ? { isConfirmingDiscardSavedState = true } : nil
        )
        if let errorMessage =
          naming.errorMessage
          ?? compute.errorMessage
          ?? network.errorMessage
          ?? audio.errorMessage
          ?? diskSnapshots.errorMessage
          ?? diskSnapshots.warningMessage
          ?? sharedDirectories.errorMessage
          ?? diskMaintenance.errorMessage
          ?? runtime.errorMessage
        {
          MacVirtualMachineConfigurationErrorBanner(
            message: errorMessage,
            dismiss: {
              naming.clearError()
              compute.clearError()
              network.clearError()
              audio.clearError()
              diskSnapshots.clearMessages()
              sharedDirectories.clearError()
              diskMaintenance.clearError()
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
    .task {
      await runtime.observe()
    }
    .confirmationDialog(
      "Discard the saved state for \(machine.name)?",
      isPresented: $isConfirmingDiscardSavedState
    ) {
      Button("Discard Saved State", role: .destructive) {
        Task { await runtime.discardSavedState() }
      }
    } message: {
      Text(
        "The VM remains powered off, but its suspended session cannot be resumed. Disk snapshot and maintenance operations, network changes, audio changes, and shared-folder changes can then proceed."
      )
    }
  }

  private var canDiscardSavedState: Bool {
    machine.installState == .stopped && !diskMaintenance.isBusy
      && !diskSnapshots.isBusy && runtime.snapshot.canDiscardSavedState
  }

  private var nameEditMessage: LocalizedStringResource? {
    MacVirtualMachineConfigurationEditPolicy().nameBlock(
      installState: machine.installState,
      runtime: runtime.snapshot,
      diskMaintenanceIsBusy: diskMaintenance.isBusy || diskSnapshots.isBusy
    )?.message
  }
}

private struct MacVirtualMachineConfigurationHeader: View {
  let machine: VirtualMachineManifest
  let runtimeState: MacVirtualMachineRuntimeState
  let diskMaintenanceOperation: VirtualMachineDiskImageMaintenanceOperation?
  let diskSnapshotOperation: MacVirtualMachineDiskSnapshotOperation?
  let isRefreshingDiskState: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: "macwindow")
        .font(.system(size: 34))
        .foregroundStyle(.indigo)
        .frame(width: 46, height: 46)
        .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 7) {
        Text(machine.name)
          .font(.title2.weight(.semibold))
        HStack(spacing: 8) {
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
              MacVirtualMachineRuntimeStatusIndicator(state: runtimeState)
              Text(runtimeState.label)
            }
          }
          .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        VirtualMachineResourceSummary(resources: machine.resources)
      }
    }
  }
}

private struct MacVirtualMachineConfigurationErrorBanner: View {
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
