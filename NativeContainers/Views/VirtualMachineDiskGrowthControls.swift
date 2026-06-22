import SwiftUI

struct VirtualMachineDiskGrowthControls: View {
  let machineName: String
  let currentLogicalBytes: UInt64
  let maintenance: VirtualMachineDiskImageMaintenanceModel
  let blockReason: LocalizedStringResource?
  let discardSavedState: (() -> Void)?

  @State private var requestedGiB = ""
  @State private var isConfirmingGrowth = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent("Capacity") {
        Text(
          Int64(clamping: currentLogicalBytes),
          format: .byteCount(style: .file)
        )
      }

      if let blockReason {
        VirtualMachineConfigurationEditLockBanner(
          message: blockReason,
          discardSavedState: discardSavedState
        )
      } else {
        HStack(spacing: 10) {
          TextField("New capacity", text: $requestedGiB)
            .frame(width: 130)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("New virtual disk capacity in GiB")
          Text("GiB")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Grow Disk…") {
            isConfirmingGrowth = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(targetLogicalBytes == nil)
        }
      }

      Label(
        "Growth changes the virtual disk only. After the next start, expand the guest partition and file system to use the added capacity. Shrinking is unavailable.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .confirmationDialog(
      "Grow the virtual disk for \(machineName)?",
      isPresented: $isConfirmingGrowth
    ) {
      if let targetLogicalBytes {
        Button("Grow Virtual Disk") {
          maintenance.startResize(to: targetLogicalBytes)
        }
      }
    } message: {
      if let targetLogicalBytes {
        Text(
          "NativeContainers will grow the disk to \(Int64(clamping: targetLogicalBytes), format: .byteCount(style: .file)). This cannot be undone by shrinking the image, and the guest partition and file system keep their current size until you expand them inside the VM."
        )
      }
    }
  }

  private var targetLogicalBytes: UInt64? {
    guard
      let gibibytes = UInt64(
        requestedGiB.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    else {
      return nil
    }
    let (bytes, overflow) = gibibytes.multipliedReportingOverflow(
      by: VirtualMachineResources.bytesPerGiB
    )
    guard !overflow, bytes > currentLogicalBytes else { return nil }
    return bytes
  }
}
