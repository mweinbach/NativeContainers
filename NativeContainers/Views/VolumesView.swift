import SwiftUI

struct VolumesView: View {
  let appModel: AppModel
  @State private var operations: VolumeManagementModel
  @State private var isShowingCreation = false
  @State private var deletionPlan: VolumeDeletionPlan?
  @State private var prunePlan: VolumePrunePlan?
  @State private var operationTask: Task<Void, Never>?

  init(model: AppModel) {
    appModel = model
    _operations = State(initialValue: model.makeVolumeManagementModel())
  }

  var body: some View {
    Group {
      if appModel.volumes.isEmpty {
        ContentUnavailableView(
          "No volumes",
          systemImage: "externaldrive",
          description: Text("Create a persistent ext4 volume for Apple containers.")
        )
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(appModel.volumes) { volume in
                Button {
                  appModel.navigate(to: .volume(volume.id))
                } label: {
                  VolumeRow(
                    name: volume.name,
                    driver: volume.driver,
                    format: volume.format,
                    sizeBytes: volume.sizeBytes,
                    isAnonymous: volume.isAnonymous,
                    consumerCount: volume.usedByContainerIDs.count
                  )
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .background(
                  selectedVolumeID == volume.id
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 9)
                )
                .contextMenu {
                  Button("Review Deletion…", systemImage: "trash", role: .destructive) {
                    prepareDeletion(volume.name)
                  }
                  .disabled(
                    operations.isWorking
                      || operationTask != nil
                      || !volume.usedByContainerIDs.isEmpty
                  )
                }
              }
            }
            .padding(.vertical, 8)
          }
          .frame(minWidth: 330, idealWidth: 390)
          .background(.background.secondary)

          if let volume = selectedVolume {
            VolumeInspector(
              volume: volume,
              isOperationActive: operations.isWorking || operationTask != nil,
              onDelete: { prepareDeletion(volume.name) }
            )
            .frame(minWidth: 430)
          } else {
            ContentUnavailableView(
              "Select a volume",
              systemImage: "sidebar.right",
              description: Text("Inspect capacity, allocated storage, metadata, and consumers.")
            )
            .frame(minWidth: 430)
          }
        }
        .onChange(of: appModel.volumes) {
          synchronizeSelection()
        }
      }
    }
    .navigationTitle("Volumes")
    .overlay(alignment: .bottomLeading) {
      VStack(alignment: .leading, spacing: 8) {
        if let cleanupResult = operations.cleanupResult {
          InfrastructureCleanupBanner(result: cleanupResult)
        }
        if let errorMessage = operations.errorMessage {
          InfrastructureErrorBanner(message: errorMessage)
        }
      }
      .padding()
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if operationTask != nil {
          Button("Cancel Operation", systemImage: "xmark.circle") {
            operationTask?.cancel()
          }
          .help("Cancel the active volume operation")
        }
        Button("Prune Volumes", systemImage: "trash.slash") {
          preparePrune()
        }
        .disabled(
          operations.isWorking || operationTask != nil || appModel.volumes.isEmpty
        )
        Button("New Volume", systemImage: "plus") {
          isShowingCreation = true
        }
        .disabled(operations.isWorking || operationTask != nil)
      }
    }
    .onDisappear {
      operationTask?.cancel()
    }
    .sheet(isPresented: $isShowingCreation) {
      VolumeCreationView(model: operations)
    }
    .confirmationDialog(
      "Delete volume?",
      isPresented: deletionPlanPresentation,
      presenting: deletionPlan
    ) { plan in
      Button("Delete \(plan.volume.name)", role: .destructive) {
        deletionPlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          _ = await operations.deleteReviewedVolume(plan)
        }
      }
    } message: { plan in
      Text(
        "This removes the ext4 volume at \(plan.volume.source). Its data cannot be recovered."
      )
    }
    .confirmationDialog(
      "Prune unused volumes?",
      isPresented: prunePlanPresentation,
      presenting: prunePlan
    ) { plan in
      Button("Delete \(plan.candidates.count) Volumes", role: .destructive) {
        prunePlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          _ = await operations.pruneReviewedVolumes(plan)
        }
      }
      .disabled(plan.candidates.isEmpty)
    } message: { plan in
      Text(
        "NativeContainers revalidates and removes only these reviewed, unreferenced volumes: \(plan.candidates.map(\.volume.name).formatted()). Estimated allocated storage: \(Int64(clamping: plan.estimatedReclaimableBytes).formatted(.byteCount(style: .file)))."
      )
    }
  }

  private var selectedVolume: VolumeRecord? {
    appModel.volumes.first { $0.id == selectedVolumeID }
  }

  private var selectedVolumeID: VolumeRecord.ID? {
    guard case .volume(let id) = appModel.workspaceRoute else { return nil }
    return id
  }

  private var deletionPlanPresentation: Binding<Bool> {
    Binding(
      get: { deletionPlan != nil },
      set: { if !$0 { deletionPlan = nil } }
    )
  }

  private var prunePlanPresentation: Binding<Bool> {
    Binding(
      get: { prunePlan != nil },
      set: { if !$0 { prunePlan = nil } }
    )
  }

  private func synchronizeSelection() {
    guard selectedVolume == nil else { return }
    if let id = appModel.volumes.first?.id {
      appModel.navigate(to: .volume(id))
    }
  }

  private func prepareDeletion(_ name: String) {
    guard operationTask == nil, !operations.isWorking else { return }
    operationTask = Task {
      defer { operationTask = nil }
      deletionPlan = await operations.prepareDeletion(name: name)
    }
  }

  private func preparePrune() {
    guard operationTask == nil, !operations.isWorking else { return }
    operationTask = Task {
      defer { operationTask = nil }
      prunePlan = await operations.preparePrune()
    }
  }
}

