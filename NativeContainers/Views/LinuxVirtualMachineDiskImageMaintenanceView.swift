import SwiftUI

struct LinuxVirtualMachineDiskImageMaintenanceView: View {
  let machine: VirtualMachineManifest
  let runtime: LinuxVirtualMachineRuntimeModel
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let snapshotOperationIsBusy: Bool
  let discardSavedState: (() -> Void)?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(machine.effectiveDiskImageFormat.label)
              .font(.headline)
            Text(
              "DiskImageKit grows the virtual block device without rewriting guest data."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Text(
            verbatim:
              machine.effectiveDiskImageFormat == .raw ? "RAW" : "ASIF"
          )
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
          .accessibilityHidden(true)
        }

        if maintenance.isRefreshing {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Refreshing virtual machine state…")
              .foregroundStyle(.secondary)
          }
        } else if let operation = maintenance.operation {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text(operation.progressLabel)
              .foregroundStyle(.secondary)
          }
        } else if case .resize(let result) = maintenance.completion {
          HStack(spacing: 12) {
            Label {
              Text(
                "Grew the virtual disk by \(Int64(clamping: result.addedLogicalBytes), format: .byteCount(style: .file)). Expand the Linux partition and file system after the next start."
              )
            } icon: {
              Image(systemName: "checkmark.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.green)
            Spacer()
            Button("Dismiss") {
              maintenance.clearCompletion()
            }
          }
        } else {
          VirtualMachineDiskGrowthControls(
            machineName: machine.name,
            currentLogicalBytes: machine.resources.diskBytes,
            maintenance: maintenance,
            blockReason: growthBlockReason,
            discardSavedState: discardSavedState
          )
        }
      }
      .padding(.vertical, 4)
    } label: {
      Label("Virtual Disk", systemImage: "internaldrive")
    }
  }

  private var growthBlockReason: LocalizedStringResource? {
    guard !snapshotOperationIsBusy else {
      return "Wait for the disk snapshot operation to finish."
    }
    guard
      machine.installState == .readyToInstall
        || machine.installState == .stopped
    else {
      return "Finish preparing this VM before growing its virtual disk."
    }
    guard #available(macOS 27.0, *) else {
      return "Virtual disk growth requires macOS 27 or later."
    }
    guard runtime.snapshot.target == nil else {
      return "Shut down this VM before growing its virtual disk."
    }
    switch runtime.snapshot.state {
    case .stopped:
      break
    case .ownedElsewhere:
      return "Another NativeContainers process owns this VM."
    case .inspectingSavedState:
      return "Checking the VM’s saved state…"
    default:
      return "Wait for this VM to finish changing state."
    }
    switch runtime.snapshot.savedStateStatus {
    case .none:
      return nil
    case .unknown:
      return "Checking the VM’s saved state…"
    case .available, .incompatible:
      return "Discard the saved state before growing the virtual disk."
    }
  }
}
