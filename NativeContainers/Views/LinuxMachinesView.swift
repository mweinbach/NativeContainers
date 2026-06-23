import SwiftUI

struct LinuxMachinesView: View {
  @Environment(\.openWindow) private var openWindow

  private let appModel: AppModel

  @State private var managementModel: LinuxMachineManagementModel
  @State private var snapshotModel: LinuxMachineSnapshotModel
  @State private var isPresentingCreation = false
  @State private var pendingDeletion: LinuxMachineRecord?
  @State private var pendingForceStop: LinuxMachineRecord?
  @State private var presentedConfiguration: LinuxMachineRecord?
  @State private var presentedCommand: LinuxMachineRecord?
  @State private var presentedSnapshots: LinuxMachineRecord?

  init(model: AppModel) {
    appModel = model
    _managementModel = State(initialValue: model.makeLinuxMachineManagementModel())
    _snapshotModel = State(initialValue: model.makeLinuxMachineSnapshotModel())
  }

  var body: some View {
    VStack(spacing: 0) {
      LinuxMachineManagementFeedback(
        errorMessage: managementModel.errorMessage,
        configurationUpdate: managementModel.configurationUpdate,
        onDismissError: managementModel.clearError,
        onDismissConfiguration: managementModel.clearConfigurationUpdate
      )

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
            isSelected: selectedMachineID == machine.id,
            onSelect: {
              appModel.navigate(to: .linuxMachine(machine.id))
            },
            onStart: {
              Task { await managementModel.start(machine) }
            },
            onStop: {
              Task { await managementModel.stop(machine) }
            },
            onForceStop: {
              pendingForceStop = machine
            },
            onConfigure: {
              managementModel.beginConfigurationSession()
              presentedConfiguration = machine
            },
            onSnapshots: {
              presentedSnapshots = machine
            },
            onRunCommand: {
              presentedCommand = machine
            },
            onOpenTerminal: {
              openWindow(
                value: TerminalWindowRequest(
                  target: .linuxMachine(LinuxMachineIdentity(machine: machine))
                )
              )
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
    .onChange(of: appModel.linuxMachines, initial: true) {
      synchronizeSelection()
    }
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
      let defaults = appModel.currentWorkloadCreationDefaults()
      LinuxMachineCreationView(
        model: managementModel,
        resourceDefaults: defaults.linuxMachine,
        resourceConstraint: defaults.constraint
      )
    }
    .sheet(item: $presentedConfiguration) { machine in
      LinuxMachineConfigurationEditor(machine: machine, model: managementModel)
    }
    .sheet(item: $presentedCommand) { machine in
      LinuxMachineCommandView(machine: machine, appModel: appModel)
    }
    .sheet(item: $presentedSnapshots) { machine in
      LinuxMachineSnapshotsView(machine: machine, model: snapshotModel)
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

  private var selectedMachineID: LinuxMachineRecord.ID? {
    guard case .linuxMachine(let id) = appModel.workspaceRoute else { return nil }
    return id
  }

  private func synchronizeSelection() {
    guard
      let id = appModel.linuxMachines.first?.id,
      !appModel.linuxMachines.contains(where: { $0.id == selectedMachineID })
    else { return }
    appModel.navigate(to: .linuxMachine(id))
  }
}

private struct LinuxMachineManagementFeedback: View {
  let errorMessage: String?
  let configurationUpdate: LinuxMachineConfigurationUpdateResult?
  let onDismissError: () -> Void
  let onDismissConfiguration: () -> Void

  var body: some View {
    if let errorMessage {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(errorMessage)
          .textSelection(.enabled)
        Spacer()
        dismissButton(action: onDismissError)
      }
      .padding(12)
      .background(.orange.opacity(0.08))
    }

    if let configurationUpdate {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if configurationUpdate.requiresRestart {
          Text(
            "Configuration for \(configurationUpdate.target.id) is saved. Restart the machine to apply it."
          )
        } else {
          Text(
            "Configuration for \(configurationUpdate.target.id) is saved and will apply on its next start."
          )
        }
        Spacer()
        dismissButton(action: onDismissConfiguration)
      }
      .padding(12)
      .background(.green.opacity(0.08))
    }
  }

  private func dismissButton(action: @escaping () -> Void) -> some View {
    Button("Dismiss", systemImage: "xmark", action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
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
  let isSelected: Bool
  let onSelect: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onForceStop: () -> Void
  let onConfigure: () -> Void
  let onSnapshots: () -> Void
  let onRunCommand: () -> Void
  let onOpenTerminal: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button(action: onSelect) {
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
        }
      }
      .buttonStyle(.plain)
      .accessibilityValue(isSelected ? "Selected" : "Not selected")

      Menu("Machine Tools", systemImage: "ellipsis.circle") {
        Button("Configure", systemImage: "gearshape") {
          onConfigure()
        }
        Button("Snapshots", systemImage: "camera.on.rectangle") {
          onSnapshots()
        }
        .disabled(machine.state != .stopped || machine.createdAt == nil)
        Divider()
        Button(
          machine.state == .stopped ? "Start & Open Terminal" : "Open Terminal",
          systemImage: "terminal"
        ) {
          onOpenTerminal()
        }
        Button(
          machine.state == .stopped ? "Start & Run Command" : "Run Command",
          systemImage: "chevron.left.forwardslash.chevron.right"
        ) {
          onRunCommand()
        }
      }
      .labelStyle(.iconOnly)
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(!canUseTools)
      .help(toolHelp)

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
    .padding(.horizontal, 8)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
  }

  private var canUseTools: Bool {
    machine.createdAt != nil && (machine.state == .running || machine.state == .stopped)
  }

  private var toolHelp: String {
    guard machine.createdAt != nil else {
      return "Refresh this legacy machine before running commands."
    }
    switch machine.state {
    case .running:
      return "Configure the machine, open a shell, or run a one-shot command."
    case .stopped:
      return "Configure the machine, or start it to open a shell or run a command."
    case .stopping, .unknown:
      return "Wait for a stable running or stopped state."
    }
  }
}

private struct LinuxMachineSnapshotsView: View {
  @Environment(\.dismiss) private var dismiss

