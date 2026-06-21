import SwiftUI

struct MacVirtualMachineDiskImageMaintenanceView: View {
  let machine: VirtualMachineManifest
  let runtime: MacVirtualMachineRuntimeModel
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let discardSavedState: (() -> Void)?

  @State private var isConfirmingMigration = false
  @State private var isConfirmingRewrite = false

  var body: some View {
    MacVirtualMachineDiskImageSection(
      format: machine.effectiveDiskImageFormat,
      maintenance: maintenance,
      maintenanceBlockReason: maintenanceBlockReason,
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

  private var maintenanceBlockReason: LocalizedStringResource? {
    guard machine.installState == .stopped else {
      return "Finish installing this VM before maintaining its virtual disk."
    }
    guard #available(macOS 27.0, *) else {
      return "ASIF disk maintenance requires macOS 27 or later."
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
}

struct MacVirtualMachineDiskImageSection: View {
  let format: VirtualMachineDiskImageFormat
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let maintenanceBlockReason: LocalizedStringResource?
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
            Text(
              operation == .migration
                ? "Converting the virtual disk…"
                : "Rewriting the virtual disk…"
            )
            .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
              maintenance.cancelMaintenance()
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
        } else if let maintenanceBlockReason {
          HStack(spacing: 10) {
            Label(maintenanceBlockReason, systemImage: "lock.fill")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            if let discardSavedState {
              Button("Discard Saved State…", action: discardSavedState)
            }
          }
          .padding(10)
          .background(
            .quaternary.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 8)
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
      }
    } icon: {
      Image(systemName: "checkmark.circle.fill")
    }
    .font(.callout)
    .foregroundStyle(.green)
  }
}
