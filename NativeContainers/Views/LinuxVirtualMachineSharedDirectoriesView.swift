import SwiftUI
import UniformTypeIdentifiers

struct LinuxVirtualMachineSharedDirectoriesView: View {
  let runtimeState: LinuxVirtualMachineRuntimeState
  let hasActiveRuntime: Bool
  let editMessage: LocalizedStringResource?
  let discardSavedState: (() -> Void)?
  let sharedDirectories: LinuxVirtualMachineSharedDirectoriesModel

  @State private var isChoosingDirectory = false
  @State private var isPresentingAddSheet = false
  @State private var pendingDirectoryURL: URL?
  @State private var directoryToRemove: LinuxVirtualMachineSharedDirectorySummary?
  @State private var isConfirmingRemoval = false

  var body: some View {
    LinuxVirtualMachineSharedDirectoriesSection(
      directories: sharedDirectories.directories,
      isLoading: sharedDirectories.isLoading,
      isWorking: sharedDirectories.isWorking,
      errorMessage: sharedDirectories.errorMessage,
      editBlockMessage: editBlockMessage,
      discardSavedState: discardSavedState,
      chooseDirectory: { isChoosingDirectory = true },
      remove: {
        directoryToRemove = $0
        isConfirmingRemoval = true
      },
      dismissError: sharedDirectories.clearError
    )
    .task {
      await sharedDirectories.load()
    }
    .fileImporter(
      isPresented: $isChoosingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      do {
        guard let sourceURL = try result.get().first else { return }
        pendingDirectoryURL = sourceURL
        isPresentingAddSheet = true
      } catch {
        sharedDirectories.report(error)
      }
    }
    .sheet(isPresented: $isPresentingAddSheet, onDismiss: clearPendingDirectory) {
      if let sourceURL = pendingDirectoryURL {
        LinuxVirtualMachineAddSharedDirectoryView(
          sourceURL: sourceURL,
          isWorking: sharedDirectories.isWorking,
          cancel: { isPresentingAddSheet = false },
          save: { guestName, readOnly in
            Task {
              if await sharedDirectories.add(
                sourceURL: sourceURL,
                guestName: guestName,
                readOnly: readOnly
              ) {
                isPresentingAddSheet = false
              }
            }
          }
        )
      }
    }
    .confirmationDialog(
      "Remove shared folder?",
      isPresented: $isConfirmingRemoval,
      presenting: directoryToRemove
    ) { directory in
      Button("Remove \(directory.guestName)", role: .destructive) {
        directoryToRemove = nil
        Task { await sharedDirectories.remove(id: directory.id) }
      }
    } message: { directory in
      Text(
        "This removes \(directory.guestName) from the guest. Files in \(directory.lastKnownPath) stay untouched."
      )
    }
  }

  private var editBlockMessage: LocalizedStringResource? {
    if let editMessage { return editMessage }
    if runtimeState == .ownedElsewhere {
      return "This VM is active in another NativeContainers process."
    }
    if hasActiveRuntime || runtimeState != .stopped {
      return "Shut down the VM before changing shared folders."
    }
    return nil
  }

  private func clearPendingDirectory() {
    pendingDirectoryURL = nil
  }
}

private struct LinuxVirtualMachineSharedDirectoriesSection: View {
  let directories: [LinuxVirtualMachineSharedDirectorySummary]
  let isLoading: Bool
  let isWorking: Bool
  let errorMessage: String?
  let editBlockMessage: LocalizedStringResource?
  let discardSavedState: (() -> Void)?
  let chooseDirectory: () -> Void
  let remove: (LinuxVirtualMachineSharedDirectorySummary) -> Void
  let dismissError: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        if let editBlockMessage {
          VirtualMachineConfigurationEditLockBanner(
            message: editBlockMessage,
            discardSavedState: discardSavedState
          )
        }
        if let errorMessage {
          LinuxVirtualMachineSharedDirectoryErrorBanner(
            message: errorMessage,
            dismiss: dismissError
          )
        }

