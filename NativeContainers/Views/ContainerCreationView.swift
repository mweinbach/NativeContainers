import SwiftUI

struct ContainerCreationView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerProvisioningModel
  @State private var draft = ContainerCreationDraft()
  @State private var validationMessage: String?

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerProvisioningModel())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Container") {
          TextField("Name", text: $draft.name, prompt: Text("my-container"))
          TextField("Image", text: $draft.imageReference, prompt: Text("alpine:latest"))
          Picker("Architecture", selection: $draft.architecture) {
            Text("Apple silicon (arm64)").tag(ContainerArchitecture.arm64)
            Text("Intel with Rosetta (amd64)").tag(ContainerArchitecture.amd64)
          }
        }

        Section("Resources") {
          Stepper(value: $draft.cpuCount, in: 1...maximumSuggestedCPUCount) {
            LabeledContent("CPUs", value: draft.cpuCount.formatted())
          }
          Picker("Memory", selection: $draft.memoryMiB) {
            ForEach(ContainerCreationDraft.memoryOptions, id: \.self) { memoryMiB in
              Text(memoryLabel(memoryMiB)).tag(memoryMiB)
            }
          }
        }

        Section("Process") {
          TextField(
            "Working directory",
            text: $draft.workingDirectory,
            prompt: Text("Use image default")
          )
          LabeledContent("Arguments") {
            TextEditor(text: $draft.argumentsText)
              .font(.body.monospaced())
              .frame(minHeight: 64)
              .overlay(alignment: .topLeading) {
                if draft.argumentsText.isEmpty {
                  Text("One argument per line; leave empty for image defaults")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                }
              }
          }
          LabeledContent("Environment") {
            TextEditor(text: $draft.environmentText)
              .font(.body.monospaced())
              .frame(minHeight: 76)
              .overlay(alignment: .topLeading) {
                if draft.environmentText.isEmpty {
                  Text("One KEY=value entry per line")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                }
              }
          }
        }

        Section("Published ports") {
          if draft.publishedPorts.isEmpty {
            Text("No host ports published")
              .foregroundStyle(.secondary)
          }
          ForEach($draft.publishedPorts) { $port in
            ContainerPortDraftRow(port: $port) {
              draft.publishedPorts.removeAll { $0.id == port.id }
            }
          }
          Button("Add Port", systemImage: "plus") {
            draft.publishedPorts.append(ContainerPortDraft())
          }
        }

        Section("Lifecycle") {
          Toggle("Start after creation", isOn: $draft.startAfterCreation)
          Toggle("Use a minimal init process", isOn: $draft.useInitProcess)
          Toggle("Forward SSH agent", isOn: $draft.forwardSSHAgent)
          Toggle("Read-only root filesystem", isOn: $draft.readOnlyRootFilesystem)
          Toggle("Remove automatically when stopped", isOn: $draft.removeWhenStopped)
        }

        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if model.isWorking || model.progress != nil {
          Section("Progress") {
            ContainerOperationStatusView(progress: model.progress)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("New Container")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(model.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            create()
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || draft.name.isEmpty || draft.imageReference.isEmpty)
        }
      }
    }
    .frame(minWidth: 650, minHeight: 720)
    .interactiveDismissDisabled(model.isWorking)
  }

  private var maximumSuggestedCPUCount: Int {
    max(1, min(ProcessInfo.processInfo.activeProcessorCount, 32))
  }

  private func create() {
    do {
      let request = try draft.makeRequest()
      validationMessage = nil
      Task {
        if await model.createContainer(request) {
          dismiss()
        }
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }

  private func memoryLabel(_ memoryMiB: Int) -> String {
    Int64(memoryMiB * Int(ContainerCreationRequest.bytesPerMiB)).formatted(
      .byteCount(style: .memory)
    )
  }
}

struct ContainerPortDraftRow: View {
  @Binding var port: ContainerPortDraft
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TextField("Host address", text: $port.hostAddress)
        .frame(minWidth: 125)
      TextField("Host", value: $port.hostPort, format: .number)
        .frame(width: 74)
      Image(systemName: "arrow.right")
        .foregroundStyle(.tertiary)
      TextField("Guest", value: $port.containerPort, format: .number)
        .frame(width: 74)
      Picker("Protocol", selection: $port.transportProtocol) {
        ForEach(ContainerTransportProtocol.allCases) { transport in
          Text(transport.rawValue.uppercased()).tag(transport)
        }
      }
      .labelsHidden()
      .frame(width: 76)
      Button("Remove Port", systemImage: "minus.circle", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
  }
}

struct ImagePullView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerProvisioningModel
  @State private var reference = ""

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerProvisioningModel())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("OCI image") {
          TextField("Reference", text: $reference, prompt: Text("alpine:latest"))
          Text("Unqualified references use the registry configured by Apple’s container runtime.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if model.isWorking || model.progress != nil {
          Section("Progress") {
            ContainerOperationStatusView(progress: model.progress)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("Pull Image")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(model.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Pull") {
            Task {
              if await model.pullImage(reference: reference) {
                dismiss()
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || reference.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .frame(minWidth: 500, minHeight: 310)
    .interactiveDismissDisabled(model.isWorking)
  }
}

struct ContainerOperationStatusView: View {
  let progress: ContainerOperationProgress?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let progress {
        Text(progress.message)
          .font(.headline)
        if let fraction = progress.fractionCompleted {
          ProgressView(value: fraction)
        } else if progress.phase == .completed {
          ProgressView(value: 1)
        } else {
          ProgressView()
        }
        if progress.totalBytes > 0 {
          Text(
            "\(Int64(progress.transferredBytes), format: .byteCount(style: .file)) of \(Int64(progress.totalBytes), format: .byteCount(style: .file))"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      } else {
        ProgressView("Preparing…")
      }
    }
  }
}

private struct ContainerCreationDraft {
  static let memoryOptions = [512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]

  var name = ""
  var imageReference = ""
  var architecture = ContainerArchitecture.arm64
  var cpuCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
  var memoryMiB = 1_024
  var argumentsText = ""
  var environmentText = ""
  var workingDirectory = ""
  var publishedPorts: [ContainerPortDraft] = []
  var startAfterCreation = true
  var removeWhenStopped = false
  var forwardSSHAgent = false
  var readOnlyRootFilesystem = false
  var useInitProcess = true

  func makeRequest() throws -> ContainerCreationRequest {
    try ContainerCreationRequest(
      name: name,
      imageReference: imageReference,
      architecture: architecture,
      cpuCount: cpuCount,
      memoryBytes: UInt64(memoryMiB) * ContainerCreationRequest.bytesPerMiB,
      arguments: argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty },
      environment: try environmentVariables(),
      workingDirectory: workingDirectory,
      publishedPorts: try publishedPorts.map { try $0.publication() },
      startAfterCreation: startAfterCreation,
      removeWhenStopped: removeWhenStopped,
      forwardSSHAgent: forwardSSHAgent,
      readOnlyRootFilesystem: readOnlyRootFilesystem,
      useInitProcess: useInitProcess
    )
  }

  private func environmentVariables() throws -> [ContainerEnvironmentVariable] {
    var result: [ContainerEnvironmentVariable] = []
    for (offset, rawLine) in environmentText.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let separator = line.firstIndex(of: "=") else {
        throw ContainerCreationValidationError.malformedEnvironmentLine(offset + 1)
      }
      result.append(
        try ContainerEnvironmentVariable(
          key: String(line[..<separator]),
          value: String(line[line.index(after: separator)...])
        )
      )
    }
    return result
  }
}

struct ContainerPortDraft: Identifiable {
  let id = UUID()
  var hostAddress = "127.0.0.1"
  var hostPort = 8_080
  var containerPort = 8_080
  var transportProtocol = ContainerTransportProtocol.tcp

  func publication() throws -> ContainerPortPublication {
    guard let hostPort = UInt16(exactly: hostPort),
      let containerPort = UInt16(exactly: containerPort),
      hostPort > 0, containerPort > 0
    else {
      throw ContainerCreationValidationError.invalidPort
    }
    return try ContainerPortPublication(
      hostAddress: hostAddress,
      hostPort: hostPort,
      containerPort: containerPort,
      transportProtocol: transportProtocol
    )
  }
}

#Preview("New container") {
  ContainerCreationView(appModel: .preview)
}

#Preview("Pull image") {
  ImagePullView(appModel: .preview)
}
