import SwiftUI

struct SettingsView: View {
  let model: AppModel

  var body: some View {
    Form {
      AppBehaviorSettingsSection(
        launchAtLogin: model.makeLaunchAtLoginModel()
      )

      AppNotificationSettingsSection(
        model: model.makeAppNotificationSettingsModel()
      )

      Section("Apple container runtime") {
        LabeledContent("Status") {
          Text(model.systemInfo == nil ? "Unavailable" : "Running")
        }
        if let systemInfo = model.systemInfo {
          LabeledContent("Version", value: systemInfo.version)
          LabeledContent("Build", value: systemInfo.build)
          LabeledContent("Commit", value: systemInfo.commit)
          LabeledContent("Data") {
            Text(systemInfo.applicationRoot.path)
              .textSelection(.enabled)
          }
        }
      }

      NativeRuntimeDistributionSettingsSection(appModel: model)

      Section("Runtime policy") {
        LabeledContent("Container backend", value: "Verified Apple or NativeContainers runtime")
        LabeledContent("VM backend", value: "Virtualization.framework")
        LabeledContent("Networking", value: "Apple runtime / NAT")
      }

      PerformanceBenchmarkSettingsSection(
        model: model.makePerformanceBenchmarkModel()
      )

      FieldDiagnosticSettingsSection(
        model: model.makeFieldDiagnosticModel()
      )

      DockerCompatibilitySettingsSection(appModel: model)

      RegistrySettingsSection(appModel: model)
    }
    .formStyle(.grouped)
    .padding()
    .navigationTitle("Settings")
  }
}

#Preview("Settings") {
  SettingsView(model: .preview)
    .frame(width: 680, height: 1_100)
}
