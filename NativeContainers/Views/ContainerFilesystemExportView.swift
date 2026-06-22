import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContainerFilesystemExportView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerFilesystemExportModel
  @State private var destinationURL: URL?
  @State private var isChoosingDestination = false

  private let destinationPicker = MacContainerFilesystemExportDestinationPicker()

  init(container: ContainerRecord, appModel: AppModel) {
    _model = State(
      initialValue: appModel.makeContainerFilesystemExportModel(for: container)
    )
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ContainerFilesystemExportHeader(containerID: model.containerID)

        Form {
          ContainerFilesystemExportScopeSection()
          ContainerFilesystemExportDestinationSection(
            destinationPath: destinationURL?.path(percentEncoded: false),
            isChoosing: isChoosingDestination,
            isDisabled: model.isExporting || model.receipt != nil,
            choose: chooseDestination
          )
          ContainerFilesystemExportStatusSection(
            isExporting: model.isExporting,
            receipt: model.receipt,
            errorMessage: model.errorMessage,
            warningMessage: model.warningMessage
          )
        }
        .formStyle(.grouped)
      }
      .navigationTitle("Export Container Filesystem")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.receipt == nil {
            Button("Cancel") { dismiss() }
              .disabled(model.isExporting)
          } else {
            Button("Done") { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if model.receipt == nil {
            Button("Export", systemImage: "archivebox.fill") {
              exportFilesystem()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
              model.isExporting || isChoosingDestination || destinationURL == nil
            )
          }
        }
      }
    }
    .frame(minWidth: 620, minHeight: 520)
    .interactiveDismissDisabled(model.isExporting)
  }

  private func chooseDestination() {
    guard !isChoosingDestination, !model.isExporting else { return }
    isChoosingDestination = true
    Task {
      defer { isChoosingDestination = false }
      guard
        let destination = await destinationPicker.chooseDestination(
          for: model.containerID
        )
      else {
        return
      }
      destinationURL = destination
      model.clearMessages()
    }
  }

  private func exportFilesystem() {
    guard let destinationURL else { return }
    Task {
      _ = await model.export(to: destinationURL)
    }
  }
}

private struct ContainerFilesystemExportHeader: View {
  let containerID: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "archivebox.fill")
        .font(.largeTitle)
        .foregroundStyle(.blue)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Export the stopped root filesystem")
          .font(.title2.bold())
        Text(containerID)
          .font(.body.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 8)
  }
}

private struct ContainerFilesystemExportScopeSection: View {
  var body: some View {
    Section("Archive Contents") {
      Label(
        "The container’s writable root filesystem",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
      Label(
        "Restricted PAX tar archive produced by Apple’s container service",
        systemImage: "archivebox"
      )
      Label(
        "Named volumes, bind mounts, and runtime or VM state are not included",
        systemImage: "externaldrive.badge.xmark"
      )
      .foregroundStyle(.secondary)
      Text(
        "Apple requires the container to remain stopped. NativeContainers verifies the exact container identity again before publishing the archive."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct ContainerFilesystemExportDestinationSection: View {
  let destinationPath: String?
  let isChoosing: Bool
  let isDisabled: Bool
  let choose: () -> Void

  var body: some View {
    Section("Destination") {
      LabeledContent("Archive") {
        if let destinationPath {
          Text(destinationPath)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        } else {
          Text("No destination selected")
            .foregroundStyle(.secondary)
        }
      }
      Button {
        choose()
      } label: {
        if isChoosing {
          Label("Choosing…", systemImage: "folder")
        } else {
          Label("Choose Destination…", systemImage: "folder")
        }
      }
      .disabled(isChoosing || isDisabled)
      Text("Existing files and symbolic links are never replaced.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ContainerFilesystemExportStatusSection: View {
  let isExporting: Bool
  let receipt: ContainerFilesystemExportReceipt?
  let errorMessage: String?
  let warningMessage: String?

  var body: some View {
    if isExporting {
      Section("Progress") {
        ProgressView("Exporting the root filesystem…")
        Text(
          "The export can’t be cancelled after Apple’s container service accepts it. This window will remain open until private staging has settled."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }

    if let receipt {
      Section("Completed") {
        Label("Filesystem archive exported", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        LabeledContent("Size") {
          Text(
            receipt.byteCount,
            format: ByteCountFormatStyle(style: .file)
          )
        }
        LabeledContent("SHA-256") {
          Text(receipt.sha256)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
    }

    if let warningMessage {
      Section("Warning") {
        Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    } else if let errorMessage {
      Section("Export Failed") {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
  }
}

@MainActor
private protocol ContainerFilesystemExportDestinationChoosing {
  func chooseDestination(for containerID: String) async -> URL?
}

@MainActor
private struct MacContainerFilesystemExportDestinationPicker:
  ContainerFilesystemExportDestinationChoosing
{
  func chooseDestination(for containerID: String) async -> URL? {
    await withCheckedContinuation { continuation in
      let panel = NSSavePanel()
      panel.title = String(
        localized: "Export Container Filesystem",
        comment: "Title of the save panel used to export a stopped container filesystem."
      )
      panel.prompt = String(
        localized: "Choose",
        comment: "Confirmation button in the container filesystem export save panel."
      )
      panel.message = String(
        localized:
          "Choose a new .tar archive. Existing files are never replaced.",
        comment: "Safety message in the container filesystem export save panel."
      )
      panel.allowedContentTypes = [.tarArchive]
      panel.allowsOtherFileTypes = false
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue =
        ContainerFilesystemExportRequest.suggestedFileName(
          containerID: containerID
        )

      let completion: (NSApplication.ModalResponse) -> Void = { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        panel.begin(completionHandler: completion)
      }
    }
  }
}

#Preview("Filesystem export") {
  ContainerFilesystemExportView(
    container: ContainerRecord(
      id: "api",
      imageReference: "ghcr.io/example/api:latest",
      platform: "linux/arm64",
      state: .stopped,
      ipAddress: nil,
      createdAt: Date(),
      startedAt: nil,
      cpuCount: 4,
      memoryBytes: 4 * 1_024 * 1_024 * 1_024,
      ports: []
    ),
    appModel: .preview
  )
}
