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
    VirtualMachineNetworkContent(
      guest: .macOS,
      attachment: network.attachment,
      isLoading: network.isLoading,
      isWorking: network.isWorking,
      editMessage: editBlock?.message,
      select: { attachment in
        Task { await network.use(attachment) }
      },
      discardSavedState: editBlock == .savedStatePresent
        ? discardSavedState : nil
    )
    .task {
      await network.load()
    }
  }
}

struct VirtualMachineNetworkContent: View {
  let guest: VirtualMachineGuest
  let attachment: VirtualMachineNetworkAttachment
  let isLoading: Bool
  let isWorking: Bool
  let editMessage: LocalizedStringResource?
  let select: (VirtualMachineNetworkAttachment) -> Void
  let discardSavedState: (() -> Void)?

  var body: some View {
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

        ForEach(VirtualMachineNetworkAttachment.allCases, id: \.self) { option in
          VirtualMachineNetworkOptionRow(
            option: option,
            isSelected: option == attachment,
            canEdit: editMessage == nil && !isLoading && !isWorking,
            select: { select(option) }
          )
          if option != VirtualMachineNetworkAttachment.allCases.last {
            Divider()
          }
        }

        Divider()
        VirtualMachineNetworkGuidance(
          guest: guest,
          attachment: attachment
        )
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

private struct VirtualMachineNetworkOptionRow: View {
  let option: VirtualMachineNetworkAttachment
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

private struct VirtualMachineNetworkGuidance: View {
  let guest: VirtualMachineGuest
  let attachment: VirtualMachineNetworkAttachment

  var body: some View {
    Label {
      Text(guidance)
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

  private var guidance: LocalizedStringResource {
    switch (guest, attachment) {
    case (.macOS, .nat):
      "NAT is portable and supports suspend. Network changes apply on the next cold start."
    case (.macOS, .shared):
      "NativeContainers recreates this shared network when the app launches. Suspend is unavailable in this mode."
    case (.macOS, .hostOnly):
      "NativeContainers recreates this isolated network when the app launches. Suspend and external access are unavailable."
    case (.linux, .nat):
      "NAT is portable. Network changes apply on the next cold start."
    case (.linux, .shared):
      "NativeContainers recreates this shared network when the app launches. Changes apply on the next cold start."
    case (.linux, .hostOnly):
      "NativeContainers recreates this isolated network when the app launches. External access is unavailable."
    case (.windows, .nat):
      "NAT is portable. Network changes apply on the next cold start."
    case (.windows, .shared):
      "NativeContainers recreates this shared network when the app launches. Changes apply on the next cold start."
    case (.windows, .hostOnly):
      "NativeContainers recreates this isolated network when the app launches. External access is unavailable."
    }
  }
}

extension VirtualMachineNetworkAttachment {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .nat:
      "Automatic NAT"
    case .shared:
      "Shared VM Network"
    case .hostOnly:
      "Host-Only Network"
    }
  }

  fileprivate var summary: LocalizedStringResource {
    switch self {
    case .nat:
      "Private guest with outbound access through this Mac"
    case .shared:
      "VMs can reach each other, this Mac, and the internet"
    case .hostOnly:
      "VMs can reach each other and this Mac, without internet access"
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
  VirtualMachineNetworkContent(
    guest: .macOS,
    attachment: .nat,
    isLoading: false,
    isWorking: false,
    editMessage: nil,
    select: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 650)
}

#Preview("Shared VM network · Dark") {
  VirtualMachineNetworkContent(
    guest: .macOS,
    attachment: .shared,
    isLoading: false,
    isWorking: false,
    editMessage: nil,
    select: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 650)
  .preferredColorScheme(.dark)
}

#Preview("Host-only network locked") {
  VirtualMachineNetworkContent(
    guest: .macOS,
    attachment: .hostOnly,
    isLoading: false,
    isWorking: false,
    editMessage: MacVirtualMachineConfigurationEditBlock.savedStatePresent.message,
    select: { _ in },
    discardSavedState: {}
  )
  .padding(24)
  .frame(width: 650)
}

#Preview("Linux shared network") {
  VirtualMachineNetworkContent(
    guest: .linux,
    attachment: .shared,
    isLoading: false,
    isWorking: false,
    editMessage: nil,
    select: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 650)
}
