import SwiftUI

struct MacVirtualMachineConfigurationEditLockBanner: View {
  let message: LocalizedStringResource
  let discardSavedState: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      Label(message, systemImage: "lock.fill")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      if let discardSavedState {
        Button("Discard Saved State…", action: discardSavedState)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
  }
}