struct VolumeRow: View {
  let name: String
  let driver: String
  let format: String
  let sizeBytes: UInt64?
  let isAnonymous: Bool
  let consumerCount: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "externaldrive.fill")
        .font(.title2)
        .foregroundStyle(.orange)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(name)
            .font(.headline)
          if isAnonymous {
            Text("Anonymous")
              .font(.caption)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
          }
        }
        Text("\(driver) · \(format)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        if let sizeBytes {
          Text(Int64(clamping: sizeBytes), format: .byteCount(style: .file))
            .monospacedDigit()
        }
        if consumerCount > 0 {
          Label("\(consumerCount)", systemImage: "shippingbox")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
  }
}

struct VolumeInspector: View {
  let volume: VolumeRecord
  let isOperationActive: Bool
  let onDelete: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VolumeInspectorHeader(
          name: volume.name,
          isAnonymous: volume.isAnonymous,
          canDelete: !isOperationActive && volume.usedByContainerIDs.isEmpty,
          onDelete: onDelete
        )
        VolumeStorageSection(
          capacityBytes: volume.sizeBytes,
          allocatedBytes: volume.allocatedBytes,
          format: volume.format,
          driver: volume.driver
        )
        VolumeLocationSection(
          source: volume.source,
          createdAt: volume.createdAt
        )
        InfrastructureConsumersSection(
          title: "Container references",
          resourceNames: volume.usedByContainerIDs,
          emptyMessage: "No container configuration references this volume."
        )
        InfrastructureMetadataSection(
          labels: volume.labels,
          options: volume.options
        )
      }
      .padding(24)
    }
  }
}

struct VolumeInspectorHeader: View {
  let name: String
  let isAnonymous: Bool
  let canDelete: Bool
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "externaldrive.fill")
        .font(.largeTitle)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.title.bold())
          .textSelection(.enabled)
        Text(isAnonymous ? "Anonymous persistent volume" : "Named persistent volume")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        .disabled(!canDelete)
        .help(canDelete ? "Review volume deletion" : "Remove all referring containers first")
    }
  }
}

struct VolumeStorageSection: View {
  let capacityBytes: UInt64?
  let allocatedBytes: UInt64?
  let format: String
  let driver: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Storage")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
        GridRow {
          LabeledContent("Capacity") {
            InfrastructureByteValue(bytes: capacityBytes)
          }
          LabeledContent("Allocated") {
            InfrastructureByteValue(bytes: allocatedBytes)
          }
        }
        GridRow {
          LabeledContent("Driver", value: driver)
          LabeledContent("Format", value: format)
        }
      }
    }
  }
}

struct VolumeLocationSection: View {
  let source: String
  let createdAt: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Location")
        .font(.headline)
      LabeledContent("Host image") {
        Text(source)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      LabeledContent("Created") {
        Text(createdAt, format: .dateTime.year().month().day().hour().minute())
      }
    }
  }
}

