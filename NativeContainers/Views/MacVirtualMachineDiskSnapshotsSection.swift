import SwiftUI

struct MacVirtualMachineDiskSnapshotsSection: View {
  let installState: VirtualMachineInstallState
  let runtime: MacVirtualMachineRuntimeModel
  let snapshots: MacVirtualMachineDiskSnapshotModel
  let diskMaintenanceIsBusy: Bool
  let discardSavedState: (() -> Void)?

  @State private var newSnapshotName = ""
  @State private var snapshotToRestore: MacVirtualMachineDiskSnapshot?
  @State private var isConfirmingRestore = false

  var body: some View {
    MacVirtualMachineDiskSnapshotsContent(
      snapshotItems: snapshots.snapshots,
      newSnapshotName: $newSnapshotName,
      isLoading: snapshots.isLoading,
      operation: snapshots.operation,
      isAtLimit: snapshots.isAtLimit,
      editBlock: editBlock,
      hostIsSupported: hostIsSupported,
      createSnapshot: createSnapshot,
      requestRestore: requestRestore,
      discardSavedState: discardSavedState
    )
    .task {
      await snapshots.load()
    }
    .confirmationDialog(
      restoreDialogTitle,
      isPresented: $isConfirmingRestore,
      presenting: snapshotToRestore
    ) { snapshot in
      Button("Restore Disk Snapshot", role: .destructive) {
        isConfirmingRestore = false
        Task {
          await snapshots.restoreSnapshot(id: snapshot.id)
        }
      }
    } message: { snapshot in
      Text(
        "The VM remains powered off. Disk changes and snapshots newer than “\(snapshot.name)” are permanently removed, then a fresh writable layer is created."
      )
    }
  }

  private var editBlock: MacVirtualMachineConfigurationEditBlock? {
    MacVirtualMachineConfigurationEditPolicy().block(
      installState: installState,
      runtime: runtime.snapshot,
      diskMaintenanceIsBusy: diskMaintenanceIsBusy
    )
  }

  private var hostIsSupported: Bool {
    if #available(macOS 27.0, *) {
      true
    } else {
      false
    }
  }

  private var restoreDialogTitle: LocalizedStringResource {
    guard let snapshotToRestore else {
      return "Restore disk snapshot?"
    }
    return "Restore “\(snapshotToRestore.name)”?"
  }

  private func createSnapshot() {
    let name = newSnapshotName
    Task {
      if await snapshots.createSnapshot(named: name) {
        newSnapshotName = ""
      }
    }
  }

  private func requestRestore(
    _ snapshot: MacVirtualMachineDiskSnapshot
  ) {
    snapshotToRestore = snapshot
    isConfirmingRestore = true
  }
}

private struct MacVirtualMachineDiskSnapshotsContent: View {
  let snapshotItems: [MacVirtualMachineDiskSnapshot]
  @Binding var newSnapshotName: String
  let isLoading: Bool
  let operation: MacVirtualMachineDiskSnapshotOperation?
  let isAtLimit: Bool
  let editBlock: MacVirtualMachineConfigurationEditBlock?
  let hostIsSupported: Bool
  let createSnapshot: () -> Void
  let requestRestore: (MacVirtualMachineDiskSnapshot) -> Void
  let discardSavedState: (() -> Void)?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "Snapshots preserve a powered-off disk checkpoint using Apple overlay layers. New guest writes continue in a separate active layer."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        if !hostIsSupported {
          MacVirtualMachineDiskSnapshotLock(
            message: "Disk snapshots require macOS 27 or later.",
            discardSavedState: nil
          )
        } else if let editBlock {
          MacVirtualMachineDiskSnapshotLock(
            message: editBlock.message,
            discardSavedState: editBlock == .savedStatePresent
              ? discardSavedState : nil
          )
        }

        MacVirtualMachineDiskSnapshotCreator(
          name: $newSnapshotName,
          isBusy: isLoading || operation != nil,
          isAtLimit: isAtLimit,
          canCreate: hostIsSupported && editBlock == nil,
          create: createSnapshot
        )

