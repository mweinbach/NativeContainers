import SwiftUI

struct LinuxMachineCommandView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: LinuxMachineCommandModel
  @State private var command = "printf 'hello from %s\\n' \"$(hostname)\" && uname -a"
  @State private var environmentText = ""
  @State private var workingDirectory = ""
  @State private var timeoutSeconds = 30
  @State private var selectedOutput = MachineCommandOutputKind.standardOutput
  @State private var validationMessage: String?
  @State private var commandTask: Task<Void, Never>?
  @State private var startsMachine: Bool

  init(machine: LinuxMachineRecord, appModel: AppModel) {
    _startsMachine = State(initialValue: machine.state == .stopped)
    _model = State(initialValue: appModel.makeLinuxMachineCommandModel(for: machine))
  }

  var body: some View {
    NavigationStack {
      Form {
        if startsMachine {
          Section {
            Label(
              "This machine is stopped. Running the command starts and provisions it first, then leaves the persistent machine running.",
              systemImage: "power"
            )
            .foregroundStyle(.secondary)
          }
        }

        Section("Shell Command") {
          TextEditor(text: $command)
            .font(.body.monospaced())
            .frame(minHeight: 110)
            .accessibilityLabel("Shell command")
          Text(
            "Runs through the Linux machine’s configured user shell as its host-mapped user."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          TextField(
            "Working directory",
            text: $workingDirectory,
            prompt: Text("Use machine home")
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
          Text(
            "Only the values entered here are added; host environment variables are not inherited."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if let result = model.commandResult {
          resultSection(result)
        }

        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Run Command — \(model.machineID)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isRunningCommand ? "KILL Command" : "Close") {
            if model.isRunningCommand {
              commandTask?.cancel()
            } else {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(startsMachine ? "Start & Run" : "Run", systemImage: "play.fill") {
            runCommand()
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isRunningCommand || command.isEmpty)
        }
      }
    }
    .frame(minWidth: 680, minHeight: 650)
    .interactiveDismissDisabled(model.isRunningCommand)
    .onDisappear {
      commandTask?.cancel()
    }
  }

  @ViewBuilder
  private func resultSection(_ result: ContainerCommandResult) -> some View {
    Section {
      HStack {
        Label(
          "Exit \(result.exitCode)",
          systemImage: result.exitCode == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
        )
        .foregroundStyle(result.exitCode == 0 ? .green : .orange)
        Spacer()
        Text(formattedDuration(result.duration))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Picker("Output", selection: $selectedOutput) {
        ForEach(MachineCommandOutputKind.allCases) { output in
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

  private func runCommand() {
    do {
      let request = try LinuxMachineCommandRequest(
        command: command,
        environment: try parseEnvironment(environmentText),
        workingDirectory: workingDirectory,
        timeoutSeconds: timeoutSeconds
      )
      validationMessage = nil
      commandTask = Task {
        await model.execute(request)
        if model.commandResult != nil {
          startsMachine = false
        }
        commandTask = nil
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }

  private func outputText(_ result: ContainerCommandResult) -> String {
    switch selectedOutput {
    case .standardOutput:
      result.standardOutput
    case .standardError:
      result.standardError
    }
  }

  private func formattedDuration(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return seconds.formatted(.number.precision(.fractionLength(2))) + " s"
  }
}

private enum MachineCommandOutputKind: String, CaseIterable, Identifiable {
  case standardOutput
  case standardError

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .standardOutput:
      "Standard Output"
    case .standardError:
      "Standard Error"
    }
  }
}

#Preview("Linux machine command") {
  LinuxMachineCommandView(
    machine: AppModel.preview.linuxMachines[0],
    appModel: .preview
  )
}
