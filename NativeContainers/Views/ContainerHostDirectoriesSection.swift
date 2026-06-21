import SwiftUI
import UniformTypeIdentifiers

struct ContainerHostDirectoriesSection: View {
  @Binding var mounts: [ContainerHostDirectoryMountDraft]
  let reportError: (String) -> Void

  @State private var isChoosingDirectory = false

  var body: some View {
    Section("Host folders") {
      if mounts.isEmpty {
        Text("No Mac folders shared")
          .foregroundStyle(.secondary)
      }

      ForEach($mounts) { $mount in
        ContainerHostDirectoryMountRow(mount: $mount) {
          mounts.removeAll { $0.id == mount.id }
        }
      }

      Button("Share Folder…", systemImage: "folder.badge.plus") {
        isChoosingDirectory = true
      }

      Label(
        "Folders are pinned to the item you reviewed and revalidated before every start. New shares are read-only.",
        systemImage: "checkmark.shield"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .fileImporter(
      isPresented: $isChoosingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      do {
        guard let sourceURL = try result.get().first else { return }
        let standardizedURL = sourceURL.standardizedFileURL
        guard !mounts.contains(where: { $0.sourceURL == standardizedURL }) else {
          reportError("That host folder is already in this request.")
          return
        }
        mounts.append(
          ContainerHostDirectoryMountDraft(sourceURL: standardizedURL)
        )
      } catch {
        reportError(error.localizedDescription)
      }
    }
    .fileDialogMessage("Choose a Mac folder to share with this container.")
    .fileDialogConfirmationLabel("Share Folder")
  }
}

private struct ContainerHostDirectoryMountRow: View {
  @Binding var mount: ContainerHostDirectoryMountDraft
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .bottom, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Mac folder")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(mount.sourceURL.nativeContainersPOSIXPath)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          Text("Container path")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "Container path",
            text: $mount.containerPath,
            prompt: Text("/workspace/project")
          )
          .labelsHidden()
          .font(.body.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Remove Host Folder", systemImage: "minus.circle", action: onDelete)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
          .padding(.bottom, 5)
      }

      Picker("Access", selection: $mount.isReadOnly) {
        Text("Read Only").tag(true)
        Text("Read & Write").tag(false)
      }
      .pickerStyle(.segmented)

      if !mount.isReadOnly {
        Label(
          "Read & Write lets processes in the container modify files in this Mac folder.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 4)
  }
}