        Divider()

        if isLoading {
          MacVirtualMachineDiskSnapshotProgress(
            label: "Loading disk snapshots"
          )
        } else if let operation {
          MacVirtualMachineDiskSnapshotProgress(
            label: operation.progressLabel
          )
        } else if snapshotItems.isEmpty {
          Text("No disk snapshots yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        } else {
          VStack(spacing: 0) {
            ForEach(snapshotItems) { snapshot in
              MacVirtualMachineDiskSnapshotRow(
                name: snapshot.name,
                createdAt: snapshot.createdAt,
                capturedLayerCount: snapshot.capturedLayerCount,
                canRestore: hostIsSupported && editBlock == nil,
                restore: { requestRestore(snapshot) }
              )
              if snapshot.id != snapshotItems.last?.id {
                Divider()
              }
            }
          }
        }

        Text(
          "Up to \(MacVirtualMachineDiskSnapshotConfiguration.maximumSnapshotCount) snapshots are kept. Restoring an earlier checkpoint prunes every newer checkpoint and layer."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    } label: {
      Label("Disk Snapshots", systemImage: "clock.arrow.circlepath")
        .font(.headline)
    }
  }
}

private struct MacVirtualMachineDiskSnapshotCreator: View {
  @Binding var name: String
  let isBusy: Bool
  let isAtLimit: Bool
  let canCreate: Bool
  let create: () -> Void

  var body: some View {
    HStack {
      TextField("Snapshot name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(createIfAvailable)
      Spacer()
      Button("Create Snapshot", action: createIfAvailable)
        .buttonStyle(.borderedProminent)
        .disabled(!isCreationAvailable)
    }
    .disabled(isBusy || !canCreate)
  }

  private var isCreationAvailable: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isBusy && !isAtLimit && canCreate
  }

  private func createIfAvailable() {
    guard isCreationAvailable else { return }
    create()
  }
}

private struct MacVirtualMachineDiskSnapshotRow: View {
  let name: String
  let createdAt: Date
  let capturedLayerCount: Int
  let canRestore: Bool
  let restore: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.indigo)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.callout.weight(.medium))
        HStack(spacing: 6) {
          Text(createdAt, format: .dateTime.month().day().year().hour().minute())
          Text(verbatim: "•")
            .accessibilityHidden(true)
          Text(layerDescription)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Restore…", action: restore)
        .disabled(!canRestore)
    }
    .padding(.vertical, 9)
  }

  private var layerDescription: LocalizedStringResource {
    if capturedLayerCount == 0 {
      "Base disk"
    } else if capturedLayerCount == 1 {
      "1 frozen layer"
    } else {
      "\(capturedLayerCount) frozen layers"
    }
  }
}

private struct MacVirtualMachineDiskSnapshotProgress: View {
  let label: LocalizedStringResource

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(label)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }
}

private struct MacVirtualMachineDiskSnapshotLock: View {
  let message: LocalizedStringResource
  let discardSavedState: (() -> Void)?

  var body: some View {
    MacVirtualMachineConfigurationEditLockBanner(
      message: message,
      discardSavedState: discardSavedState
    )
  }
}

#Preview("Snapshot history") {
  @Previewable @State var name = "Before Upgrade"
  let snapshotItems = [
    try! MacVirtualMachineDiskSnapshot(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      name: "Clean Install",
      createdAt: Date(timeIntervalSince1970: 1_750_000_000),
      capturedLayerCount: 0
    ),
    try! MacVirtualMachineDiskSnapshot(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      name: "Developer Tools",
      createdAt: Date(timeIntervalSince1970: 1_750_086_400),
      capturedLayerCount: 1
    ),
  ]

  MacVirtualMachineDiskSnapshotsContent(
    snapshotItems: snapshotItems,
    newSnapshotName: $name,
    isLoading: false,
    operation: nil,
    isAtLimit: false,
    editBlock: nil,
    hostIsSupported: true,
    createSnapshot: {},
    requestRestore: { _ in },
    discardSavedState: nil
  )
  .padding(24)
  .frame(width: 700)
}
