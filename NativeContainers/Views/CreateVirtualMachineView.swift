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
  @State private var isWindowsSecureBootEnabled = false
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
    _name = State(initialValue: initialGuest.defaultDisplayName)
    _cpuCount = State(
      initialValue: initialGuest == .windows
        ? max(defaults.virtualMachine.cpuCount, 2)
        : defaults.virtualMachine.cpuCount
    )
    _memoryGiB = State(
      initialValue: initialGuest == .windows
        ? max(defaults.virtualMachine.memoryGiB, 4)
        : defaults.virtualMachine.memoryGiB
    )
    _diskGiB = State(
      initialValue: initialGuest == .windows
        ? max(defaults.virtualMachine.diskGiB, 64)
        : defaults.virtualMachine.diskGiB
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      CreateVirtualMachineHeader(guest: guest)
      Form {
        Picker("Guest", selection: $guest) {
          Text("macOS").tag(VirtualMachineGuest.macOS)
          Text("Linux").tag(VirtualMachineGuest.linux)
          Text("Windows").tag(VirtualMachineGuest.windows)
        }
        .pickerStyle(.segmented)

        TextField("Name", text: $name)
        Stepper(
          "CPUs: \(cpuCount)",
          value: $cpuCount,
          in: minimumCPUCount...ProcessInfo.processInfo.processorCount
        )
        Stepper(
          "Memory: \(memoryGiB) GiB",
          value: $memoryGiB,
          in: minimumMemoryGiB...128
        )
        Stepper(
          "Disk: \(diskGiB) GiB",
          value: $diskGiB,
          in: minimumDiskGiB...1024,
          step: 8
        )
        WorkloadResourceConstraintNotice(constraint: resourceConstraint)

        if guest != .macOS {
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

        if guest == .windows {
          Toggle("Secure Boot", isOn: $isWindowsSecureBootEnabled)
          Text(windowsSecurityDescription)
            .font(.caption)
            .foregroundStyle(
              isWindowsSecureBootEnabled ? Color.orange : Color.secondary
            )
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
      let oldDefaultName = oldGuest.defaultDisplayName
      if name == oldDefaultName {
        name = newGuest.defaultDisplayName
      }
      if newGuest == .windows {
        cpuCount = max(cpuCount, 2)
        memoryGiB = max(memoryGiB, 4)
        diskGiB = max(diskGiB, 64)
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
      && cpuCount >= minimumCPUCount
      && memoryGiB >= minimumMemoryGiB
      && diskGiB >= minimumDiskGiB
      && (guest != .windows || windowsSecurityMode.isCurrentlyBootable)
  }

  private var minimumCPUCount: Int {
    guest == .windows ? 2 : 1
  }

  private var minimumMemoryGiB: Int {
    guest == .windows ? 4 : 1
  }

  private var minimumDiskGiB: Int {
    guest == .windows ? 64 : 8
  }

  private var creationDescription: LocalizedStringResource {
    switch guest {
    case .macOS:
      "Creates a sparse VM bundle. Restore-image preparation remains a separate, cancellable operation."
    case .linux:
      "Creates a sparse VM bundle, copies the selected ISO, and prepares persistent UEFI and machine identity artifacts as one recoverable operation."
    case .windows:
      "Validates and copies an ARM64 Windows ISO, creates persistent UEFI identity, and supplies a TPM-only setup compatibility answer disk."
    }
  }

  private var windowsSecurityDescription: LocalizedStringResource {
    switch windowsSecurityMode {
    case .productionSecureBoot:
      "Secure Boot support is prepared, but creating and booting this VM is disabled until the signed guest drivers pass release validation."
    case .developmentTestSigning:
      "Secure Boot is off. This is the current bootable Windows mode."
    }
  }

  private var windowsSecurityMode: WindowsVirtualMachineSecurityMode {
    isWindowsSecureBootEnabled ? .productionSecureBoot : .currentDefault
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
        case .windows:
          guard let installationMediaURL else {
            throw WindowsVirtualMachineCreationError.unavailable
          }
          try await model.createWindowsVirtualMachine(
            name: name,
            resources: resources,
            installationMediaURL: installationMediaURL,
            securityMode: windowsSecurityMode
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

#Preview("Create Windows virtual machine") {
  CreateVirtualMachineView(
    model: .previewEmpty,
    initialGuest: .windows
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
    switch guest {
    case .macOS: "Create macOS VM"
    case .linux: "Create Linux VM"
    case .windows: "Create Windows VM"
    }
  }

  private var iconName: String {
    switch guest {
    case .macOS: "macwindow.badge.plus"
    case .linux: "display.badge.plus"
    case .windows: "rectangle.badge.plus"
    }
  }

  private var tint: Color {
    switch guest {
    case .macOS: .indigo
    case .linux: .mint
    case .windows: .blue
    }
  }
}

extension VirtualMachineGuest {
  fileprivate var defaultDisplayName: String {
    switch self {
    case .macOS: "macOS"
    case .linux: "Linux"
    case .windows: "Windows 11"
    }
  }
}
