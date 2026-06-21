import SwiftUI
import UniformTypeIdentifiers

struct CreateVirtualMachineView: View {
  let model: AppModel
  private let resourceConstraint: ResourceDefaultConstraint?

  @Environment(\.dismiss) private var dismiss
  @State private var guest = VirtualMachineGuest.macOS
  @State private var name = "macOS"
  @State private var cpuCount: Int
  @State private var memoryGiB: Int
  @State private var diskGiB: Int
  @State private var installationMediaURL: URL?
  @State private var isChoosingInstallationMedia = false
  @State private var isCreating = false
  @State private var errorMessage: String?

  init(
    model: AppModel,
    initialGuest: VirtualMachineGuest = .macOS
  ) {
    let defaults = model.currentWorkloadCreationDefaults()
    self.model = model
    resourceConstraint = defaults.constraint
    _guest = State(initialValue: initialGuest)
    _name = State(initialValue: initialGuest == .macOS ? "macOS" : "Linux")
    _cpuCount = State(initialValue: defaults.virtualMachine.cpuCount)
    _memoryGiB = State(initialValue: defaults.virtualMachine.memoryGiB)
    _diskGiB = State(initialValue: defaults.virtualMachine.diskGiB)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      CreateVirtualMachineHeader(guest: guest)
      Form {
        Picker("Guest", selection: $guest) {
          Text("macOS").tag(VirtualMachineGuest.macOS)
          Text("Linux").tag(VirtualMachineGuest.linux)
        }
        .pickerStyle(.segmented)

        TextField("Name", text: $name)
        Stepper(
          "CPUs: \(cpuCount)",
          value: $cpuCount,
          in: 1...ProcessInfo.processInfo.processorCount
        )
        Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 1...128)
        Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: 8...1024, step: 8)
        WorkloadResourceConstraintNotice(constraint: resourceConstraint)

        if guest == .linux {
          LabeledContent("Installation ISO") {
            HStack(spacing: 8) {
              if let installationMediaURL {
                Text(installationMediaURL.lastPathComponent)
                  .lineLimit(1)
              } else {
                Text("Not selected")
                  .foregroundStyle(.secondary)
              }
              Button("Choose…") {
                isChoosingInstallationMedia = true
              }
            }
          }
        }
      }

      Text(creationDescription)
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
        .disabled(!canCreate)
      }
    }
    .padding(24)
    .frame(width: 540)
    .onChange(of: guest) { oldGuest, newGuest in
      let oldDefaultName = oldGuest == .macOS ? "macOS" : "Linux"
      if name == oldDefaultName {
        name = newGuest == .macOS ? "macOS" : "Linux"
      }
      errorMessage = nil
    }
    .fileImporter(
      isPresented: $isChoosingInstallationMedia,
      allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        installationMediaURL = urls.first
        errorMessage = nil
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
  }

  private var canCreate: Bool {
    !isCreating
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (guest == .macOS || installationMediaURL != nil)
  }

  private var creationDescription: LocalizedStringResource {
    switch guest {
    case .macOS:
      "Creates a sparse VM bundle. Restore-image preparation remains a separate, cancellable operation."
    case .linux:
      "Creates a sparse VM bundle, copies the selected ISO, and prepares persistent UEFI and machine identity artifacts as one recoverable operation."
    }
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
        switch guest {
        case .macOS:
          try await model.createVirtualMachineDraft(
            name: name,
            guest: .macOS,
            resources: resources
          )
        case .linux:
          guard let installationMediaURL else {
            throw LinuxVirtualMachineCreationError.unavailable
          }
          try await model.createLinuxVirtualMachine(
            name: name,
            resources: resources,
            installationMediaURL: installationMediaURL
          )
        }
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isCreating = false
      }
    }
  }

}

#Preview("Create macOS virtual machine") {
  CreateVirtualMachineView(model: .previewEmpty)
}

#Preview("Create Linux virtual machine") {
  CreateVirtualMachineView(
    model: .previewEmpty,
    initialGuest: .linux
  )
}

private struct CreateVirtualMachineHeader: View {
  let guest: VirtualMachineGuest

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: iconName)
        .font(.largeTitle)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title2.bold())
        Text("Native Virtualization.framework bundle")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var title: LocalizedStringResource {
    guest == .macOS ? "Create macOS VM" : "Create Linux VM"
  }

  private var iconName: String {
    guest == .macOS ? "macwindow.badge.plus" : "display.badge.plus"
  }

  private var tint: Color {
    guest == .macOS ? .indigo : .mint
  }
}
