import SwiftUI

struct LinuxMachinesView: View {
  let model: AppModel
  @State private var pendingDeletion: LinuxMachineRecord?

  var body: some View {
    VStack(spacing: 0) {
      if model.linuxMachines.isEmpty {
        ContentUnavailableView(
          "No Linux machines",
          systemImage: "terminal",
          description: Text(
            "Persistent development machines created with Apple’s container runtime appear here.")
        )
      } else {
        List(model.linuxMachines) { machine in
          LinuxMachineRow(
            machine: machine,
            onStart: { Task { await model.startMachine(id: machine.id) } },
            onStop: { Task { await model.stopMachine(id: machine.id) } },
            onDelete: { pendingDeletion = machine }
          )
        }
      }
    }
    .navigationTitle("Linux Machines")
    .confirmationDialog(
      "Delete Linux machine?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { machine in
      Button("Delete \(machine.id)", role: .destructive) {
        pendingDeletion = nil
        Task { await model.deleteMachine(id: machine.id) }
      }
    } message: { machine in
      Text(
        "The machine \(machine.id), its persistent filesystem, and its configuration will be removed."
      )
    }
  }
}

struct LinuxMachineRow: View {
  let machine: LinuxMachineRecord
  let onStart: () -> Void
  let onStop: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      RuntimeStatusIndicator(state: machine.state)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(machine.id)
            .font(.headline)
          RuntimeStateBadge(state: machine.state)
        }
        Text(machine.imageReference)
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Label("\(machine.cpuCount) CPUs", systemImage: "cpu")
          Label(machine.memoryDescription, systemImage: "memorychip")
          if let ipAddress = machine.ipAddress {
            Label(ipAddress, systemImage: "network")
          }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
      Spacer()
      ResourceActionMenu(
        isRunning: machine.state.isRunning,
        onStart: onStart,
        onStop: onStop,
        onDelete: onDelete
      )
    }
    .padding(.vertical, 7)
  }
}
