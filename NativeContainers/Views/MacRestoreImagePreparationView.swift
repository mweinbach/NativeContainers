import SwiftUI
import UniformTypeIdentifiers

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
      MacRestoreImagePreparationHeader(machineName: model.machine.name)
      VirtualMachineResourceSummary(resources: model.machine.resources)
      Divider()
      MacRestoreImageDiscoverySection(model: model)
      MacRestoreImagePreparationProgress(model: model)

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
    .onDisappear {
      operationTask?.cancel()
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
}

private struct MacRestoreImagePreparationHeader: View {
  let machineName: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.down.doc.fill")
        .font(.largeTitle)
        .foregroundStyle(.indigo)
      VStack(alignment: .leading, spacing: 3) {
        Text("Prepare macOS")
          .font(.title2.bold())
        Text("Download or choose an Apple restore image for \(machineName)")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MacRestoreImageDiscoverySection: View {
  let model: MacRestoreImagePreparationModel

  var body: some View {
    if let image = model.latestImage {
      GroupBox("Latest supported restore image") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                "macOS \(image.majorVersion).\(image.minorVersion).\(image.patchVersion)"
              )
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
}

private struct MacRestoreImagePreparationProgress: View {
  let model: MacRestoreImagePreparationModel

  var body: some View {
    switch model.stage {
    case .downloading:
      transferProgress {
        Text("Downloading restore image")
      }
    case .importing:
      transferProgress {
        Text("Copying restore image into the private app cache")
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
        "Platform artifacts are ready for macOS installation.",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .idle, .discovering:
      EmptyView()
    }
  }

  private func transferProgress<Title: View>(
    @ViewBuilder title: () -> Title
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if let fraction = model.downloadProgress?.fractionCompleted {
        ProgressView(value: fraction)
      } else {
        ProgressView()
      }
      if let progress = model.downloadProgress {
        HStack {
          title()
          Spacer()
          Text(downloadDescription(progress))
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
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
    acquisition: PreviewRestoreImageAcquisition()
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

private struct PreviewRestoreImageAcquisition: RestoreImageAcquiring {
  func acquire(
    _ source: RestoreImageAcquisitionSource,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease {
    RestoreImageCacheLease(
      fileURL: URL(filePath: "/tmp/UniversalMac.ipsw"),
      purpose: source.isRemote ? .remoteDownload : .localImport,
      abandonPolicy: source.isRemote ? .retainArtifacts : .discardArtifacts
    )
  }

  func commit(_ lease: RestoreImageCacheLease) async {}
  func abandon(_ lease: RestoreImageCacheLease) async throws {}
}

extension RestoreImageAcquisitionSource {
  fileprivate var isRemote: Bool {
    if case .remote = self { return true }
    return false
  }
}
