import SwiftUI
import UniformTypeIdentifiers

struct VirtualMachinesView: View {
  let model: AppModel
  @State private var isCreating = false
  @State private var machineToPrepare: VirtualMachineManifest?

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
          VirtualMachineRow(machine: machine) {
            machineToPrepare = machine
          }
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
  }
}

struct VirtualMachineRow: View {
  let machine: VirtualMachineManifest
  let prepare: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: machine.guest == .macOS ? "macwindow" : "display")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 4) {
        Text(machine.name)
          .font(.headline)
        Text(installStateLabel)
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
      action
    }
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private var action: some View {
    switch machine.installState {
    case .draft:
      Button("Prepare…", action: prepare)
        .buttonStyle(.borderedProminent)
    case .readyToInstall:
      Button("Install") {}
        .disabled(true)
        .help("Installation is staged until the Virtualization entitlement is available.")
    case .installing:
      ProgressView()
        .controlSize(.small)
    case .stopped:
      Button("Open") {}
    case .failed:
      Button("Details") {}
        .disabled(true)
    }
  }

  private var installStateLabel: String {
    switch machine.installState {
    case .draft: "Needs restore image"
    case .readyToInstall: "Ready to install"
    case .installing: "Installing macOS"
    case .stopped: "Stopped"
    case .failed: "Needs attention"
    }
  }
}

struct MacRestoreImagePreparationView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: MacRestoreImagePreparationModel
  @State private var isChoosingRestoreImage = false
  @State private var operationTask: Task<Void, Never>?

  init(machine: VirtualMachineManifest, appModel: AppModel) {
    _model = State(
      initialValue: appModel.makeMacRestoreImagePreparationModel(for: machine)
    )
  }

  init(model: MacRestoreImagePreparationModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header
      machineSummary
      Divider()
      latestRestoreImage
      operationProgress

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        Button("Choose Local IPSW…") {
          isChoosingRestoreImage = true
        }
        .disabled(model.isWorking)

        Spacer()
        Button(operationTask == nil ? "Close" : "Cancel Operation") {
          if let operationTask {
            operationTask.cancel()
          } else {
            dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)

        Button("Download & Prepare") {
          startOperation {
            await model.downloadLatestAndPrepare()
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
          model.latestImage == nil
            || model.latestImageCompatibilityMessage != nil
            || model.isWorking
        )
      }
    }
    .padding(24)
    .frame(width: 620)
    .interactiveDismissDisabled(operationTask != nil)
    .task {
      await model.discoverLatest()
    }
    .fileImporter(
      isPresented: $isChoosingRestoreImage,
      allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        startOperation {
          await model.prepareLocalImage(at: url)
        }
      case .failure(let error):
        model.clearError()
        if !error.isUserCancellation {
          model.reportError(error.localizedDescription)
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.down.doc.fill")
        .font(.largeTitle)
        .foregroundStyle(.indigo)
      VStack(alignment: .leading, spacing: 3) {
        Text("Prepare macOS")
          .font(.title2.bold())
        Text("Download or choose an Apple restore image for \(model.machine.name)")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var machineSummary: some View {
    HStack(spacing: 18) {
      Label("\(model.machine.resources.cpuCount) CPUs", systemImage: "cpu")
      Label {
        Text(
          Int64(clamping: model.machine.resources.memoryBytes),
          format: .byteCount(style: .memory)
        )
      } icon: {
        Image(systemName: "memorychip")
      }
      Label {
        Text(
          Int64(clamping: model.machine.resources.diskBytes),
          format: .byteCount(style: .file)
        )
      } icon: {
        Image(systemName: "internaldrive")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var latestRestoreImage: some View {
    if let image = model.latestImage {
      GroupBox("Latest supported restore image") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("macOS \(versionString(for: image))")
                .font(.headline)
              Text("Build \(image.buildVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Apple IPSW", systemImage: "checkmark.seal.fill")
              .foregroundStyle(.green)
          }

          Text(
            "Requires at least \(image.minimumCPUCount) CPUs and \(Int64(clamping: image.minimumMemoryBytes), format: .byteCount(style: .memory)) of memory."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          if let message = model.latestImageCompatibilityMessage {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if model.stage == .discovering {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Asking Virtualization.framework for the latest supported image…")
          .foregroundStyle(.secondary)
      }
    } else {
      Button("Retry Latest Image Discovery") {
        Task { await model.discoverLatest() }
      }
      .disabled(model.isWorking)
    }
  }

  @ViewBuilder
  private var operationProgress: some View {
    switch model.stage {
    case .downloading:
      VStack(alignment: .leading, spacing: 7) {
        if let fraction = model.downloadProgress?.fractionCompleted {
          ProgressView(value: fraction)
        } else {
          ProgressView()
        }
        if let progress = model.downloadProgress {
          HStack {
            Text("Downloading restore image")
            Spacer()
            Text(downloadDescription(progress))
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    case .preparing:
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Validating the IPSW and creating Apple platform identity…")
          .foregroundStyle(.secondary)
      }
    case .finished:
      Label(
        "Platform artifacts are ready for macOS installation.", systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .idle, .discovering:
      EmptyView()
    }
  }

  private func startOperation(
    _ operation: @escaping @MainActor @Sendable () async -> Bool
  ) {
    guard operationTask == nil else { return }
    operationTask = Task {
      let succeeded = await operation()
      operationTask = nil
      if succeeded {
        dismiss()
      }
    }
  }

  private func versionString(for image: MacRestoreImageInfo) -> String {
    "\(image.majorVersion).\(image.minorVersion).\(image.patchVersion)"
  }

  private func downloadDescription(_ progress: RestoreImageDownloadProgress) -> String {
    let received = ByteCountFormatter.string(
      fromByteCount: progress.receivedBytes,
      countStyle: .file
    )
    guard let totalBytes = progress.totalBytes else { return received }
    let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    return "\(received) of \(total)"
  }
}

extension Error {
  fileprivate var isUserCancellation: Bool {
    (self as NSError).domain == NSCocoaErrorDomain
      && (self as NSError).code == CocoaError.userCancelled.rawValue
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

#Preview("macOS virtual machines") {
  RootView(model: .previewVirtualMachines)
    .frame(width: 1_080, height: 720)
}

#Preview("Restore image preparation") {
  let resources = try! VirtualMachineResources(
    cpuCount: 6,
    memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 96 * VirtualMachineResources.bytesPerGiB
  )
  let machine = try! VirtualMachineManifest(
    name: "Development Mac",
    guest: .macOS,
    resources: resources
  )
  let model = MacRestoreImagePreparationModel(
    machine: machine,
    discovery: PreviewRestoreImageDiscovery(),
    downloader: PreviewRestoreImageDownloader()
  ) { _ in }
  MacRestoreImagePreparationView(model: model)
}

private struct PreviewRestoreImageDiscovery: MacRestoreImageDiscovering {
  func latestSupported() async throws -> MacRestoreImageInfo {
    MacRestoreImageInfo(
      url: URL(string: "https://updates.example/UniversalMac.ipsw")!,
      buildVersion: "26A123",
      majorVersion: 26,
      minorVersion: 0,
      patchVersion: 0,
      minimumCPUCount: 4,
      minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      isSupported: true
    )
  }
}

private struct PreviewRestoreImageDownloader: MacRestoreImageDownloading {
  func download(
    from sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> URL {
    URL(filePath: "/tmp/UniversalMac.ipsw")
  }
}