        if isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading shared folders…")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 90)
        } else if directories.isEmpty {
          ContentUnavailableView {
            Label("No Shared Folders", systemImage: "folder.badge.plus")
          } description: {
            Text(
              "Choose host folders to expose through the VM’s native VirtioFS device."
            )
          }
          .frame(maxWidth: .infinity, minHeight: 130)
        } else {
          VStack(spacing: 0) {
            ForEach(directories.enumerated(), id: \.element.id) { index, directory in
              LinuxVirtualMachineSharedDirectoryRow(
                guestName: directory.guestName,
                hostPath: directory.lastKnownPath,
                readOnly: directory.readOnly,
                canRemove: editBlockMessage == nil && !isWorking,
                remove: { remove(directory) }
              )
              if index < directories.count - 1 {
                Divider()
              }
            }
          }
        }

        LinuxVirtioFSMountInstructions()

        HStack {
          Text("Folder changes apply on the next cold start.")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Spacer()
          if isWorking {
            ProgressView()
              .controlSize(.small)
          }
          Button("Add Shared Folder…", systemImage: "plus", action: chooseDirectory)
            .disabled(editBlockMessage != nil || isLoading || isWorking)
        }
      }
      .padding(4)
    } label: {
      Label("Shared Folders", systemImage: "folder.badge.gearshape")
        .font(.headline)
    }
  }
}

private struct LinuxVirtualMachineSharedDirectoryRow: View {
  let guestName: String
  let hostPath: String
  let readOnly: Bool
  let canRemove: Bool
  let remove: () -> Void

  private var accessLabel: LocalizedStringResource {
    readOnly ? "Read Only" : "Read & Write"
  }

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: readOnly ? "folder.badge.minus" : "folder")
        .foregroundStyle(.mint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(guestName)
            .font(.headline)
          Text(accessLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(readOnly ? Color.secondary : Color.mint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        Text(hostPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: "/mnt/nativecontainers/\(guestName)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!canRemove)
        .help("Remove this guest share without deleting host files")
    }
    .padding(.vertical, 10)
  }
}

private struct LinuxVirtioFSMountInstructions: View {
  private let mountCommand =
    "sudo mkdir -p /mnt/nativecontainers && sudo mount -t virtiofs nativecontainers /mnt/nativecontainers"

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("Mount in Linux", systemImage: "terminal")
        .font(.subheadline.weight(.semibold))
      Text(
        "Run this command in the guest after boot. The Linux kernel must include VirtioFS support."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(verbatim: mountCommand)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
  }
}

private struct LinuxVirtualMachineAddSharedDirectoryView: View {
  let sourceURL: URL
  let isWorking: Bool
  let cancel: () -> Void
  let save: (String, Bool) -> Void

  @State private var guestName: String
  @State private var readOnly = true

  init(
    sourceURL: URL,
    isWorking: Bool,
    cancel: @escaping () -> Void,
    save: @escaping (String, Bool) -> Void
  ) {
    self.sourceURL = sourceURL
    self.isWorking = isWorking
    self.cancel = cancel
    self.save = save
    _guestName = State(initialValue: sourceURL.lastPathComponent)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      LinuxVirtualMachineAddSharedDirectoryHeader(
        sourcePath: sourceURL.path(percentEncoded: false)
      )
      Form {
        TextField("Guest name", text: $guestName)
        Picker("Access", selection: $readOnly) {
          Text("Read Only").tag(true)
          Text("Read & Write").tag(false)
        }
        .pickerStyle(.segmented)
      }
      .formStyle(.grouped)
      Text(
        "After mounting VirtioFS, this folder appears under /mnt/nativecontainers/<guest name>."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Add", action: { save(guestName, readOnly) })
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(
            guestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || isWorking
          )
      }
    }
    .padding(24)
    .frame(width: 500)
  }
}

private struct LinuxVirtualMachineAddSharedDirectoryHeader: View {
  let sourcePath: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Add Linux Shared Folder")
        .font(.title2.weight(.semibold))
      Text(sourcePath)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
    }
  }
}

private struct LinuxVirtualMachineSharedDirectoryErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
      Spacer()
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.caption)
    .foregroundStyle(.orange)
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}
