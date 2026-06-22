import SwiftUI

struct VirtualMachineComputeSection: View {
  let compute: VirtualMachineComputeModel
  let refreshToken: Date
  let editMessage: LocalizedStringResource?
  let discardSavedState: (() -> Void)?

  var body: some View {
    @Bindable var compute = compute

    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        if let editMessage {
          VirtualMachineConfigurationEditLockBanner(
            message: editMessage,
            discardSavedState: discardSavedState
          )
          .padding(.vertical, 8)
          Divider()
        }

        VirtualMachineCPUCountRow(
          cpuCount: compute.cpuCount,
          cpuRange: compute.cpuRange,
          isEnabled: canEdit,
          selection: $compute.cpuCount
        )
        Divider()
        VirtualMachineMemoryRow(
          memoryGiB: compute.memoryGiB,
          memoryGiBRange: compute.memoryGiBRange,
          isEnabled: canEdit,
          selection: $compute.memoryGiB
        )
        Divider()
        LabeledContent("Disk capacity") {
          Text(
            Int64(clamping: compute.diskBytes),
            format: .byteCount(style: .file)
          )
        }
        .padding(.vertical, 10)
        Divider()
        HStack(alignment: .center, spacing: 12) {
          Label(
            "CPU and memory changes apply on the next cold start. Disk capacity uses separate storage maintenance.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer(minLength: 12)
          Button("Revert", action: compute.resetChanges)
            .disabled(!canEdit || !compute.hasChanges)
          Button("Apply") {
            Task { await compute.save() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canEdit || !compute.hasChanges)
        }
        .padding(.vertical, 10)
      }
      .padding(.horizontal, 4)
    } label: {
      HStack {
        Label("Compute", systemImage: "cpu")
          .font(.headline)
        Spacer()
        if compute.isLoading || compute.isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .task(id: refreshToken) {
      await compute.reload()
    }
  }

  private var canEdit: Bool {
    editMessage == nil
      && compute.isLoaded
      && !compute.isLoading
      && !compute.isWorking
  }
}

private struct VirtualMachineCPUCountRow: View {
  let cpuCount: Int
  let cpuRange: ClosedRange<Int>
  let isEnabled: Bool
  @Binding var selection: Int

  var body: some View {
    HStack(spacing: 12) {
      Label("Virtual CPUs", systemImage: "cpu")
      Spacer()
      Text(cpuCount, format: .number)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Stepper(
        "Virtual CPUs",
        value: $selection,
        in: cpuRange
      )
      .labelsHidden()
      .disabled(!isEnabled)
    }
    .padding(.vertical, 10)
  }
}

private struct VirtualMachineMemoryRow: View {
  let memoryGiB: Int
  let memoryGiBRange: ClosedRange<Int>
  let isEnabled: Bool
  @Binding var selection: Int

  var body: some View {
    HStack(spacing: 12) {
      Label("Memory", systemImage: "memorychip")
      Spacer()
      Text("\(memoryGiB) GiB")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Stepper(
        "Memory",
        value: $selection,
        in: memoryGiBRange
      )
      .labelsHidden()
      .disabled(!isEnabled)
    }
    .padding(.vertical, 10)
  }
}

#Preview("Editable compute") {
  VirtualMachineComputeSection(
    compute: VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try! VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      ),
      service: PreviewVirtualMachineComputeService()
    ),
    refreshToken: .distantPast,
    editMessage: nil,
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 680)
}

#Preview("Compute locked by saved state") {
  VirtualMachineComputeSection(
    compute: VirtualMachineComputeModel(
      machineID: UUID(),
      initialResources: try! VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      ),
      service: PreviewVirtualMachineComputeService()
    ),
    refreshToken: .distantPast,
    editMessage: MacVirtualMachineConfigurationEditBlock.savedStatePresent.message,
    discardSavedState: {}
  )
  .padding(24)
  .frame(width: 680)
}

private actor PreviewVirtualMachineComputeService:
  VirtualMachineComputeManaging
{
  private var configuration = VirtualMachineComputeConfiguration(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB
  )

  func snapshot(id: UUID) -> VirtualMachineComputeSnapshot {
    makeSnapshot()
  }

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) -> VirtualMachineComputeSnapshot {
    self.configuration = configuration
    return makeSnapshot()
  }

  private func makeSnapshot() -> VirtualMachineComputeSnapshot {
    VirtualMachineComputeSnapshot(
      configuration: configuration,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB,
      limits: VirtualMachineComputeLimits(
        minimumCPUCount: 1,
        maximumCPUCount: 12,
        minimumMemoryBytes: VirtualMachineResources.bytesPerGiB,
        maximumMemoryBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}
