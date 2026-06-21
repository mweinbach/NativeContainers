import SwiftUI

struct LinuxMachineConfigurationEditor: View {
  @Environment(\.dismiss) private var dismiss

  let machine: LinuxMachineRecord
  let model: LinuxMachineManagementModel

  @State private var cpuCount: Int
  @State private var memoryMiB: Int
  @State private var homeMount: LinuxMachineHomeMount
  @State private var confirmsWritableHomeMount = false

  init(
    machine: LinuxMachineRecord,
    model: LinuxMachineManagementModel
  ) {
    self.machine = machine
    self.model = model
    _cpuCount = State(initialValue: machine.cpuCount)
    _memoryMiB = State(
      initialValue: Int(machine.memoryBytes / LinuxMachineConfiguration.bytesPerMiB)
    )
    _homeMount = State(initialValue: machine.homeMount)
  }

  var body: some View {
    NavigationStack {
      Form {
        LinuxMachineConfigurationIdentitySection(machine: machine)

        LinuxMachineComputeConfigurationSection(
          cpuCount: $cpuCount,
          memoryMiB: $memoryMiB
        )

        LinuxMachineHomeMountConfigurationSection(
          homeMount: $homeMount,
          confirmsWritableHomeMount: $confirmsWritableHomeMount
        )

        Section("When changes apply") {
          Label(applicationMessage, systemImage: applicationSymbol)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Configure \(machine.id)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save()
          }
          .disabled(!canSave)
        }
      }
    }
    .frame(minWidth: 500, idealWidth: 540, minHeight: 480, idealHeight: 540)
    .interactiveDismissDisabled(model.isWorking)
    .onChange(of: homeMount) {
      if homeMount != .readWrite {
        confirmsWritableHomeMount = false
      }
    }
  }

  private var canSave: Bool {
    !model.isWorking
      && (homeMount != .readWrite || confirmsWritableHomeMount)
  }

  private var applicationMessage: LocalizedStringResource {
    if machine.state == .stopped {
      "The updated configuration will be used the next time this machine starts."
    } else {
      "The updated configuration is saved immediately and takes effect after this machine restarts."
    }
  }

  private var applicationSymbol: String {
    machine.state == .stopped ? "play.circle" : "arrow.clockwise.circle"
  }

  private func save() {
    do {
      let request = try LinuxMachineConfigurationUpdateRequest(
        cpuCount: cpuCount,
        memoryBytes: UInt64(memoryMiB) * LinuxMachineConfiguration.bytesPerMiB,
        homeMount: homeMount,
        allowsWritableHomeMount: confirmsWritableHomeMount
      )
      Task {
        if await model.updateConfiguration(for: machine, request: request) {
          dismiss()
        }
      }
    } catch {
      model.report(error)
    }
  }
}

private struct LinuxMachineConfigurationIdentitySection: View {
  let machine: LinuxMachineRecord

  var body: some View {
    Section("Machine") {
      LabeledContent("Image", value: machine.imageReference)
      LabeledContent("Platform", value: machine.platform)
      LabeledContent("State") {
        RuntimeStateBadge(state: machine.state)
      }
    }
  }
}

private struct LinuxMachineComputeConfigurationSection: View {
  @Binding var cpuCount: Int
  @Binding var memoryMiB: Int

  var body: some View {
    Section {
      Stepper(
        value: $cpuCount,
        in: 1...LinuxMachineConfiguration.maximumCPUCount
      ) {
        LabeledContent("Virtual CPUs", value: "\(cpuCount)")
      }

      Stepper(
        value: $memoryMiB,
        in: minimumMemoryMiB...maximumMemoryMiB,
        step: 512
      ) {
        LabeledContent("Memory", value: memoryDescription)
      }
    } header: {
      Text("Compute")
    } footer: {
      Text("Memory is allocated in 512 MiB steps, with a 1 GiB minimum.")
    }
  }

  private var minimumMemoryMiB: Int {
    Int(
      LinuxMachineConfiguration.minimumMemoryBytes
        / LinuxMachineConfiguration.bytesPerMiB
    )
  }

  private let maximumMemoryMiB = 1_048_576

  private var memoryDescription: String {
    ByteCountFormatter.string(
      fromByteCount: Int64(memoryMiB) * Int64(LinuxMachineConfiguration.bytesPerMiB),
      countStyle: .memory
    )
  }
}

private struct LinuxMachineHomeMountConfigurationSection: View {
  @Binding var homeMount: LinuxMachineHomeMount
  @Binding var confirmsWritableHomeMount: Bool

  var body: some View {
    Section {
      Picker("Home directory", selection: $homeMount) {
        ForEach(LinuxMachineHomeMount.allCases) { option in
          Text(option.title)
            .tag(option)
        }
      }

      if homeMount == .readWrite {
        Toggle(
          "Allow this machine to modify files in my home directory",
          isOn: $confirmsWritableHomeMount
        )
        Label(
          "Processes in the machine can change or delete host files accessible through this mount.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      }
    } header: {
      Text("Host access")
    } footer: {
      Text(homeMountDescription)
    }
  }

  private var homeMountDescription: LocalizedStringResource {
    switch homeMount {
    case .none:
      "Your home directory is not shared with the machine."
    case .readOnly:
      "Your home directory is visible to the machine but cannot be changed from inside it."
    case .readWrite:
      "Your home directory is visible and writable from inside the machine."
    }
  }
}

#Preview {
  let appModel = AppModel.preview
  LinuxMachineConfigurationEditor(
    machine: appModel.linuxMachines[0],
    model: appModel.makeLinuxMachineManagementModel()
  )
}
