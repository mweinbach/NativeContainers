import SwiftUI

struct MacVirtualMachineAudioSection: View {
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        MacVirtualMachineAudioCapabilityRow(
          title: "Output",
          detail: "Mac default output",
          systemImage: "speaker.wave.2.fill",
          isEnabled: true
        )
        Divider()
        MacVirtualMachineAudioCapabilityRow(
          title: "Microphone",
          detail: "Disconnected",
          systemImage: "mic.slash.fill",
          isEnabled: false
        )
        Divider()
        Text(
          "Guest audio follows the Mac’s current output device. NativeContainers does not request microphone access."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
      }
      .padding(.horizontal, 4)
    } label: {
      Label("Audio", systemImage: "waveform")
        .font(.headline)
    }
  }
}

private struct MacVirtualMachineAudioCapabilityRow: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let systemImage: String
  let isEnabled: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
        .frame(width: 24)
      Text(title)
      Spacer()
      Text(detail)
        .foregroundStyle(.secondary)
      Image(systemName: isEnabled ? "checkmark.circle.fill" : "minus.circle")
        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 10)
  }
}

#Preview("Mac virtual machine audio") {
  MacVirtualMachineAudioSection()
    .padding(24)
    .frame(width: 560)
}
