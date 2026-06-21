import SwiftUI

struct LinuxMachineCreationView: View {
  @Environment(\.dismiss) private var dismiss

  let model: LinuxMachineManagementModel
  @State private var draft = LinuxMachineCreationDraft()
  @State private var validationMessage: String?
  @State private var operationTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Machine") {
          TextField("Name", text: $draft.name, prompt: Text("development"))
          TextField(
            "OCI image",
            text: $draft.imageReference,
            prompt: Text("alpine:3.22")
          )
          Picker("Architecture", selection: $draft.architecture) {
            ForEach(ContainerArchitecture.allCases) { architecture in
              Text(architecture.rawValue).tag(architecture)
            }
          }
          Text(
            "The image is fetched and unpacked through Apple’s container runtime before the persistent machine is created."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section("Resources") {
          Stepper(value: $draft.cpuCount, in: 1...maximumSuggestedCPUCount) {
            LabeledContent("Virtual CPUs", value: draft.cpuCount.formatted())
          }
          Stepper(value: $draft.memoryMiB, in: 1_024...65_536, step: 256) {
            LabeledContent(
              "Memory",
              value: Int64(draft.memoryMiB * 1_048_576).formatted(.byteCount(style: .memory))
            )
          }
        }

        Section("Host access") {
          Picker("Home directory", selection: $draft.homeMount) {
            ForEach(LinuxMachineHomeMount.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          if draft.homeMount == .readWrite {
            Toggle(
              "Allow this machine to modify my home directory",
              isOn: $draft.allowsWritableHomeMount
            )
            Text(
              "Read-and-write access lets software in the machine change files in your macOS home directory."
            )
            .font(.caption)
            .foregroundStyle(.orange)
          } else if draft.homeMount == .readOnly {
            Text("The machine can read files in your home directory but cannot modify them.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("No host home-directory mount is added.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("Lifecycle") {
          Toggle("Start and finish first-boot setup", isOn: $draft.startAfterCreation)
          Text(
            draft.startAfterCreation
              ? "Creation completes only after the machine is running and its host user is configured."
              : "The persistent machine is created in a stopped state."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if let partialCreation = model.partialCreation {
          Section("Created machine") {
            LabeledContent("Name", value: partialCreation.identity.id)
            LabeledContent("State", value: partialCreation.state.rawValue.capitalized)
            Text("The durable machine was kept so you can inspect or retry it.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if model.isWorking || model.progress != nil {
          Section("Progress") {
            ContainerOperationStatusView(progress: model.progress)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(isBusy)
      .navigationTitle("New Linux Machine")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if isBusy {
            Button("Cancel and Auto Stop") {
              operationTask?.cancel()
            }
            .help(
              "Cancel creation and automatically stop or KILL a machine that was already created"
            )
          } else {
            Button("Cancel") {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            create()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            isBusy
              || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || draft.imageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || (draft.homeMount == .readWrite && !draft.allowsWritableHomeMount)
          )
        }
      }
    }
    .frame(minWidth: 560, minHeight: 620)
    .interactiveDismissDisabled(isBusy)
    .onAppear {
      model.beginCreationSession()
    }
    .onChange(of: draft.homeMount) {
      if draft.homeMount != .readWrite {
        draft.allowsWritableHomeMount = false
      }
    }
    .onDisappear {
      operationTask?.cancel()
    }
  }

  private var isBusy: Bool {
    model.isWorking || operationTask != nil
  }

  private var maximumSuggestedCPUCount: Int {
    max(1, min(ProcessInfo.processInfo.activeProcessorCount, 32))
  }

  private func create() {
    guard operationTask == nil, !model.isWorking else { return }
    do {
      let request = try draft.makeRequest()
      validationMessage = nil
      operationTask = Task { @MainActor in
        defer { operationTask = nil }
        if await model.createMachine(request) {
          dismiss()
        }
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

#Preview {
  let appModel = AppModel.preview
  LinuxMachineCreationView(model: appModel.makeLinuxMachineManagementModel())
}
