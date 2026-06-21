import SwiftUI

struct MacVirtualMachineDiskImageSection: View {
  let format: VirtualMachineDiskImageFormat
  let migration: VirtualMachineDiskImageMigrationModel
  let migrationBlockReason: LocalizedStringResource?
  let requestMigration: () -> Void
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

        if migration.isMigrating {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Converting the virtual disk…")
              .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
              migration.cancelMigration()
            }
          }
        } else if migration.isRefreshing {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Refreshing virtual machine state…")
              .foregroundStyle(.secondary)
          }
        } else if let result = migration.lastResult {
          MacVirtualMachineDiskImageMigrationCompletion(
            reclaimedBytes: result.reclaimedBytes
          )
        } else if format == .raw {
          if let migrationBlockReason {
            HStack(spacing: 10) {
              Label(migrationBlockReason, systemImage: "lock.fill")
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

private struct MacVirtualMachineDiskImageMigrationCompletion: View {
  let reclaimedBytes: UInt64

  var body: some View {
    Label {
      if reclaimedBytes > 0 {
        Text(
          "Converted to ASIF and reclaimed \(Int64(clamping: reclaimedBytes), format: .byteCount(style: .file))."
        )
      } else {
        Text("Converted to ASIF.")
      }
    } icon: {
      Image(systemName: "checkmark.circle.fill")
    }
    .font(.callout)
    .foregroundStyle(.green)
  }
}