  let machine: LinuxMachineRecord
  @State var model: LinuxMachineSnapshotModel

  @State private var newSnapshotName = ""
  @State private var cloneMachineName = ""
  @State private var snapshotToRestore: LinuxMachineSnapshotRecord?
  @State private var snapshotToClone: LinuxMachineSnapshotRecord?
  @State private var snapshotToDelete: LinuxMachineSnapshotRecord?

  var body: some View {
    NavigationStack {
      Form {
        statusSection
        if let catalog = model.catalog {
          createSection(catalog)
          snapshotsSection(catalog)
          exclusionsSection
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Snapshots for \(machine.id)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        if model.isWorking {
          ToolbarItem(placement: .primaryAction) {
            ProgressView().controlSize(.small)
          }
        }
      }
    }
    .frame(minWidth: 680, minHeight: 520)
    .task { await model.load(for: machine) }
    .confirmationDialog(
      "Restore this machine snapshot?",
      isPresented: Binding(
        get: { snapshotToRestore != nil },
        set: { if !$0 { snapshotToRestore = nil } }
      ),
      presenting: snapshotToRestore
    ) { snapshot in
      Button("Restore \(snapshot.name)", role: .destructive) {
        snapshotToRestore = nil
        Task { _ = await model.restore(snapshot) }
      }
      Button("Cancel", role: .cancel) { snapshotToRestore = nil }
    } message: { snapshot in
      Text(
        "The stopped machine’s current bundle will be replaced through the runtime’s recoverable swap. The snapshot remains independently restorable."
      )
    }
    .confirmationDialog(
      "Delete this machine snapshot?",
      isPresented: Binding(
        get: { snapshotToDelete != nil },
        set: { if !$0 { snapshotToDelete = nil } }
      ),
      presenting: snapshotToDelete
    ) { snapshot in
      Button("Delete \(snapshot.name)", role: .destructive) {
        snapshotToDelete = nil
        Task { _ = await model.delete(snapshot) }
      }
      Button("Cancel", role: .cancel) { snapshotToDelete = nil }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    if let errorMessage = model.errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
        Button("Retry") { Task { await model.load(for: machine) } }
      }
    } else if model.catalog == nil {
      Section {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading the stopped-machine snapshot catalog…")
        }
      }
    }
  }

  private func createSection(_ catalog: LinuxMachineSnapshotCatalog) -> some View {
    Section("Create snapshot") {
      TextField("Snapshot name", text: $newSnapshotName)
        .textFieldStyle(.roundedBorder)
      Button("Create Snapshot", systemImage: "camera.on.rectangle") {
        let name = newSnapshotName
        Task {
          if await model.create(named: name) {
            newSnapshotName = ""
          }
        }
      }
      .disabled(
        model.isWorking || !catalog.canCreate
          || newSnapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      Text("Snapshots require a stopped machine and are limited to eight per machine.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func snapshotsSection(_ catalog: LinuxMachineSnapshotCatalog) -> some View {
    Section("Snapshots") {
      if catalog.snapshots.isEmpty {
        ContentUnavailableView(
          "No Snapshots",
          systemImage: "camera.on.rectangle",
          description: Text("Create a stopped-machine snapshot to retain this filesystem state.")
        )
      }
      ForEach(catalog.snapshots) { snapshot in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
              Text(snapshot.name).font(.headline)
              Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(byteCount(snapshot.allocatedSize))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          HStack {
            Button("Restore", systemImage: "arrow.counterclockwise") {
              snapshotToRestore = snapshot
            }
            Button("Clone", systemImage: "plus.square.on.square") {
              snapshotToClone = snapshot
              cloneMachineName = "\(machine.id)-copy"
            }
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) {
              snapshotToDelete = snapshot
            }
          }
          .disabled(model.isWorking)
          if snapshotToClone?.id == snapshot.id {
            HStack {
              TextField("New machine name", text: $cloneMachineName)
                .textFieldStyle(.roundedBorder)
              Button("Create Clone") {
                let name = cloneMachineName
                Task {
                  if await model.clone(snapshot, as: name) {
                    snapshotToClone = nil
                    cloneMachineName = ""
                  }
                }
              }
              .buttonStyle(.borderedProminent)
              Button("Cancel") {
                snapshotToClone = nil
                cloneMachineName = ""
              }
            }
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var exclusionsSection: some View {
    Section("Captured data") {
      Text(
        "Each snapshot captures the EXT4 root filesystem, machine and boot configuration, and initialization state."
      )
      Text(
        "External home-directory contents, logs, runtime memory, and attached external resources are not captured. Snapshot clones receive a new machine identity, start stopped, are not made default, and have external home mounts disconnected."
      )
      .foregroundStyle(.secondary)
    }
  }

  private func byteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(clamping: value),
      countStyle: .file
    )
  }
}