struct VolumeCreationView: View {
  @Environment(\.dismiss) private var dismiss
  let model: VolumeManagementModel
  @State private var name = ""
  @State private var sizeGiB = 64
  @State private var journalMode = VolumeJournalMode.ordered
  @State private var labelsText = ""
  @State private var validationMessage: String?
  @State private var reviewedPlan: VolumeCreationPlan?
  @State private var operationTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Volume") {
          TextField("Name", text: $name, prompt: Text("database-data"))
          Stepper(value: $sizeGiB, in: 1...2_048) {
            LabeledContent("Capacity", value: "\(sizeGiB) GiB")
          }
          Picker("Journal mode", selection: $journalMode) {
            ForEach(VolumeJournalMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          Text(
            "Volumes use Apple’s local sparse ext4 driver. Capacity and host allocation are reported separately."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Labels") {
          TextEditor(text: $labelsText)
            .font(.body.monospaced())
            .frame(minHeight: 90)
          Text("Optional KEY=value metadata, one entry per line.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking || operationTask != nil)
      .navigationTitle("New Volume")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.isWorking || operationTask != nil {
            Button("Cancel Operation") {
              operationTask?.cancel()
            }
          } else {
            Button("Cancel") { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Review") { review() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || operationTask != nil || name.isEmpty)
        }
      }
    }
    .frame(minWidth: 560, minHeight: 520)
    .interactiveDismissDisabled(model.isWorking || operationTask != nil)
    .confirmationDialog(
      "Create volume?",
      isPresented: reviewedPlanPresentation,
      presenting: reviewedPlan
    ) { plan in
      Button("Create \(plan.request.name)") {
        guard operationTask == nil else { return }
        reviewedPlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          if await model.createReviewedVolume(plan) {
            dismiss()
          }
        }
      }
    } message: { plan in
      Text(
        "Create a \(plan.request.sizeBytes.formatted(.byteCount(style: .file))) local ext4 volume with \(plan.request.journalMode.title.lowercased()) journaling."
      )
    }
  }

  private var reviewedPlanPresentation: Binding<Bool> {
    Binding(
      get: { reviewedPlan != nil },
      set: { if !$0 { reviewedPlan = nil } }
    )
  }

  private func review() {
    guard operationTask == nil, !model.isWorking else { return }
    do {
      let labels = try ResourceMetadataParser.parse(labelsText)
      let request = try VolumeCreateRequest(
        name: name,
        sizeBytes: UInt64(sizeGiB) * 1_024 * VolumeCreateRequest.bytesPerMiB,
        journalMode: journalMode,
        labels: labels
      )
      validationMessage = nil
      operationTask = Task {
        defer { operationTask = nil }
        reviewedPlan = await model.prepareCreation(request)
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

struct InfrastructureByteValue: View {
  let bytes: UInt64?

  var body: some View {
    if let bytes {
      Text(Int64(clamping: bytes), format: .byteCount(style: .file))
        .monospacedDigit()
    } else {
      Text("Unavailable")
        .foregroundStyle(.secondary)
    }
  }
}

struct InfrastructureConsumersSection: View {
  let title: LocalizedStringResource
  let resourceNames: [String]
  let emptyMessage: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      if resourceNames.isEmpty {
        Text(emptyMessage)
          .foregroundStyle(.secondary)
      } else {
        Text(resourceNames.formatted())
          .textSelection(.enabled)
      }
    }
  }
}

struct InfrastructureMetadataSection: View {
  let labels: [String: String]
  let options: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Metadata")
        .font(.headline)
      InfrastructureKeyValueList(
        title: "Labels",
        values: labels.filter { $0.key != ResourceOperationLabel.key }
      )
      InfrastructureKeyValueList(title: "Options", values: options)
    }
  }
}

struct InfrastructureKeyValueList: View {
  let title: LocalizedStringResource
  let values: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      if values.isEmpty {
        Text("None")
          .foregroundStyle(.secondary)
      } else {
        ForEach(values.keys.sorted(), id: \.self) { key in
          LabeledContent(key, value: values[key] ?? "")
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
    }
  }
}

struct InfrastructureCleanupBanner: View {
  let result: ResourceCleanupResult

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if result.removedResourceNames.isEmpty {
        Label("No reviewed resources were removed.", systemImage: "info.circle")
      } else {
        Label(
          "Removed: \(result.removedResourceNames.formatted())",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
      }

      if result.reclaimedBytes > 0 {
        Text(
          "Reclaimed \(Int64(clamping: result.reclaimedBytes).formatted(.byteCount(style: .file)))."
        )
        .font(.caption)
      }

      ForEach(result.failedResources) { failure in
        Label(
          "\(failure.resource): \(failure.message)",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .frame(maxWidth: 520, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

struct InfrastructureErrorBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .foregroundStyle(.red)
  }
}

#Preview("Volumes") {
  NavigationStack {
    VolumesView(model: .preview)
  }
  .frame(width: 980, height: 680)
}
