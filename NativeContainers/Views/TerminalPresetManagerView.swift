import SwiftUI

struct TerminalPresetManagerView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var selectedPresetID: UUID?
  @State private var name = ""
  @State private var usesPreferredShell = true
  @State private var executable = ""
  @State private var launchesAsLoginShell = true
  @State private var workingDirectory = ""
  @State private var validationMessage: String?

  let model: TerminalWorkspaceModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Saved Preset") {
          Picker("Preset", selection: $selectedPresetID) {
            Text("New Preset").tag(nil as UUID?)
            ForEach(model.presets) { preset in
              Text(preset.name).tag(Optional(preset.id))
            }
          }
          .onChange(of: selectedPresetID) {
            loadSelection()
          }

          TextField("Name", text: $name)
            .frame(maxWidth: 360)
          Toggle("Use the detected preferred shell", isOn: $usesPreferredShell)
          if !usesPreferredShell {
            TextField("Executable", text: $executable, prompt: Text("/bin/zsh"))
              .font(.body.monospaced())
              .frame(maxWidth: 360)
          }
          Toggle("Launch as a login shell", isOn: $launchesAsLoginShell)
          TextField(
            "Working directory",
            text: $workingDirectory,
            prompt: Text("Use the container default")
          )
          .font(.body.monospaced())
          .frame(maxWidth: 360)
        }

        Section {
          Text(
            "Presets store only the shell choice, login-shell option, and container working directory. Environment variables, terminal output, and command history are never saved."
          )
          .foregroundStyle(.secondary)
          .frame(maxWidth: 360, alignment: .leading)
        }

        if let validationMessage {
          Section {
            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if let persistenceMessage = model.errorMessage {
          Section {
            LabeledContent {
              Button("Dismiss") {
                model.clearError()
              }
            } label: {
              Label(persistenceMessage, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .navigationTitle("Terminal Presets")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if let selectedPresetID {
            Button("Delete", role: .destructive) {
              Task {
                if await model.deletePreset(id: selectedPresetID) {
                  beginNewPreset()
                }
              }
            }
          }
          Button("Save") {
            save()
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 680, height: 500)
  }

  private func loadSelection() {
    validationMessage = nil
    guard
      let selectedPresetID,
      let preset = model.presets.first(where: { $0.id == selectedPresetID })
    else {
      beginNewPreset()
      return
    }

    name = preset.name
    launchesAsLoginShell = preset.launchesAsLoginShell
    workingDirectory = preset.workingDirectory ?? ""
    switch preset.program {
    case .preferredShell:
      usesPreferredShell = true
      executable = ""
    case .executable(let value):
      usesPreferredShell = false
      executable = value
    }
  }

  private func beginNewPreset() {
    selectedPresetID = nil
    name = ""
    usesPreferredShell = true
    executable = ""
    launchesAsLoginShell = true
    workingDirectory = ""
    validationMessage = nil
  }

  private func save() {
    do {
      let preset = try TerminalPreset(
        id: selectedPresetID ?? UUID(),
        name: name,
        program: usesPreferredShell ? .preferredShell : .executable(executable),
        launchesAsLoginShell: launchesAsLoginShell,
        workingDirectory: workingDirectory
      )
      validationMessage = nil
      Task {
        if await model.savePreset(preset) {
          selectedPresetID = preset.id
        }
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

#Preview("Terminal presets") {
  let appModel = AppModel.preview
  let request = TerminalWindowRequest(
    target: .container(
      ContainerTerminalTargetIdentity(container: appModel.containers[0])
    )
  )
  let model = appModel.makeTerminalWorkspaceModel(request: request)
  TerminalPresetManagerView(model: model)
    .task {
      await model.restore(from: nil)
    }
}
