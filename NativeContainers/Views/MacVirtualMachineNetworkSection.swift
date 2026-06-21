import SwiftUI

struct MacVirtualMachineNetworkSection: View {
  let installState: VirtualMachineInstallState
  let runtime: MacVirtualMachineRuntimeModel
  let network: MacVirtualMachineNetworkModel
  let diskMaintenanceIsBusy: Bool
  let discardSavedState: (() -> Void)?

  var body: some View {
    let editBlock = MacVirtualMachineConfigurationEditPolicy().block(
      installState: installState,
      runtime: runtime.snapshot,
      diskMaintenanceIsBusy: diskMaintenanceIsBusy
    )
    MacVirtualMachineNetworkContent(
      attachment: network.attachment,
      isLoading: network.isLoading,
      isWorking: network.isWorking,
      editBlock: editBlock,
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

private struct MacVirtualMachineNetworkContent: View {
  let attachment: MacVirtualMachineNetworkAttachment
  let isLoading: Bool
  let isWorking: Bool
  let editBlock: MacVirtualMachineConfigurationEditBlock?
  let select: (MacVirtualMachineNetworkAttachment) -> Void
  let discardSavedState: (() -> Void)?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        if let editBlock {
          MacVirtualMachineConfigurationEditLockBanner(
            message: editBlock.message,
            discardSavedState: editBlock == .savedStatePresent
              ? discardSavedState : nil
          )
          .padding(.vertical, 8)
          Divider()
        }

        ForEach(MacVirtualMachineNetworkAttachment.allCases, id: \.self) { option in
          MacVirtualMachineNetworkOptionRow(
            option: option,
            isSelected: option == attachment,
            canEdit: editBlock == nil && !isLoading && !isWorking,
            select: { select(option) }
          )
          if option != MacVirtualMachineNetworkAttachment.allCases.last {
            Divider()
          }
        }

        Divider()
        MacVirtualMachineNetworkGuidance(attachment: attachment)
      }
      .padding(.horizontal, 4)
    } label: {
      HStack {
        Label("Network", systemImage: "network")
          .font(.headline)
        Spacer()
        if isLoading || isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
  }
}

private struct MacVirtualMachineNetworkOptionRow: View {
  let option: MacVirtualMachineNetworkAttachment
  let isSelected: Bool
  let canEdit: Bool
  let select: () -> Void

  var body: some View {
    Group {
      if isSelected {
        content
      } else {
        Button(action: select) {
          content
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
      }
    }
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private var content: some View {
    HStack(spacing: 12) {
      Image(systemName: option.systemImage)
        .foregroundStyle(option.tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(option.title)
        Text(option.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      Spacer(minLength: 16)
      if isSelected {
        Label("Selected", systemImage: "checkmark.circle.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.green)
          .accessibilityLabel("Selected")
      } else {
        Text("Use")
          .foregroundStyle(canEdit ? Color.accentColor : .secondary)
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 10)
  }
}

private struct MacVirtualMachineNetworkGuidance: View {
  let attachment: MacVirtualMachineNetworkAttachment

  var body: some View {
    Label {
      Text(attachment.guidance)
    } icon: {
      Image(
        systemName: attachment.usesCustomVmnetNetwork
          ? "exclamationmark.triangle"
          : "info.circle")
    }
    .font(.caption)
    .foregroundStyle(attachment.usesCustomVmnetNetwork ? .orange : .secondary)
    .padding(.vertical, 10)
  }
}

extension MacVirtualMachineNetworkAttachment {
  fileprivate var title: String {
    switch self {
    case .nat:
      "Automatic NAT"
    case .shared:
      "Shared VM Network"
    case .hostOnly:
      "Host-Only Network"
    }
  }

  fileprivate var summary: String {
    switch self {
    case .nat:
      "Private guest with outbound access through this Mac"
    case .shared:
      "VMs can reach each other, this Mac, and the internet"
    case .hostOnly:
      "VMs can reach each other and this Mac, without internet access"
    }
  }

  fileprivate var guidance: String {
    switch self {
    case .nat:
      "NAT is portable and supports suspend. Network changes apply on the next cold start."
    case .shared:
      "NativeContainers recreates this shared network when the app launches. Suspend is unavailable in this mode."
    case .hostOnly:
      "NativeContainers recreates this isolated network when the app launches. Suspend and external access are unavailable."
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .nat:
      "shield.lefthalf.filled"
    case .shared:
      "point.3.connected.trianglepath.dotted"
    case .hostOnly:
      "network.badge.shield.half.filled"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .nat:
      .green
    case .shared:
      .blue
    case .hostOnly:
      .orange
    }
  }
}

#Preview("Automatic NAT") {
  MacVirtualMachineNetworkContent(
    attachment: .nat,
    isLoading: false,
    isWorking: false,
    editBlock: nil,
    select: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 650)
}

#Preview("Shared VM network · Dark") {
  MacVirtualMachineNetworkContent(
    attachment: .shared,
    isLoading: false,
    isWorking: false,
    editBlock: nil,
    select: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 650)
  .preferredColorScheme(.dark)
}

#Preview("Host-only network locked") {
  MacVirtualMachineNetworkContent(
    attachment: .hostOnly,
    isLoading: false,
    isWorking: false,
    editBlock: .savedStatePresent,
    select: { _ in },
    discardSavedState: {}
  )
  .padding(24)
  .frame(width: 650)
}
