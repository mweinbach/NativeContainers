import SwiftUI

struct ContainerBuilderManagementView: View {
  let model: ContainerBuilderManagementModel
  let appOwnedCacheModel: AppOwnedBuildCacheModel

  @State private var reviewedAction: ContainerBuilderManagementAction?
  @State private var isConfirmingAppOwnedCacheReset = false
  @State private var operationTask: Task<Void, Never>?

  var body: some View {
    Form {
      if model.isLoading, model.inspection == nil {
        Section {
          HStack {
            ProgressView()
              .controlSize(.small)
            Text("Inspecting Apple’s shared builder…")
          }
        }
      }

      if let inspection = model.inspection {
        ContainerBuilderSummarySection(inspection: inspection)
        ContainerBuilderSafetySection(builder: inspection.builder)
        ContainerBuilderActionsSection(
          builder: inspection.builder,
          isBusy: model.isBusy,
          review: review
        )
      } else if !model.isLoading, model.errorMessage == nil {
        Section {
          ContentUnavailableView(
            "Builder status unavailable",
            systemImage: "shippingbox",
            description: Text("Refresh to inspect Apple’s shared BuildKit builder.")
          )
        }
      }

      if let result = model.result {
        ContainerBuilderResultSection(result: result)
      }

      AppOwnedBuildCacheSection(
        model: appOwnedCacheModel,
        reset: { isConfirmingAppOwnedCacheReset = true }
      )

      if let errorMessage = model.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }

      if let errorMessage = appOwnedCacheModel.errorMessage {
        Section {
          Label(errorMessage, systemImage: "externaldrive.badge.exclamationmark")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if operationTask != nil {
          Button("Cancel Operation", systemImage: "xmark.circle", role: .destructive) {
            operationTask?.cancel()
          }
        } else {
          Button("Refresh", systemImage: "arrow.clockwise") {
            startOperation { await refresh() }
          }
          .disabled(model.isBusy || appOwnedCacheModel.isBusy)
        }
      }
    }
    .task {
      if model.inspection == nil || appOwnedCacheModel.snapshot == nil {
        startOperation { await refresh() }
      }
    }
    .confirmationDialog(
      reviewedAction?.confirmationTitle ?? "Review builder action",
      isPresented: reviewIsPresented,
      presenting: model.plan
    ) { plan in
      Button(plan.action.confirmationButtonTitle, role: .destructive) {
        startOperation {
          _ = await model.execute(
            plan,
            authorization: plan.action.requiresInterruptionAuthorization
              ? ContainerBuilderManagementAuthorization(
                allowsInterruptRunningBuilder: true
              )
              : .none
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { plan in
      Text(plan.action.confirmationMessage(for: plan.builder))
    }
    .confirmationDialog(
      "Reset the NativeContainers local cache?",
      isPresented: $isConfirmingAppOwnedCacheReset
    ) {
      Button("Reset Local Cache", role: .destructive) {
        startOperation { _ = await appOwnedCacheModel.reset() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes only NativeContainers’ private local build cache. It does not stop or recreate Apple’s shared builder, remove its internal cache, or delete build outputs."
      )
    }
    .onDisappear {
      operationTask?.cancel()
      model.discardPlan()
    }
  }

  private func refresh() async {
    await model.load()
    await appOwnedCacheModel.load()
  }

  private var reviewIsPresented: Binding<Bool> {
    Binding(
      get: { reviewedAction != nil },
      set: { isPresented in
        guard !isPresented else { return }
        reviewedAction = nil
        model.discardPlan()
      }
    )
  }

  private func review(_ action: ContainerBuilderManagementAction) {
    startOperation {
      if await model.prepare(action) != nil {
        reviewedAction = action
      }
    }
  }

  private func startOperation(
    _ operation: @escaping @MainActor () async -> Void
  ) {
    guard operationTask == nil else { return }
    operationTask = Task { @MainActor in
      defer { operationTask = nil }
      await operation()
    }
  }
}

private struct AppOwnedBuildCacheSection: View {
  let model: AppOwnedBuildCacheModel
  let reset: () -> Void

  var body: some View {
    Section("NativeContainers local cache") {
      if model.isLoading, model.snapshot == nil {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Inspecting the app-owned cache…")
        }
      } else if let snapshot = model.snapshot {
        LabeledContent(
          "Allocated size",
          value: snapshot.byteCount.formatted(.byteCount(style: .file))
        )
        LabeledContent("Entries", value: snapshot.entryCount.formatted())
        if let warning = snapshot.maintenanceWarning {
          Label(warning, systemImage: "wrench.and.screwdriver")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Button("Reset Local Cache…", systemImage: "trash", role: .destructive) {
          reset()
        }
        .disabled(model.isBusy)
      } else if model.errorMessage != nil {
        Label("Cache inspection failed", systemImage: "externaldrive.badge.exclamationmark")
          .foregroundStyle(.orange)
        Button("Reset Local Cache…", systemImage: "trash", role: .destructive) {
          reset()
        }
        .disabled(model.isBusy)
      } else {
        Label("No app-owned cache", systemImage: "externaldrive")
          .foregroundStyle(.secondary)
      }
      if let warning = model.maintenanceWarning {
        Label(warning, systemImage: "wrench.and.screwdriver")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Text(
        "This cache is separate from Apple’s shared builder. Incomplete cache work is reclaimed automatically, and a committed generation stays valid if later output delivery fails."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct ContainerBuilderSummarySection: View {
  let inspection: ContainerBuilderInspection

  var body: some View {
    Section("Shared BuildKit builder") {
      LabeledContent("Status") {
        Label(inspection.builder.state.title, systemImage: inspection.builder.state.systemImage)
          .foregroundStyle(inspection.builder.state.tint)
      }

      if inspection.builder.isPresent {
        if let imageReference = inspection.builder.imageReference {
          LabeledContent("Image", value: imageReference)
        }
        if let digest = inspection.builder.imageDigest {
          LabeledContent("Image digest") {
            Text(digest)
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
        }
        if let cpuCount = inspection.builder.cpuCount,
          let memoryBytes = inspection.builder.memoryBytes
        {
          LabeledContent(
            "Resources",
            value:
              "\(cpuCount) CPUs, \(Int64(clamping: memoryBytes).formatted(.byteCount(style: .memory)))"
          )
        }
        if let allocatedBytes = inspection.builder.allocatedBytes {
          LabeledContent(
            "Allocated storage",
            value: Int64(clamping: allocatedBytes).formatted(.byteCount(style: .file))
          )
        } else {
          LabeledContent("Allocated storage", value: "Unavailable")
        }
        if let createdAt = inspection.builder.createdAt {
          LabeledContent(
            "Created",
            value: createdAt.formatted(date: .abbreviated, time: .shortened)
          )
        }

        Text(
          "Allocated storage is the whole builder bundle. Apple’s native API does not expose a cache-only size."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ContainerBuilderSafetySection: View {
  let builder: ContainerBuilderRecord

  var body: some View {
    Section("Safety") {
      if builder.hasOrphanedBundle {
        Label(
          "The runtime no longer lists the builder, but its bundle remains on disk. NativeContainers will not delete or replace it.",
          systemImage: "exclamationmark.octagon.fill"
        )
        .foregroundStyle(.red)
      } else if !builder.isPresent {
        Label("The shared builder has not been created.", systemImage: "shippingbox")
        Text("The next image build creates it automatically.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !builder.isTrustedBuilder {
        Label(
          "The container named “buildkit” does not exactly match Apple’s builder identity. Maintenance actions are disabled.",
          systemImage: "exclamationmark.octagon.fill"
        )
        .foregroundStyle(.red)
      } else {
        switch builder.state {
        case .running:
          Label(
            "Running does not mean idle. NativeContainers cannot detect an external container CLI build.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
        case .stopped:
          Label(
            "The stopped builder matches the reviewed Apple builder identity.",
            systemImage: "checkmark.shield.fill"
          )
          .foregroundStyle(.green)
        case .stopping, .unknown:
          Label(
            "Wait for a stable runtime state before maintenance.",
            systemImage: "clock.badge.exclamationmark"
          )
          .foregroundStyle(.orange)
        case .absent:
          EmptyView()
        }
      }
    }
  }
}

private struct ContainerBuilderActionsSection: View {
  let builder: ContainerBuilderRecord
  let isBusy: Bool
  let review: (ContainerBuilderManagementAction) -> Void

  var body: some View {
    if builder.isTrustedBuilder {
      switch builder.state {
      case .running:
        Section("Maintenance") {
          Button("Stop Builder…", systemImage: "stop.circle") {
            review(.stop)
          }
          Button("Force Stop…", systemImage: "xmark.octagon", role: .destructive) {
            review(.forceStop)
          }
          Text(
            "Stop sends TERM and Apple escalates to KILL after five seconds if needed. Force Stop sends KILL immediately. Either can interrupt an external CLI build."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .disabled(isBusy)
      case .stopped:
        Section("Maintenance") {
          Button(
            "Delete Builder & Internal Cache…",
            systemImage: "trash",
            role: .destructive
          ) {
            review(.deleteBuilderAndCache)
          }
          Text(
            "Deletion removes the stopped builder bundle and its BuildKit cache. Exported build artifacts are left intact, and the next build recreates the builder."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .disabled(isBusy)
      case .stopping, .unknown, .absent:
        EmptyView()
      }
    }
  }
}

private struct ContainerBuilderResultSection: View {
  let result: ContainerBuilderManagementResult

  var body: some View {
    Section("Last action") {
      Label(result.action.resultTitle, systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text(result.action.resultMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

extension ContainerBuilderRuntimeState {
  fileprivate var title: String {
    switch self {
    case .running: "Running"
    case .stopped: "Stopped"
    case .stopping: "Stopping"
    case .unknown: "Unknown"
    case .absent: "Not created"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .running: "play.circle.fill"
    case .stopped: "stop.circle.fill"
    case .stopping: "clock.fill"
    case .unknown: "questionmark.circle.fill"
    case .absent: "shippingbox"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .running: .green
    case .stopped, .absent: .secondary
    case .stopping, .unknown: .orange
    }
  }
}

extension ContainerBuilderManagementAction {
  fileprivate var confirmationTitle: String {
    switch self {
    case .stop: "Stop the shared builder?"
    case .forceStop: "Force stop the shared builder?"
    case .deleteBuilderAndCache: "Delete the builder and internal cache?"
    }
  }

  fileprivate var confirmationButtonTitle: String {
    switch self {
    case .stop: "Stop Builder"
    case .forceStop: "Force Stop with KILL"
    case .deleteBuilderAndCache: "Delete Builder & Internal Cache"
    }
  }

  fileprivate var requiresInterruptionAuthorization: Bool {
    self == .stop || self == .forceStop
  }

  fileprivate func confirmationMessage(for builder: ContainerBuilderRecord) -> String {
    switch self {
    case .stop:
      "This can interrupt an external container CLI build. Apple sends TERM, waits up to five seconds, then automatically sends KILL if the builder does not exit."
    case .forceStop:
      "This immediately sends KILL and can interrupt an external container CLI build."
    case .deleteBuilderAndCache:
      "This deletes the exact reviewed stopped builder bundle and all of its BuildKit cache (\(builder.allocatedStorageDescription)). Exported artifacts remain, and the next build recreates the builder."
    }
  }

  fileprivate var resultTitle: String {
    switch self {
    case .stop: "Builder stopped"
    case .forceStop: "Builder force stopped"
    case .deleteBuilderAndCache: "Builder and cache deleted"
    }
  }

  fileprivate var resultMessage: String {
    switch self {
    case .stop, .forceStop:
      "The reviewed builder is stopped and can be deleted or restarted by the next build."
    case .deleteBuilderAndCache:
      "The builder is absent. The next image build creates a fresh builder."
    }
  }
}

extension ContainerBuilderRecord {
  fileprivate var allocatedStorageDescription: String {
    allocatedBytes.map {
      Int64(clamping: $0).formatted(.byteCount(style: .file))
    } ?? "size unavailable"
  }
}

private struct ContainerBuilderPreviewService: ContainerBuilderManaging {
  func loadBuilder() async throws -> ContainerBuilderInspection {
    let safety = ContainerBuilderSafetySnapshot(
      state: .running,
      identity: nil,
      configuration: nil
    )
    return ContainerBuilderInspection(
      builder: ContainerBuilderRecord(
        state: .running,
        createdAt: Date().addingTimeInterval(-86_400),
        imageReference: "ghcr.io/apple/container-builder-shim/builder:0.12.0",
        imageDigest: "sha256:0123456789abcdef",
        cpuCount: 2,
        memoryBytes: 2 * 1_073_741_824,
        allocatedBytes: 530_751_488,
        identityMismatches: [],
        bundlePresent: true
      ),
      reviewedSnapshot: ContainerBuilderReviewedSnapshot(
        creationDate: Date().addingTimeInterval(-86_400),
        safety: safety
      ),
      runtimeApplicationRoot: "/Users/example/Library/Application Support/com.apple.container"
    )
  }
}

private struct AppOwnedBuildCachePreviewService: AppOwnedBuildCacheManaging {
  func loadCache() async throws -> AppOwnedBuildCacheSnapshot? {
    AppOwnedBuildCacheSnapshot(byteCount: 786_432_000, entryCount: 2_418)
  }

  func resetCache() async throws -> AppOwnedBuildCacheResetReceipt {
    AppOwnedBuildCacheResetReceipt()
  }
}

#Preview("Builder and cache") {
  NavigationStack {
    ContainerBuilderManagementView(
      model: ContainerBuilderManagementModel(service: ContainerBuilderPreviewService()),
      appOwnedCacheModel: AppOwnedBuildCacheModel(
        service: AppOwnedBuildCachePreviewService()
      )
    )
  }
  .frame(width: 760, height: 620)
}
