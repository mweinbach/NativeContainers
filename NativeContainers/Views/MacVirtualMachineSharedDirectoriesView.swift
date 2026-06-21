import SwiftUI
import UniformTypeIdentifiers

struct MacVirtualMachineSharedDirectoriesView: View {
  let machine: VirtualMachineManifest
  let runtime: MacVirtualMachineRuntimeModel
  let sharedDirectories: MacVirtualMachineSharedDirectoriesModel
  let diskMaintenanceIsBusy: Bool
  let discardSavedState: (() -> Void)?

  @State private var isChoosingDirectory = false
  @State private var isPresentingAddSheet = false
  @State private var pendingDirectoryURL: URL?
  @State private var directoryToRemove: MacVirtualMachineSharedDirectorySummary?

  var body: some View {
    MacVirtualMachineSharedDirectoriesSection(
      directories: sharedDirectories.directories,
      isLoading: sharedDirectories.isLoading,
      isWorking: sharedDirectories.isWorking,
      editBlockReason: editBlockReason,
      chooseDirectory: { isChoosingDirectory = true },
      remove: { directoryToRemove = $0 },
      discardSavedState: discardSavedState
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
        MacVirtualMachineAddSharedDirectoryView(
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
      isPresented: Binding(
        get: { directoryToRemove != nil },
        set: { if !$0 { directoryToRemove = nil } }
      ),
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

  private var editBlockReason: LocalizedStringResource? {
    guard !diskMaintenanceIsBusy else {
      return "Wait for virtual disk maintenance to finish."
    }
    guard machine.installState == .stopped else {
      return "Finish preparing and installing this VM before adding shared folders."
    }
    guard runtime.snapshot.target == nil else {
      return "Shut down this VM before changing shared folders."
    }
    switch runtime.snapshot.state {
    case .stopped:
      break
    case .ownedElsewhere:
      return "Another NativeContainers process owns this VM."
    case .inspectingSavedState:
      return "Checking the VM’s saved state…"
    default:
      return "Wait for this VM to finish changing state."
    }
    switch runtime.snapshot.savedStateStatus {
    case .none:
      return nil
    case .unknown:
      return "Checking the VM’s saved state…"
    case .available, .incompatible:
      return "Discard the saved state before changing shared folders."
    }
  }

  private func clearPendingDirectory() {
    pendingDirectoryURL = nil
  }
}

private struct MacVirtualMachineSharedDirectoriesSection: View {
  let directories: [MacVirtualMachineSharedDirectorySummary]
  let isLoading: Bool
  let isWorking: Bool
  let editBlockReason: LocalizedStringResource?
  let chooseDirectory: () -> Void
  let remove: (MacVirtualMachineSharedDirectorySummary) -> Void
  let discardSavedState: (() -> Void)?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        if let editBlockReason {
          HStack(spacing: 10) {
            Label(editBlockReason, systemImage: "lock.fill")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            if let discardSavedState {
              Button("Discard Saved State…", action: discardSavedState)
            }
          }
          .padding(10)
          .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
              "Choose a host folder to mount under /Volumes/My Shared Files the next time this VM starts."
            )
          }
          .frame(maxWidth: .infinity, minHeight: 150)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(directories.enumerated()), id: \.element.id) { index, directory in
              MacVirtualMachineSharedDirectoryRow(
                directory: directory,
                canRemove: editBlockReason == nil && !isWorking,
                remove: { remove(directory) }
              )
              if index < directories.count - 1 {
                Divider()
              }
            }
          }
        }

        HStack {
          Text("Changes apply on the next cold start.")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Spacer()
          if isWorking {
            ProgressView()
              .controlSize(.small)
          }
          Button("Add Shared Folder…", systemImage: "plus", action: chooseDirectory)
            .disabled(editBlockReason != nil || isLoading || isWorking)
        }
      }
      .padding(4)
    } label: {
      Label("Shared Folders", systemImage: "folder.badge.gearshape")
        .font(.headline)
    }
  }
}

private struct MacVirtualMachineSharedDirectoryRow: View {
  let directory: MacVirtualMachineSharedDirectorySummary
  let canRemove: Bool
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: directory.readOnly ? "folder.badge.minus" : "folder")
        .foregroundStyle(.blue)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(directory.guestName)
            .font(.headline)
          Text(directory.readOnly ? "Read Only" : "Read & Write")
            .font(.caption2.weight(.medium))
            .foregroundStyle(directory.readOnly ? Color.secondary : Color.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        Text(directory.lastKnownPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("/Volumes/My Shared Files/\(directory.guestName)")
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

private struct MacVirtualMachineAddSharedDirectoryView: View {
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
      VStack(alignment: .leading, spacing: 5) {
        Text("Add Shared Folder")
          .font(.title2.weight(.semibold))
        Text(sourceURL.path(percentEncoded: false))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      Form {
        TextField("Guest name", text: $guestName)
        Picker("Access", selection: $readOnly) {
          Text("Read Only").tag(true)
          Text("Read & Write").tag(false)
        }
        .pickerStyle(.segmented)
      }
      .formStyle(.grouped)
      Text("The folder mounts at /Volumes/My Shared Files/<guest name> after a cold start.")
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
    .frame(width: 480)
  }
}
