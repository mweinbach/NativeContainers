import SwiftUI

struct VirtualMachinesView: View {
  let model: AppModel

  @State private var isCreating = false
  @State private var machineToPrepare: VirtualMachineManifest?
  @State private var machineToInstall: VirtualMachineManifest?
  @State private var machineToOpen: VirtualMachineManifest?
  @State private var machineToForceStop: VirtualMachineManifest?
  @State private var machineToDiscard: VirtualMachineManifest?

  var body: some View {
    VStack(spacing: 0) {
      if model.virtualMachines.isEmpty {
        ContentUnavailableView {
          Label("No macOS VMs", systemImage: "macwindow")
        } description: {
          Text("Create a native Virtualization.framework bundle to begin installing macOS.")
        } actions: {
          Button("Create VM") { isCreating = true }
            .buttonStyle(.borderedProminent)
        }
      } else {
        HSplitView {
          List(model.virtualMachines) { machine in
            VirtualMachineRow(
              machine: machine,
              availability: model.virtualMachineAvailability,
              runtime: model.makeMacVirtualMachineRuntimeModel(for: machine),
              isSelected: selectedMachineID == machine.id,
              onSelect: {
                model.navigate(to: .macOSVirtualMachine(machine.id))
              },
              prepare: { machineToPrepare = machine },
              install: { machineToInstall = machine },
              open: { machineToOpen = machine },
              forceStop: { machineToForceStop = machine },
              discard: { machineToDiscard = machine }
            )
          }
          .frame(minWidth: 360, idealWidth: 430, maxWidth: 560)

          if let selectedMachine {
            MacVirtualMachineConfigurationView(
              machine: selectedMachine,
              runtime: model.makeMacVirtualMachineRuntimeModel(for: selectedMachine),
              sharedDirectories: model.makeMacVirtualMachineSharedDirectoriesModel(
                for: selectedMachine
              )
            )
            .id(selectedMachine.id)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ContentUnavailableView(
              "Select a Virtual Machine",
              systemImage: "macwindow",
              description: Text("Choose a VM to inspect its configuration.")
            )
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
    .navigationTitle("macOS VMs")
    .onChange(of: model.virtualMachines, initial: true) {
      synchronizeSelection()
    }
    .toolbar {
      ToolbarItem {
        Button("Create VM", systemImage: "plus") {
          isCreating = true
        }
      }
    }
    .sheet(isPresented: $isCreating) {
      CreateVirtualMachineView(model: model)
    }
    .sheet(item: $machineToPrepare) { machine in
      MacRestoreImagePreparationView(machine: machine, appModel: model)
    }
    .sheet(item: $machineToInstall) { machine in
      MacVirtualMachineInstallationView(machine: machine, appModel: model)
    }
    .sheet(item: $machineToOpen) { machine in
      MacVirtualMachineRuntimeView(
        machine: machine,
        model: model.makeMacVirtualMachineRuntimeModel(for: machine)
      )
    }
    .confirmationDialog(
      "Force stop virtual machine?",
      isPresented: Binding(
        get: { machineToForceStop != nil },
        set: { if !$0 { machineToForceStop = nil } }
      ),
      presenting: machineToForceStop
    ) { machine in
      Button("Force Stop \(machine.name)", role: .destructive) {
        machineToForceStop = nil
        let runtime = model.makeMacVirtualMachineRuntimeModel(for: machine)
        Task { await runtime.forceStop() }
      }
    } message: { machine in
      Text("This immediately powers off \(machine.name) and may lose unsaved guest data.")
    }
    .confirmationDialog(
      "Discard virtual machine?",
      isPresented: Binding(
        get: { machineToDiscard != nil },
        set: { if !$0 { machineToDiscard = nil } }
      ),
      presenting: machineToDiscard
    ) { machine in
      Button("Discard \(machine.name)", role: .destructive) {
        machineToDiscard = nil
        Task { await model.discardVirtualMachine(id: machine.id) }
      }
    } message: { machine in
      Text(
        "This permanently removes \(machine.name), its virtual disk, and its platform identity. Cached restore images are retained."
      )
    }
  }

  private var selectedMachineID: VirtualMachineManifest.ID? {
    guard case .macOSVirtualMachine(let id) = model.workspaceRoute else { return nil }
    return id
  }

  private var selectedMachine: VirtualMachineManifest? {
    guard let selectedMachineID else { return nil }
    return model.virtualMachines.first { $0.id == selectedMachineID }
  }

  private func synchronizeSelection() {
    guard
      let id = model.virtualMachines.first?.id,
      !model.virtualMachines.contains(where: { $0.id == selectedMachineID })
    else { return }
    model.navigate(to: .macOSVirtualMachine(id))
  }
}

#Preview("macOS virtual machines") {
  RootView(model: .previewVirtualMachines)
    .frame(width: 1_080, height: 720)
}
