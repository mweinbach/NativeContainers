import SwiftUI

struct AppNotificationSettingsSection: View {
  let model: AppNotificationSettingsModel

  var body: some View {
    Section("Notifications") {
      LabeledContent("Authorization") {
        Text(model.settings.authorization.title)
      }

      AppNotificationChannelSummary(settings: model.settings)
      AppNotificationPermissionGuidance(status: model.settings.authorization)

      AppNotificationPermissionActions(model: model)

      if model.isWorking {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing notification status")
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .task {
      await model.refresh()
    }
  }
}

private struct AppNotificationChannelSummary: View {
  let settings: AppNotificationSettingsSnapshot

  var body: some View {
    LabeledContent("Alerts") {
      Text(settings.alerts.title)
    }

    LabeledContent("Sounds") {
      Text(settings.sounds.title)
    }
  }
}

private struct AppNotificationPermissionGuidance: View {
  let status: AppNotificationAuthorizationStatus

  var body: some View {
    Text(status.guidance)
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

private struct AppNotificationPermissionActions: View {
  let model: AppNotificationSettingsModel

  var body: some View {
    HStack {
      if model.settings.authorization.canRequestAuthorization {
        Button("Enable Notifications") {
          Task {
            await model.requestAuthorization()
          }
        }
        .disabled(model.isWorking)
      }

      Button {
        Task {
          await model.refresh()
        }
      } label: {
        Label("Refresh Status", systemImage: "arrow.clockwise")
      }
      .disabled(model.isWorking)
    }
  }
}

extension AppNotificationAuthorizationStatus {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .unknown:
      "Checking"
    case .notDetermined:
      "Not requested"
    case .denied:
      "Off"
    case .authorized:
      "Allowed"
    case .provisional:
      "Quietly allowed"
    case .unavailable:
      "Unavailable"
    }
  }

  fileprivate var guidance: LocalizedStringResource {
    switch self {
    case .unknown:
      "Checking the notification permission managed by macOS."
    case .notDetermined:
      "Enable notifications to hear when image builds and macOS virtual machine setup finish."
    case .denied:
      "Notifications are off. Allow them in System Settings > Notifications > NativeContainers, then refresh this status."
    case .authorized:
      "NativeContainers can notify you when image builds and macOS virtual machine setup finish."
    case .provisional:
      "macOS is delivering NativeContainers notifications quietly."
    case .unavailable:
      "Notifications are unavailable in this app environment."
    }
  }
}

extension AppNotificationChannelStatus {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .unknown:
      "Checking"
    case .notSupported:
      "Not supported"
    case .disabled:
      "Off"
    case .enabled:
      "On"
    }
  }
}

#Preview("Notifications Allowed") {
  Form {
    AppNotificationSettingsSection(
      model: AppNotificationSettingsModel(
        service: PreviewAppNotificationService(
          settings: AppNotificationSettingsSnapshot(
            authorization: .authorized,
            alerts: .enabled,
            sounds: .enabled
          )
        )
      )
    )
  }
  .formStyle(.grouped)
  .frame(width: 520)
}

#Preview("Notifications Denied") {
  Form {
    AppNotificationSettingsSection(
      model: AppNotificationSettingsModel(
        service: PreviewAppNotificationService(
          settings: AppNotificationSettingsSnapshot(
            authorization: .denied,
            alerts: .disabled,
            sounds: .disabled
          )
        )
      )
    )
  }
  .formStyle(.grouped)
  .frame(width: 520)
}

@MainActor
private final class PreviewAppNotificationService: AppNotificationManaging {
  private let currentSettings: AppNotificationSettingsSnapshot

  init(settings: AppNotificationSettingsSnapshot) {
    currentSettings = settings
  }

  func settings() async -> AppNotificationSettingsSnapshot {
    currentSettings
  }

  func requestAuthorization() async throws -> AppNotificationSettingsSnapshot {
    currentSettings
  }

  func deliver(_ event: AppNotificationEvent) async {}

  func setResponseHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  ) {}
}
