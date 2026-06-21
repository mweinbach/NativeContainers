import SwiftUI

struct SettingsView: View {
  let model: AppModel

  var body: some View {
    Form {
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

      Section("Runtime policy") {
        LabeledContent("Container backend", value: "Apple container 1.0.0")
        LabeledContent("VM backend", value: "Virtualization.framework")
        LabeledContent("Networking", value: "Apple runtime / NAT")
      }

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
