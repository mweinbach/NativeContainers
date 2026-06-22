import SwiftUI

struct MacVirtualMachineDiskImageMaintenanceView: View {
  let machine: VirtualMachineManifest
  let runtime: MacVirtualMachineRuntimeModel
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let snapshotOperationIsBusy: Bool
  let discardSavedState: (() -> Void)?

  @State private var isConfirmingMigration = false
  @State private var isConfirmingRewrite = false

  var body: some View {
    MacVirtualMachineDiskImageSection(
      machineName: machine.name,
      currentLogicalBytes: machine.resources.diskBytes,
      format: machine.effectiveDiskImageFormat,
      maintenance: maintenance,
      growthBlockReason: growthBlockReason,
      optimizationBlockReason: optimizationBlockReason,
      requestMigration: { isConfirmingMigration = true },
      requestRewrite: { isConfirmingRewrite = true },
      discardSavedState: discardSavedState
    )
    .confirmationDialog(
      "Convert \(machine.name) to ASIF?",
      isPresented: $isConfirmingMigration
    ) {
      Button("Convert Virtual Disk") {
        maintenance.startMigration()
      }
    } message: {
      Text(
        "The VM stays powered off while a verified Apple sparse image is created. The RAW disk remains authoritative until the manifest commit, and cancellation stops the owned converter before removing its partial output."
      )
    }
    .confirmationDialog(
      "Rewrite the ASIF disk for \(machine.name)?",
      isPresented: $isConfirmingRewrite
    ) {
      Button("Rewrite Virtual Disk") {
        maintenance.startRewrite()
      }
    } message: {
      Text(
        "The VM stays powered off while a standalone ASIF candidate is created and verified. NativeContainers switches only if measured allocated bytes decrease; APFS free-space growth may differ. Cancellation stops the owned converter before cleanup."
      )
    }
  }

  private var growthBlockReason: LocalizedStringResource? {
    guard machine.installState == .stopped else {
      return "Finish installing this VM before maintaining its virtual disk."
    }
    guard #available(macOS 27.0, *) else {
      return "Virtual disk growth and ASIF maintenance require macOS 27 or later."
    }
    guard !snapshotOperationIsBusy else {
      return "Wait for the disk snapshot operation to finish."
    }
    guard runtime.snapshot.target == nil else {
      return "Shut down this VM before maintaining its virtual disk."
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
      return "Discard the saved state before maintaining the virtual disk."
    }
  }

  private var optimizationBlockReason: LocalizedStringResource? {
    if let growthBlockReason { return growthBlockReason }
    guard !machine.effectiveMacOSDiskSnapshotConfiguration.hasSnapshots else {
      return "Virtual disk conversion and rewrite are unavailable while snapshot history exists."
    }
    return nil
  }
}

struct MacVirtualMachineDiskImageSection: View {
  let machineName: String
  let currentLogicalBytes: UInt64
  let format: VirtualMachineDiskImageFormat
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let growthBlockReason: LocalizedStringResource?
  let optimizationBlockReason: LocalizedStringResource?
  let requestMigration: () -> Void
  let requestRewrite: () -> Void
  let discardSavedState: (() -> Void)?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(format.label)
              .font(.headline)
            Text(formatDescription)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(verbatim: format == .raw ? "RAW" : "ASIF")
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
            Spacer()
            if operation.canCancel {
              Button("Cancel") {
                maintenance.cancelMaintenance()
              }
            }
          }
        } else if let completion = maintenance.completion {
          HStack(spacing: 12) {
            MacVirtualMachineDiskImageMaintenanceCompletion(
              completion: completion
            )
            Spacer()
            Button("Dismiss") {
              maintenance.clearCompletion()
            }
          }
        } else {
          VirtualMachineDiskGrowthControls(
            machineName: machineName,
            currentLogicalBytes: currentLogicalBytes,
            maintenance: maintenance,
            blockReason: growthBlockReason,
            discardSavedState: discardSavedState
          )

          Divider()

          if let optimizationBlockReason {
            VirtualMachineConfigurationEditLockBanner(
              message: optimizationBlockReason,
              discardSavedState: discardSavedState
            )
          } else {
            switch format {
            case .raw:
              HStack {
                Text(
                  "Conversion is out-of-place and keeps the RAW disk authoritative until the ASIF image is verified."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Convert to ASIF…", action: requestMigration)
                  .buttonStyle(.borderedProminent)
              }
            case .asif:
              HStack {
                Text(
                  "A rewrite creates and verifies a standalone ASIF candidate, then switches only when its measured allocation is smaller."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Rewrite ASIF…", action: requestRewrite)
                  .buttonStyle(.borderedProminent)
              }
            }
          }
        }
      }
      .padding(.vertical, 4)
    } label: {
      Label("Virtual Disk", systemImage: "internaldrive")
    }
  }

  private var formatDescription: LocalizedStringResource {
    switch format {
    case .raw:
      "A fixed logical block mapping. Convert on macOS 27 to reduce host storage use and enable safe rewrite-based reclamation."
    case .asif:
      "Apple Sparse Image Format stores allocated blocks proportionally while preserving the guest disk capacity."
    }
  }
}

private struct MacVirtualMachineDiskImageMaintenanceCompletion: View {
  let completion: VirtualMachineDiskImageMaintenanceCompletion

  var body: some View {
    Label {
      switch completion {
      case .migration(let result):
        if result.reclaimedBytes > 0 {
          Text(
            "Converted to ASIF and measured \(Int64(clamping: result.reclaimedBytes), format: .byteCount(style: .file)) less allocated storage."
          )
        } else {
          Text("Converted to ASIF.")
        }
      case .rewrite(let result):
        if result.didReplace {
          Text(
            "Rewrote ASIF and measured \(Int64(clamping: result.reclaimedBytes), format: .byteCount(style: .file)) less allocated storage."
          )
        } else {
          Text(
            "Rewrite completed without a smaller allocation, so the current disk was kept."
          )
        }
      case .resize(let result):
        Text(
          "Grew the virtual disk by \(Int64(clamping: result.addedLogicalBytes), format: .byteCount(style: .file)). Expand the guest partition and file system after the next start."
        )
      }
    } icon: {
      Image(systemName: "checkmark.circle.fill")
    }
    .font(.callout)
    .foregroundStyle(.green)
  }
}
