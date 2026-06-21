import SwiftUI

struct LinuxMachinesView: View {
  private let appModel: AppModel

  @State private var managementModel: LinuxMachineManagementModel
  @State private var isPresentingCreation = false
  @State private var pendingDeletion: LinuxMachineRecord?
  @State private var pendingForceStop: LinuxMachineRecord?

  init(model: AppModel) {
    appModel = model
    _managementModel = State(initialValue: model.makeLinuxMachineManagementModel())
  }

  var body: some View {
    VStack(spacing: 0) {
      if let errorMessage = managementModel.errorMessage {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(errorMessage)
            .textSelection(.enabled)
          Spacer()
          Button("Dismiss", systemImage: "xmark") {
            managementModel.clearError()
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.08))
      }

      if appModel.linuxMachines.isEmpty {
        ContentUnavailableView(
          "No Linux machines",
          systemImage: "terminal",
          description: Text(
            "Create a persistent development machine with Apple’s container runtime."
          )
        )
      } else {
        List(appModel.linuxMachines) { machine in
          LinuxMachineRow(
            machine: machine,
            onStart: {
              Task { await managementModel.start(machine) }
            },
            onStop: {
              Task { await managementModel.stop(machine) }
            },
            onForceStop: {
              pendingForceStop = machine
            },
            onDelete: {
              pendingDeletion = machine
            }
          )
        }
        .disabled(managementModel.isWorking)
      }
    }
    .navigationTitle("Linux Machines")
    .toolbar {
      ToolbarItemGroup {
        if managementModel.isWorking {
          ProgressView()
            .controlSize(.small)
        }
        Button("New Linux Machine", systemImage: "plus") {
          managementModel.beginCreationSession()
          isPresentingCreation = true
        }
        .disabled(managementModel.isWorking)
      }
    }
    .sheet(isPresented: $isPresentingCreation) {
      LinuxMachineCreationView(model: managementModel)
    }
    .confirmationDialog(
      "Force-stop Linux machine?",
      isPresented: Binding(
        get: { pendingForceStop != nil },
        set: { if !$0 { pendingForceStop = nil } }
      ),
      presenting: pendingForceStop
    ) { machine in
      Button("KILL \(machine.id)", role: .destructive) {
        pendingForceStop = nil
        Task { await managementModel.forceStop(machine) }
      }
      Button("Cancel", role: .cancel) {
        pendingForceStop = nil
      }
    } message: { machine in
      Text(
        "This sends KILL to the verified backing container for \(machine.id). Use it when a graceful stop does not complete."
      )
    }
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
        Task { await managementModel.delete(machine) }
      }
      .disabled(machine.state != .stopped || machine.createdAt == nil)
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
    } message: { machine in
      Text(
        "The stopped machine \(machine.id), its persistent filesystem, and its configuration will be removed after its identity is revalidated."
      )
    }
  }
}

#Preview {
  NavigationStack {
    LinuxMachinesView(model: .preview)
  }
  .frame(width: 900, height: 620)
}

struct LinuxMachineRow: View {
  let machine: LinuxMachineRecord
  let onStart: () -> Void
  let onStop: () -> Void
  let onForceStop: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      RuntimeStatusIndicator(state: machine.state)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(machine.id)
            .font(.headline)
          RuntimeStateBadge(state: machine.state)
          if !machine.isInitialized {
            Text("Setup required")
              .font(.caption2.weight(.medium))
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.15), in: Capsule())
              .foregroundStyle(.orange)
          }
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
        isRunning: machine.state == .running || machine.state == .stopping,
        onStart: onStart,
        onStop: onStop,
        onForceStop: onForceStop,
        canDelete: machine.state == .stopped && machine.createdAt != nil,
        onDelete: onDelete
      )
    }
    .padding(.vertical, 7)
  }
}
