import SwiftUI

struct MacVirtualMachineInstallationView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var model: MacVirtualMachineInstallationModel
  @State private var operationTask: Task<Void, Never>?

  init(machine: VirtualMachineManifest, appModel: AppModel) {
    _model = State(
      initialValue: appModel.makeMacVirtualMachineInstallationModel(for: machine)
    )
  }

  init(model: MacVirtualMachineInstallationModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      MacVirtualMachineInstallationHeader(machineName: model.machine.name)
      VirtualMachineResourceSummary(resources: model.machine.resources)
      Divider()
      MacVirtualMachineInstallationStatus(model: model)
      MacVirtualMachineInstallationSafetyNotice()

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()

        Button(operationTask == nil ? "Close" : "Cancel Installation") {
          if let operationTask {
            operationTask.cancel()
          } else {
            dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)

        Button("Install macOS") {
          startInstallation()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(operationTask != nil || model.didFinish)
      }
    }
    .padding(24)
    .frame(width: 620)
    .interactiveDismissDisabled(operationTask != nil)
    .onDisappear {
      operationTask?.cancel()
    }
  }

  private func startInstallation() {
    guard operationTask == nil else { return }
    model.clearError()
    operationTask = Task {
      let succeeded = await model.install()
      operationTask = nil
      if succeeded {
        dismiss()
      }
    }
  }
}

private struct MacVirtualMachineInstallationHeader: View {
  let machineName: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "square.and.arrow.down.on.square.fill")
        .font(.largeTitle)
        .foregroundStyle(.indigo)
      VStack(alignment: .leading, spacing: 3) {
        Text("Install macOS")
          .font(.title2.bold())
        Text("Install the prepared restore image on \(machineName)")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MacVirtualMachineInstallationStatus: View {
  let model: MacVirtualMachineInstallationModel

  var body: some View {
    if let phase = model.phase {
      VStack(alignment: .leading, spacing: 8) {
        if let fraction = model.fractionCompleted {
          ProgressView(value: fraction)
        } else {
          ProgressView()
        }
        HStack {
          phaseLabel(for: phase)
          Spacer()
          if let fraction = model.fractionCompleted {
            Text(fraction, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit()
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } else {
      Text(
        "The app validates the entire VM bundle before taking an installation lease. If preflight fails, the prepared disk remains untouched."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func phaseLabel(for phase: MacVirtualMachineInstallationPhase) -> some View {
    switch phase {
    case .preparing:
      Text("Validating VM configuration")
    case .installing:
      Text("Installing macOS")
    case .finalizing:
      Text("Finalizing installation state")
    }
  }
}

private struct MacVirtualMachineInstallationSafetyNotice: View {
  var body: some View {
    GroupBox {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "shield.lefthalf.filled")
          .foregroundStyle(.indigo)
        Text(
          "Cancel uses the installer’s supported progress cancellation. The app never pauses or force-stops a VM during installation because Apple defines that behavior as unsafe."
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview("macOS installation") {
  let resources = try! VirtualMachineResources(
    cpuCount: 6,
    memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 96 * VirtualMachineResources.bytesPerGiB
  )
  let machine = try! VirtualMachineManifest(
    name: "Development Mac",
    guest: .macOS,
    installState: .readyToInstall,
    resources: resources
  )
  let model = MacVirtualMachineInstallationModel(
    machine: machine,
    installer: PreviewMacVirtualMachineInstaller()
  ) {}
  MacVirtualMachineInstallationView(model: model)
}

@MainActor
private struct PreviewMacVirtualMachineInstaller: MacVirtualMachineInstalling {
  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {
    progress(
      MacVirtualMachineInstallationProgress(
        phase: .installing,
        fractionCompleted: 0.42
      )
    )
  }

  func recoverInterruptedInstallations() async throws {}
}
