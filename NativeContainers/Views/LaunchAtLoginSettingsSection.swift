import SwiftUI

struct AppBehaviorSettingsSection: View {
  let launchAtLogin: LaunchAtLoginModel

  @AppStorage(AppPreferenceKey.menuBarExtraInserted)
  private var isMenuBarExtraInserted = true

  var body: some View {
    @Bindable var launchAtLogin = launchAtLogin

    Section("App behavior") {
      Toggle("Show menu bar controls", isOn: $isMenuBarExtraInserted)

      Toggle("Launch at login", isOn: $launchAtLogin.isEnabled)
        .disabled(!launchAtLogin.status.canChange || launchAtLogin.isUpdating)

      LaunchAtLoginStatusMessage(status: launchAtLogin.status)

      if let errorMessage = launchAtLogin.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .task {
      launchAtLogin.refresh()
    }
  }
}

private struct LaunchAtLoginStatusMessage: View {
  let status: LaunchAtLoginStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch status {
      case .notRegistered:
        Text("NativeContainers won't open automatically when you sign in.")
      case .enabled:
        Text("NativeContainers will open automatically when you sign in.")
      case .requiresApproval:
        Text(
          "Approval is required in System Settings > General > Login Items before NativeContainers can open automatically."
        )
      case .unavailable:
        Text(
          "Install NativeContainers as an application to manage launch at login."
        )
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

#Preview("App Behavior Settings") {
  Form {
    AppBehaviorSettingsSection(
      launchAtLogin: LaunchAtLoginModel(
        service: UnavailableLaunchAtLoginService()
      )
    )
  }
  .formStyle(.grouped)
  .frame(width: 520)
}
