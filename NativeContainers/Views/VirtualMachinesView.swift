import SwiftUI

struct VirtualMachinesView: View {
  let model: AppModel

  @State private var isCreating = false
  @State private var machineToPrepare: VirtualMachineManifest?
  @State private var machineToInstall: VirtualMachineManifest?

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
            prepare: { machineToPrepare = machine },
            install: { machineToInstall = machine }
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
  }
}

#Preview("macOS virtual machines") {
  RootView(model: .previewVirtualMachines)
    .frame(width: 1_080, height: 720)
}
