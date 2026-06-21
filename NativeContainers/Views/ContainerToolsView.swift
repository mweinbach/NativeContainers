import SwiftUI
import UniformTypeIdentifiers

struct ContainerExecView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerToolsModel
  @State private var executable = ""
  @State private var argumentsText = "-c\necho hello from the container"
  @State private var environmentText = ""
  @State private var workingDirectory = ""
  @State private var timeoutSeconds = 30
  @State private var selectedOutput = CommandOutputKind.standardOutput
  @State private var validationMessage: String?
  @State private var commandTask: Task<Void, Never>?

  init(containerID: String, appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerToolsModel(containerID: containerID))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Command") {
          TextField(
            "Executable",
            text: $executable,
            prompt: Text("Enter executable")
          )
          .font(.body.monospaced())
          ContainerShellDetectionStatus(
            isDetecting: model.isDetectingShell,
            message: model.shellDetectionMessage
          )
          LabeledContent("Arguments") {
            TextEditor(text: $argumentsText)
              .font(.body.monospaced())
              .frame(minHeight: 82)
          }
          TextField(
            "Working directory",
            text: $workingDirectory,
            prompt: Text("Use container default")
          )
          Stepper(value: $timeoutSeconds, in: 1...3_600, step: 5) {
            LabeledContent("Timeout", value: "\(timeoutSeconds) seconds")
          }
        }

        Section("Environment") {
          TextEditor(text: $environmentText)
            .font(.body.monospaced())
            .frame(minHeight: 64)
            .overlay(alignment: .topLeading) {
              if environmentText.isEmpty {
                Text("Optional KEY=value entries, one per line")
                  .foregroundStyle(.tertiary)
                  .allowsHitTesting(false)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 7)
              }
            }
        }

        if let result = model.commandResult {
          Section {
            HStack {
              Label("Exit \(result.exitCode)", systemImage: exitImage(result.exitCode))
                .foregroundStyle(result.exitCode == 0 ? .green : .orange)
              Spacer()
              Text(formattedDuration(result.duration))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Picker("Output", selection: $selectedOutput) {
              ForEach(CommandOutputKind.allCases) { output in
                Text(output.title).tag(output)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView([.horizontal, .vertical]) {
              Text(outputText(result).isEmpty ? "No output." : outputText(result))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(minHeight: 180, maxHeight: 340)
            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)

            if result.outputWasTruncated {
              Text("Showing the newest 1 MiB from each output stream.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } header: {
            Text("Result")
          }
        }

        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Exec in \(model.containerID)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isRunningCommand ? "Stop" : "Close") {
            if model.isRunningCommand {
              commandTask?.cancel()
            } else {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Run", systemImage: "play.fill") {
            runCommand()
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isRunningCommand || executable.isEmpty)
        }
      }
    }
    .frame(minWidth: 650, minHeight: 630)
    .interactiveDismissDisabled(model.isRunningCommand)
    .task {
      guard executable.isEmpty else { return }
      if let shell = await model.detectShell(), executable.isEmpty {
        executable = shell.executable
      }
    }
  }

  private func runCommand() {
    do {
      let request = try ContainerCommandRequest(
        executable: executable,
        arguments: argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty },
        environment: try parseEnvironment(environmentText),
        workingDirectory: workingDirectory,
        timeoutSeconds: timeoutSeconds
      )
      validationMessage = nil
      commandTask = Task {
        await model.execute(request)
        commandTask = nil
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }

  private func outputText(_ result: ContainerCommandResult) -> String {
    switch selectedOutput {
    case .standardOutput: result.standardOutput
    case .standardError: result.standardError
    }
  }

  private func exitImage(_ exitCode: Int32) -> String {
    exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
  }

  private func formattedDuration(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return seconds.formatted(.number.precision(.fractionLength(2))) + " s"
  }
}

private struct ContainerShellDetectionStatus: View {
  let isDetecting: Bool
  let message: String?

  var body: some View {
    if isDetecting {
      ProgressView("Detecting the container shell…")
        .controlSize(.small)
    } else if let message {
      Label(message, systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct ContainerFileTransferView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerToolsModel
  @State private var direction = ContainerFileTransferDirection.intoContainer
  @State private var localURL: URL?
  @State private var containerPath = "/tmp/"
  @State private var isChoosingSource = false
  @State private var isChoosingDestination = false
  @State private var validationMessage: String?

  init(containerID: String, appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerToolsModel(containerID: containerID))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Direction") {
          Picker("Direction", selection: $direction) {
            Text("Into container").tag(ContainerFileTransferDirection.intoContainer)
            Text("From container").tag(ContainerFileTransferDirection.fromContainer)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }

        Section(direction == .intoContainer ? "Local source" : "Container source") {
          if direction == .intoContainer {
            LocalSelectionRow(url: localURL, emptyLabel: "Choose a file or folder") {
              isChoosingSource = true
            }
          } else {
            TextField("Container path", text: $containerPath)
              .font(.body.monospaced())
          }
        }

        Section(direction == .intoContainer ? "Container destination" : "Local destination") {
          if direction == .intoContainer {
            TextField("Container path", text: $containerPath)
              .font(.body.monospaced())
          } else {
            LocalSelectionRow(url: localURL, emptyLabel: "Choose a destination folder") {
              isChoosingDestination = true
            }
          }
        }

        if model.isTransferring {
          Section {
            ProgressView("Copying…")
          }
        }
        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Copy Files")
      .onChange(of: direction) {
        localURL = nil
        containerPath = "/tmp/"
        validationMessage = nil
        model.clearMessages()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(model.isTransferring)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Copy") { copy() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isTransferring || localURL == nil || containerPath.isEmpty)
        }
      }
    }
    .frame(minWidth: 560, minHeight: 390)
    .interactiveDismissDisabled(model.isTransferring)
    .fileImporter(
      isPresented: $isChoosingSource,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        localURL = urls.first
      }
    }
    .fileImporter(
      isPresented: $isChoosingDestination,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        localURL = urls.first
      }
    }
  }

  private func copy() {
    guard let localURL else { return }
    do {
      let request = try ContainerFileTransferRequest(
        direction: direction,
        localURL: localURL,
        containerPath: containerPath
      )
      validationMessage = nil
      Task {
        let hasAccess = localURL.startAccessingSecurityScopedResource()
        defer {
          if hasAccess { localURL.stopAccessingSecurityScopedResource() }
        }
        if await model.transfer(request) {
          dismiss()
        }
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

private struct LocalSelectionRow: View {
  let url: URL?
  let emptyLabel: LocalizedStringResource
  let choose: () -> Void

  var body: some View {
    HStack {
      Text(url?.path(percentEncoded: false) ?? String(localized: emptyLabel))
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(url == nil ? .secondary : .primary)
      Spacer()
      Button("Choose…", action: choose)
    }
  }
}

private enum CommandOutputKind: String, CaseIterable, Identifiable {
  case standardOutput
  case standardError

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .standardOutput: "Standard Output"
    case .standardError: "Standard Error"
    }
  }
}

func parseEnvironment(_ text: String) throws -> [ContainerEnvironmentVariable] {
  var result: [ContainerEnvironmentVariable] = []
  for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
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

#Preview("Exec") {
  ContainerExecView(containerID: "api", appModel: .preview)
}

#Preview("Copy files") {
  ContainerFileTransferView(containerID: "api", appModel: .preview)
}
