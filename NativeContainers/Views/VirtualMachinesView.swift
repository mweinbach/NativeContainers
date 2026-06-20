import SwiftUI

struct VirtualMachinesView: View {
  let model: AppModel
  @State private var isCreating = false

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
          VirtualMachineRow(machine: machine)
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
  }
}

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: machine.guest == .macOS ? "macwindow" : "display")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 4) {
        Text(machine.name)
          .font(.headline)
        Text(machine.installState.rawValue)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Label("\(machine.resources.cpuCount) CPUs", systemImage: "cpu")
          Label {
            Text(Int64(clamping: machine.resources.memoryBytes), format: .byteCount(style: .memory))
          } icon: {
            Image(systemName: "memorychip")
          }
          Label {
            Text(Int64(clamping: machine.resources.diskBytes), format: .byteCount(style: .file))
          } icon: {
            Image(systemName: "internaldrive")
          }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
      Spacer()
      Button("Open") {}
        .disabled(machine.installState != .stopped)
    }
    .padding(.vertical, 7)
  }
}

struct CreateVirtualMachineView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = "macOS"
  @State private var cpuCount = min(max(ProcessInfo.processInfo.processorCount / 2, 2), 8)
  @State private var memoryGiB = 8
  @State private var diskGiB = 64
  @State private var isCreating = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      CreateVirtualMachineHeader()
      Form {
        TextField("Name", text: $name)
        Stepper(
          "CPUs: \(cpuCount)", value: $cpuCount, in: 1...ProcessInfo.processInfo.processorCount)
        Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 1...128)
        Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: 8...1024, step: 8)
      }
      Text(
        "This creates a sparse, self-contained VM bundle. Restore-image discovery and macOS installation are the next staged operation."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") {
          create()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  private func create() {
    isCreating = true
    errorMessage = nil
    Task {
      do {
        let resources = try VirtualMachineResources(
          cpuCount: cpuCount,
          memoryBytes: UInt64(memoryGiB) * VirtualMachineResources.bytesPerGiB,
          diskBytes: UInt64(diskGiB) * VirtualMachineResources.bytesPerGiB
        )
        try await model.createVirtualMachineDraft(
          name: name,
          guest: .macOS,
          resources: resources
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isCreating = false
      }
    }
  }
}

struct CreateVirtualMachineHeader: View {
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "macwindow.badge.plus")
        .font(.largeTitle)
        .foregroundStyle(.indigo)
      VStack(alignment: .leading, spacing: 3) {
        Text("Create macOS VM")
          .font(.title2.bold())
        Text("Native Virtualization.framework bundle")
          .foregroundStyle(.secondary)
      }
    }
  }
}
