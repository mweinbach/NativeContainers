import SwiftUI

struct ExportVirtualMachineView: View {
  let machine: VirtualMachineManifest
  let destinationURL: URL
  let model: AppModel

  @Environment(\.dismiss) private var dismiss
  @State private var transferTask: Task<Void, Never>?
  @State private var isCancelling = false
  @State private var errorMessage: String?

  private var isExporting: Bool {
    transferTask != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Export \(machine.name)")
          .font(.title2.bold())
        Text(destinationURL.path(percentEncoded: false))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
      }

      LabeledContent("Identity") {
        Text("Preserved")
      }
      LabeledContent("Startup") {
        Text("Cold boot")
      }

      Label(
        "Saved sessions and runtime state are excluded from the package.",
        systemImage: "snowflake"
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      switch machine.guest {
      case .macOS:
        Label(
          "Shared-folder bookmarks and the cached restore-image location stay on this Mac.",
          systemImage: "folder.badge.minus"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      case .linux:
        Label(
          "Shared-folder bookmarks stay on this Mac.",
          systemImage: "folder.badge.minus"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      case .windows:
        Label(
          "Shared-folder bookmarks stay on this Mac; the package retains its encrypted guest-agent identity.",
          systemImage: "folder.badge.minus"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        if isExporting {
          ProgressView()
            .controlSize(.small)
          Text(isCancelling ? "Cancelling and cleaning up…" : "Exporting package…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          guard let transferTask else {
            dismiss()
            return
          }
          isCancelling = true
          transferTask.cancel()
        } label: {
          Text(isCancelling ? "Cancelling…" : "Cancel")
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isCancelling)

        Button("Export") {
          export()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(isExporting)
      }
    }
    .padding(24)
    .frame(width: 560)
    .interactiveDismissDisabled(isExporting)
    .onDisappear {
      transferTask?.cancel()
    }
  }

  private func export() {
    errorMessage = nil
    transferTask = Task {
      do {
        _ = try await model.exportVirtualMachine(
          id: machine.id,
          to: destinationURL
        )
        transferTask = nil
        dismiss()
      } catch is CancellationError {
        transferTask = nil
        isCancelling = false
        dismiss()
      } catch {
        transferTask = nil
        isCancelling = false
        errorMessage = error.localizedDescription
      }
    }
  }
}

struct ImportVirtualMachineView: View {
  private enum IdentityChoice: String, CaseIterable, Identifiable {
    case preserve
    case copy

    var id: Self { self }

    var title: String {
      switch self {
      case .preserve:
        "Restore original identity"
      case .copy:
        "Import as a new copy"
      }
    }
  }

  let sourceURL: URL
  let model: AppModel

  @Environment(\.dismiss) private var dismiss
  @State private var identityChoice = IdentityChoice.preserve
  @State private var copyName: String
  @State private var transferTask: Task<Void, Never>?
  @State private var isCancelling = false
  @State private var errorMessage: String?

  init(sourceURL: URL, model: AppModel) {
    self.sourceURL = sourceURL
    self.model = model
    _copyName = State(
      initialValue: "\(sourceURL.deletingPathExtension().lastPathComponent) Copy"
    )
  }

  private var isImporting: Bool {
    transferTask != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Import Virtual Machine")
          .font(.title2.bold())
        Text(sourceURL.path(percentEncoded: false))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
      }

      Picker("Platform identity", selection: $identityChoice) {
        ForEach(IdentityChoice.allCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .pickerStyle(.radioGroup)
      .disabled(isImporting)

      if identityChoice == .copy {
        TextField("Copy name", text: $copyName)
          .textFieldStyle(.roundedBorder)
          .disabled(isImporting)
      }

      Group {
        if identityChoice == .preserve {
          Label(
            "Use this for a restore. Import stops if the same VM or platform identity already exists.",
            systemImage: "externaldrive.badge.checkmark"
          )
        } else {
          Label(
            "The imported copy receives fresh VM and platform identities.",
            systemImage: "square.on.square"
          )
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)

      Label(
        "Imported VMs start from a cold boot. Saved sessions and host shared-folder bookmarks are excluded.",
        systemImage: "snowflake"
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        if isImporting {
          ProgressView()
            .controlSize(.small)
          Text(isCancelling ? "Cancelling and cleaning up…" : "Importing package…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          guard let transferTask else {
            dismiss()
            return
          }
          isCancelling = true
          transferTask.cancel()
        } label: {
          Text(isCancelling ? "Cancelling…" : "Cancel")
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isCancelling)

        Button("Import") {
          importPackage()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
          isImporting
            || (identityChoice == .copy
              && copyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
      }
    }
    .padding(24)
    .frame(width: 560)
    .interactiveDismissDisabled(isImporting)
    .onDisappear {
      transferTask?.cancel()
    }
  }

  private func importPackage() {
    errorMessage = nil
    let mode: VirtualMachineImportMode =
      switch identityChoice {
      case .preserve:
        .preserveIdentity
      case .copy:
        .clone(name: copyName)
      }

    transferTask = Task {
      do {
        _ = try await model.importVirtualMachine(
          from: sourceURL,
          mode: mode
        )
        transferTask = nil
        dismiss()
      } catch is CancellationError {
        transferTask = nil
        isCancelling = false
        dismiss()
      } catch {
        transferTask = nil
        isCancelling = false
        errorMessage = error.localizedDescription
      }
    }
  }
}

#Preview("Export VM") {
  let model = AppModel.previewVirtualMachines
  if let machine = model.virtualMachines.first {
    ExportVirtualMachineView(
      machine: machine,
      destinationURL: FileManager.default.temporaryDirectory
        .appending(path: "\(machine.name).nativevm"),
      model: model
    )
  }
}

#Preview("Import VM") {
  ImportVirtualMachineView(
    sourceURL: FileManager.default.temporaryDirectory
      .appending(path: "Portable Mac.nativevm"),
    model: .previewVirtualMachines
  )
}
