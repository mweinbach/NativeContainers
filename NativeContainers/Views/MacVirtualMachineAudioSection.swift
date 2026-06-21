import SwiftUI

struct MacVirtualMachineAudioSection: View {
  let installState: VirtualMachineInstallState
  let runtime: MacVirtualMachineRuntimeModel
  let audio: MacVirtualMachineAudioModel
  let diskMaintenanceIsBusy: Bool
  let discardSavedState: (() -> Void)?

  var body: some View {
    let editBlock = MacVirtualMachineConfigurationEditPolicy().block(
      installState: installState,
      runtime: runtime.snapshot,
      diskMaintenanceIsBusy: diskMaintenanceIsBusy
    )
    MacVirtualMachineAudioContent(
      isMicrophoneEnabled: audio.isMicrophoneEnabled,
      microphoneAuthorization: audio.microphoneAuthorization,
      isLoading: audio.isLoading,
      isWorking: audio.isWorking,
      editBlock: editBlock,
      toggleMicrophone: {
        Task {
          await audio.setMicrophoneEnabled(!audio.isMicrophoneEnabled)
        }
      },
      discardSavedState: discardSavedState
    )
    .task {
      await audio.load()
    }
  }
}

private struct MacVirtualMachineAudioContent: View {
  let isMicrophoneEnabled: Bool
  let microphoneAuthorization: MacVirtualMachineMicrophoneAuthorizationStatus
  let isLoading: Bool
  let isWorking: Bool
  let editBlock: MacVirtualMachineConfigurationEditBlock?
  let toggleMicrophone: () -> Void
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
        }

        MacVirtualMachineAudioOutputRow()
        Divider()
        MacVirtualMachineMicrophoneRow(
          isEnabled: isMicrophoneEnabled,
          authorization: microphoneAuthorization,
          isLoading: isLoading,
          isWorking: isWorking,
          canEdit: editBlock == nil,
          toggle: toggleMicrophone
        )
        Divider()
        MacVirtualMachineAudioPrivacyNote(
          isMicrophoneEnabled: isMicrophoneEnabled,
          authorization: microphoneAuthorization
        )
      }
      .padding(.horizontal, 4)
    } label: {
      Label("Audio", systemImage: "waveform")
        .font(.headline)
    }
  }
}

private struct MacVirtualMachineAudioOutputRow: View {
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.wave.2.fill")
        .foregroundStyle(.green)
        .frame(width: 24)
        .accessibilityHidden(true)
      Text("Output")
      Spacer()
      Text("Mac default output")
        .foregroundStyle(.secondary)
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 10)
  }
}

private struct MacVirtualMachineMicrophoneRow: View {
  let isEnabled: Bool
  let authorization: MacVirtualMachineMicrophoneAuthorizationStatus
  let isLoading: Bool
  let isWorking: Bool
  let canEdit: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: isEnabled ? "mic.fill" : "mic.slash.fill")
        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      Text("Microphone")
      Spacer()
      if isLoading || isWorking {
        ProgressView()
          .controlSize(.small)
      }
      Text(detail)
        .foregroundStyle(.secondary)
      Button(buttonTitle, action: toggle)
        .disabled(!canEdit || isLoading || isWorking)
    }
    .padding(.vertical, 10)
  }

  private var detail: LocalizedStringResource {
    guard isEnabled else { return "Disconnected" }
    return switch authorization {
    case .authorized:
      "Mac default input"
    case .notDetermined:
      "Permission pending"
    case .denied:
      "Access denied"
    case .restricted:
      "Access restricted"
    }
  }

  private var buttonTitle: LocalizedStringResource {
    isEnabled ? "Disconnect" : "Connect…"
  }
}

private struct MacVirtualMachineAudioPrivacyNote: View {
  let isMicrophoneEnabled: Bool
  let authorization: MacVirtualMachineMicrophoneAuthorizationStatus

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(isWarning ? Color.orange : Color.secondary)
      .padding(.vertical, 10)
  }

  private var message: LocalizedStringResource {
    switch authorization {
    case .denied where isMicrophoneEnabled:
      "Microphone access is denied in System Settings. Disconnect it or grant access before starting the VM."
    case .restricted where isMicrophoneEnabled:
      "Microphone access is restricted on this Mac. Disconnect it before starting the VM."
    default:
      "Guest audio follows the Mac’s current devices. Microphone access is requested only when you connect it."
    }
  }

  private var isWarning: Bool {
    isMicrophoneEnabled
      && (authorization == .denied || authorization == .restricted)
  }
}

#Preview("Disconnected microphone") {
  MacVirtualMachineAudioContent(
    isMicrophoneEnabled: false,
    microphoneAuthorization: .notDetermined,
    isLoading: false,
    isWorking: false,
    editBlock: nil,
    toggleMicrophone: {},
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 600)
}

#Preview("Connected microphone") {
  MacVirtualMachineAudioContent(
    isMicrophoneEnabled: true,
    microphoneAuthorization: .authorized,
    isLoading: false,
    isWorking: false,
    editBlock: nil,
    toggleMicrophone: {},
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 600)
}
