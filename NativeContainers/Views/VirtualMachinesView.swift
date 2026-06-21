import SwiftUI

struct VirtualMachinesView: View {
  let model: AppModel

  @State private var isCreating = false
  @State private var machineToPrepare: VirtualMachineManifest?
  @State private var machineToInstall: VirtualMachineManifest?
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
        List(model.virtualMachines) { machine in
          VirtualMachineRow(
            machine: machine,
            installationAvailability: model.virtualMachineInstallationAvailability,
            prepare: { machineToPrepare = machine },
            install: { machineToInstall = machine },
            discard: { machineToDiscard = machine }
          )
        }
      }
    }
    .navigationTitle("macOS VMs")
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
}

#Preview("macOS virtual machines") {
  RootView(model: .previewVirtualMachines)
    .frame(width: 1_080, height: 720)
}
