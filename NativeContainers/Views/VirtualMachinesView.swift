import SwiftUI
import UniformTypeIdentifiers

private struct VirtualMachineExportRequest: Identifiable {
  let id = UUID()
  let machine: VirtualMachineManifest
  let destinationURL: URL
}

private struct VirtualMachineImportRequest: Identifiable {
  let id = UUID()
  let sourceURL: URL
}

struct VirtualMachinesView: View {
  let model: AppModel

  @State private var isCreating = false
  @State private var machineToPrepare: VirtualMachineManifest?
  @State private var machineToInstall: VirtualMachineManifest?
  @State private var machineToOpen: VirtualMachineManifest?
  @State private var machineToForceStop: VirtualMachineManifest?
  @State private var machineToClone: VirtualMachineManifest?
  @State private var machineToDiscard: VirtualMachineManifest?
  @State private var exportRequest: VirtualMachineExportRequest?
  @State private var importRequest: VirtualMachineImportRequest?
  @State private var isChoosingImport = false
  @State private var importPickerError: String?

  var body: some View {
    VStack(spacing: 0) {
      if model.virtualMachines.isEmpty {
        ContentUnavailableView {
          Label("No Virtual Machines", systemImage: "display.2")
        } description: {
          Text("Create a native macOS or GUI Linux virtual machine.")
        } actions: {
          HStack {
            Button("Create VM") { isCreating = true }
              .buttonStyle(.borderedProminent)
            Button("Import VM") { isChoosingImport = true }
          }
        }
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(model.virtualMachines) { machine in
                GuestVirtualMachineRow(
                  machine: machine,
                  model: model,
                  isSelected: selectedMachineID == machine.id,
                  onSelect: {
                    model.navigate(to: .macOSVirtualMachine(machine.id))
                  },
                  prepare: { machineToPrepare = machine },
                  install: { machineToInstall = machine },
                  open: { machineToOpen = machine },
                  confirmForceStop: { machineToForceStop = machine },
                  clone: { machineToClone = machine },
                  export: { chooseExportDestination(for: machine) },
                  discard: { machineToDiscard = machine }
                )
              }
            }
            .padding(8)
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .frame(minWidth: 360, idealWidth: 430, maxWidth: 560)

          if let selectedMachine {
            GuestVirtualMachineConfigurationView(
              machine: selectedMachine,
              model: model
            )
            .id(selectedMachine.id)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ContentUnavailableView(
              "Select a Virtual Machine",
              systemImage: "display.2",
              description: Text("Choose a VM to inspect its configuration.")
            )
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
    .navigationTitle("Virtual Machines")
    .onChange(of: model.virtualMachines, initial: true) {
      synchronizeSelection()
    }
    .toolbar {
      ToolbarItemGroup {
        Button("Import VM", systemImage: "square.and.arrow.down") {
          isChoosingImport = true
        }
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
      GuestVirtualMachineRuntimeView(machine: machine, model: model)
    }
    .sheet(item: $machineToClone) { machine in
      CloneVirtualMachineView(machine: machine, model: model)
    }
    .sheet(item: $exportRequest) { request in
      ExportVirtualMachineView(
        machine: request.machine,
        destinationURL: request.destinationURL,
        model: model
      )
    }
    .sheet(item: $importRequest) { request in
      ImportVirtualMachineView(sourceURL: request.sourceURL, model: model)
    }
    .fileImporter(
      isPresented: $isChoosingImport,
      allowedContentTypes: [.nativeContainersVirtualMachine],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let sourceURL = urls.first else { return }
        importRequest = VirtualMachineImportRequest(sourceURL: sourceURL)
      case .failure(let error):
        importPickerError = error.localizedDescription
      }
    } onCancellation: {
      importPickerError = nil
    }
    .alert(
      "Unable to Choose VM Package",
      isPresented: Binding(
        get: { importPickerError != nil },
        set: { if !$0 { importPickerError = nil } }
      )
    ) {
      Button("OK") {
        importPickerError = nil
      }
    } message: {
      Text(importPickerError ?? "The package picker failed.")
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
        forceStop(machine)
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
        "This permanently removes \(machine.name), its virtual disk, platform identity, and bundled installation media."
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

  private func forceStop(_ machine: VirtualMachineManifest) {
    Task {
      switch machine.guest {
      case .macOS:
        await model.makeMacVirtualMachineRuntimeModel(for: machine).forceStop()
      case .linux:
        await model.makeLinuxVirtualMachineRuntimeModel(for: machine).forceStop()
      }
    }
  }

  private func chooseExportDestination(for machine: VirtualMachineManifest) {
    Task { @MainActor in
      guard
        let destinationURL = await MacVirtualMachineExportDestinationPicker()
          .chooseDestination(for: machine.name)
      else {
        return
      }
      exportRequest = VirtualMachineExportRequest(
        machine: machine,
        destinationURL: destinationURL
      )
    }
  }
}

private struct GuestVirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let model: AppModel
  let isSelected: Bool
  let onSelect: () -> Void
  let prepare: () -> Void
  let install: () -> Void
  let open: () -> Void
  let confirmForceStop: () -> Void
  let clone: () -> Void
  let export: () -> Void
  let discard: () -> Void

  var body: some View {
    switch machine.guest {
    case .macOS:
      MacVirtualMachineRow(
        machine: machine,
        availability: model.virtualMachineAvailability,
        runtime: model.makeMacVirtualMachineRuntimeModel(for: machine),
        diskMaintenance: model.makeVirtualMachineDiskImageMaintenanceModel(
          for: machine
        ),
        isSelected: isSelected,
        onSelect: onSelect,
        prepare: prepare,
        install: install,
        open: open,
        forceStop: confirmForceStop,
        clone: clone,
        export: export,
        discard: discard
      )
    case .linux:
      LinuxVirtualMachineRow(
        machine: machine,
        runtime: model.makeLinuxVirtualMachineRuntimeModel(for: machine),
        diskMaintenance: model.makeVirtualMachineDiskImageMaintenanceModel(
          for: machine
        ),
        isSelected: isSelected,
        onSelect: onSelect,
        open: open,
        confirmForceStop: confirmForceStop,
        clone: clone,
        export: export,
        discard: discard
      )
    }
  }
}

private struct GuestVirtualMachineConfigurationView: View {
  let machine: VirtualMachineManifest
  let model: AppModel

  var body: some View {
    switch machine.guest {
    case .macOS:
      MacVirtualMachineConfigurationView(
        machine: machine,
        runtime: model.makeMacVirtualMachineRuntimeModel(for: machine),
        audio: model.makeMacVirtualMachineAudioModel(for: machine),
        network: model.makeMacVirtualMachineNetworkModel(for: machine),
        naming: model.makeVirtualMachineNameModel(for: machine),
        compute: model.makeVirtualMachineComputeModel(for: machine),
        diskSnapshots: model.makeMacVirtualMachineDiskSnapshotModel(
          for: machine
        ),
        sharedDirectories: model.makeMacVirtualMachineSharedDirectoriesModel(
          for: machine
        ),
        diskMaintenance: model.makeVirtualMachineDiskImageMaintenanceModel(
          for: machine
        )
      )
    case .linux:
      LinuxVirtualMachineConfigurationView(
        machine: machine,
        runtime: model.makeLinuxVirtualMachineRuntimeModel(for: machine),
        naming: model.makeVirtualMachineNameModel(for: machine),
        compute: model.makeVirtualMachineComputeModel(for: machine),
        diskMaintenance: model.makeVirtualMachineDiskImageMaintenanceModel(
          for: machine
        ),
        network: model.makeLinuxVirtualMachineNetworkModel(for: machine),
        sharedDirectories: model.makeLinuxVirtualMachineSharedDirectoriesModel(
          for: machine
        )
      )
    }
  }
}

private struct GuestVirtualMachineRuntimeView: View {
  let machine: VirtualMachineManifest
  let model: AppModel

  var body: some View {
    switch machine.guest {
    case .macOS:
      MacVirtualMachineRuntimeView(
        machine: machine,
        model: model.makeMacVirtualMachineRuntimeModel(for: machine),
        usb: model.makeMacVirtualMachineUSBModel(for: machine)
      )
    case .linux:
      LinuxVirtualMachineRuntimeView(
        machine: machine,
        model: model.makeLinuxVirtualMachineRuntimeModel(for: machine)
      )
    }
  }
}

#Preview("Virtual machines") {
  RootView(model: .previewVirtualMachines)
    .frame(width: 1_080, height: 720)
}

#Preview("Virtual machines — ASIF") {
  RootView(model: .previewASIFVirtualMachines)
    .frame(width: 1_080, height: 720)
}

#Preview("Linux virtual machine") {
  RootView(model: .previewLinuxVirtualMachine)
    .frame(width: 1_080, height: 720)
}
