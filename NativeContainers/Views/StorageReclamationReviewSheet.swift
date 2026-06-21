import SwiftUI

struct StorageReclamationReviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: StorageReclamationModel
  @State private var isConfirming = false

  var body: some View {
    NavigationStack {
      Form {
        StorageReclamationScopeSection(model: model)

        if model.isPreparing {
          StorageReclamationProgressSection(
            title: model.isCancelling
              ? "Cancelling scan…"
              : "Scanning exact reclaimable candidates…",
            detail: model.isCancelling
              ? "Closing the active request and waiting for it to finish."
              : "Live runtime data is checked independently from the accounting estimate."
          )
        }

        if let plan = model.plan {
          StorageReclamationPlanSummarySection(plan: plan)
          ContainerReclamationCandidatesSection(plan: plan.containerPlan)
          ImageReclamationCandidatesSection(plan: plan.imagePlan)
          VolumeReclamationCandidatesSection(plan: plan.volumePlan)
        }

        if model.isReclaiming {
          StorageReclamationProgressSection(
            title: model.isCancelling
              ? "Finishing current removal and reconciling…"
              : "Revalidating and reclaiming reviewed storage…",
            detail:
              "Cancellation stops before the next candidate. A committed removal is reconciled and never rolled back."
          )
        }

        if let result = model.result {
          StorageReclamationResultSection(result: result)
        }

        if let errorMessage = model.errorMessage {
          Section("Status") {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Review Apple Runtime Reclamation")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          cancellationToolbarItem
        }

        ToolbarItem(placement: .confirmationAction) {
          confirmationToolbarItem
        }
      }
    }
    .frame(minWidth: 680, minHeight: 620)
    .interactiveDismissDisabled(model.isWorking)
    .onDisappear {
      model.discardReview()
    }
    .confirmationDialog(
      "Permanently reclaim storage from these reviewed items?",
      isPresented: $isConfirming,
      presenting: model.plan
    ) { plan in
      Button(role: .destructive) {
        model.startReclaiming()
      } label: {
        Text(
          "Reclaim \(plan.candidateCount) Reviewed Items",
          comment: "Destructive confirmation button for deleting reviewed local runtime storage."
        )
      }
      Button("Cancel", role: .cancel) {}
    } message: { plan in
      Text(
        "Unused image references can be downloaded again. Selected stopped containers and unreferenced volumes, including their writable data, cannot be recovered. Changed or active items are skipped, and no new candidates are added."
      )
    }
  }

  @ViewBuilder
  private var cancellationToolbarItem: some View {
    if model.isWorking {
      Button(
        model.isCancelling
          ? "Cancelling…"
          : (model.isPreparing ? "Cancel Scan" : "Cancel Remaining"),
        role: .cancel
      ) {
        model.cancelCurrentOperation()
      }
      .disabled(model.isCancelling)
      .keyboardShortcut(.cancelAction)
    } else {
      Button(model.result == nil ? "Close" : "Done") {
        model.discardReview()
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var confirmationToolbarItem: some View {
    if let plan = model.plan,
      !plan.isEmpty,
      model.result == nil,
      !model.isWorking
    {
      Button(role: .destructive) {
        isConfirming = true
      } label: {
        Text(
          "Reclaim \(plan.candidateCount) Items",
          comment: "Opens a final destructive confirmation for reviewed storage candidates."
        )
      }
    } else if model.plan == nil,
      model.result == nil,
      !model.isWorking
    {
      Button("Scan Again") {
        model.startPreparing()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.hasSelectedScope)
    }
  }
}

private struct StorageReclamationScopeSection: View {
  @Bindable var model: StorageReclamationModel

  var body: some View {
    Section("Scope") {
      Toggle(
        "Unused image references",
        isOn: Binding(
          get: { model.reclaimImages },
          set: { model.setReclaimImages($0) }
        )
      )
      Toggle(
        "Unreferenced local volumes",
        isOn: Binding(
          get: { model.reclaimVolumes },
          set: { model.setReclaimVolumes($0) }
        )
      )
      Toggle(
        "Stopped NativeContainers app containers",
        isOn: Binding(
          get: { model.reclaimContainers },
          set: { model.setReclaimContainers($0) }
        )
      )

      Text(
        "Stopped containers are opt-in. Reclamation never stops, kills, or force-deletes a container. Compose, builder, machine, Apple-managed, running, stopping, unknown, and unowned containers are always preserved."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(
        "VM bundles, saved states, restore images, builder caches, and unknown files are outside this operation."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .disabled(model.isWorking || model.result != nil)
  }
}

private struct StorageReclamationProgressSection: View {
  let title: String
  let detail: String

  var body: some View {
    Section {
      ProgressView(title)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct StorageReclamationPlanSummarySection: View {
  let plan: StorageReclamationPlan

  var body: some View {
    Section("Review") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Candidates", value: plan.candidateCount.formatted())
        LabeledContent {
          Text(
            plan.knownEstimatedReclaimableBytes.formatted(
              .byteCount(style: .file)
            )
          )
        } label: {
          Text(
            plan.hasCompleteEstimate
              ? "Candidate estimate"
              : "Known candidate estimate"
          )
        }
        LabeledContent(
          "Apple runtime estimate",
          value: appleRuntimeEstimate.formatted(.byteCount(style: .file))
        )
        LabeledContent {
          Text(
            plan.request.source.appleRuntimeCapturedAt,
            format: .dateTime.year().month().day().hour().minute().second()
          )
        } label: {
          Text("Accounting captured")
        }
        LabeledContent {
          Text(
            plan.generatedAt,
            format: .dateTime.year().month().day().hour().minute().second()
          )
        } label: {
          Text("Candidates scanned")
        }

        if plan.isEmpty {
          Label(
            "No matching storage is currently safe to reclaim.",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(.green)
        } else {
          Text(
            "The accounting snapshot is context, not authorization. Execution checks every listed identity again, never adds candidates, and requires another Measure → Review loop for dependencies freed by container deletion."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var appleRuntimeEstimate: UInt64 {
    let source = plan.request.source
    var values: [UInt64] = []
    if plan.request.reclaimContainers {
      values.append(source.containers.reclaimableBytes)
    }
    if plan.request.reclaimImages {
      values.append(source.images.reclaimableBytes)
    }
    if plan.request.reclaimVolumes {
      values.append(source.volumes.reclaimableBytes)
    }
    return StorageByteMath.saturatingSum(values)
  }
}

private struct ContainerReclamationCandidatesSection: View {
  let plan: ContainerPrunePlan?

  @ViewBuilder
  var body: some View {
    if let plan, !plan.candidates.isEmpty {
      Section("Stopped App Containers (\(plan.candidates.count))") {
        ForEach(plan.candidates) { candidate in
          VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
              CandidateSizeText(bytes: candidate.allocatedBytes)
            } label: {
              Text(candidate.id)
                .fontWeight(.medium)
            }
            Text(candidate.imageReference)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Text("Created \(candidate.createdAt, format: .relative(presentation: .named))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

private struct ImageReclamationCandidatesSection: View {
  let plan: ImagePrunePlan?

  @ViewBuilder
  var body: some View {
    if let plan, !plan.candidates.isEmpty {
      Section("Unused Images (\(plan.candidates.count))") {
        if let estimate = plan.estimatedReclaimableBytes {
          LabeledContent(
            "Shared-content estimate",
            value: estimate.formatted(.byteCount(style: .file))
          )
        }
        ForEach(plan.candidates) { candidate in
          VStack(alignment: .leading, spacing: 3) {
            Text(candidate.reference)
              .fontWeight(.medium)
            Text(candidate.digest)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

private struct VolumeReclamationCandidatesSection: View {
  let plan: VolumePrunePlan?

  @ViewBuilder
  var body: some View {
    if let plan, !plan.candidates.isEmpty {
      Section("Unused Volumes (\(plan.candidates.count))") {
        ForEach(plan.candidates, id: \.volume.id) { candidate in
          LabeledContent {
            CandidateSizeText(bytes: candidate.volume.allocatedBytes)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.volume.name)
                .fontWeight(.medium)
              Text(
                "\(candidate.volume.driver) · \(candidate.volume.format) · \(candidate.volume.id)"
              )
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
            }
          }
        }
      }
    }
  }
}

private struct CandidateSizeText: View {
  let bytes: UInt64?

  var body: some View {
    if let bytes {
      Text(bytes.formatted(.byteCount(style: .file)))
        .monospacedDigit()
        .accessibilityLabel("\(bytes.formatted()) bytes")
    } else {
      Text("Unknown size")
        .foregroundStyle(.secondary)
    }
  }
}

private struct StorageReclamationResultSection: View {
  let result: StorageReclamationResult

  var body: some View {
    Section("Result") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent(
          "Items removed",
          value: result.removedCandidateCount.formatted()
        )
        LabeledContent(
          "Estimated/reported removed bytes",
          value: result.reportedRemovedBytes.formatted(.byteCount(style: .file))
        )

        if let containers = result.containerResult {
          LabeledContent(
            "Containers removed",
            value: containers.removedContainerIDs.count.formatted()
          )
          ForEach(containers.failedContainers) { failure in
            ReclamationFailureRow(
              title: failure.resource,
              message: failure.message
            )
          }
        }

        if let images = result.imageResult {
          LabeledContent(
            "Image references removed",
            value: images.removedReferences.count.formatted()
          )
          ForEach(images.failedReferences) { failure in
            ReclamationFailureRow(
              title: failure.reference,
              message: failure.message
            )
          }
        }

        if let volumes = result.volumeResult {
          LabeledContent(
            "Volumes removed",
            value: volumes.removedResourceNames.count.formatted()
          )
          ForEach(volumes.failedResources) { failure in
            ReclamationFailureRow(
              title: failure.resource,
              message: failure.message
            )
          }
        }

        ForEach(result.categoryFailures) { failure in
          ReclamationFailureRow(
            title: String(localized: failure.category.title),
            message: failure.message
          )
        }

        if result.completedWithoutFailures {
          Label("Every reviewed candidate was handled.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Text("Measure and review again before retrying skipped or cancelled work.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(
          "Image bytes are reported by Apple’s content cleanup. Container and volume bytes are pre-removal allocation measurements, not a measured host free-space increase."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ReclamationFailureRow: View {
  let title: String
  let message: String

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)
        Text(message)
          .font(.caption)
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle")
    }
    .foregroundStyle(.orange)
  }
}

private struct PreviewStorageReclamationService:
  StorageReclamationManaging
{
  func prepareStorageReclamation(
    _ request: StorageReclamationRequest
  ) async throws -> StorageReclamationPlan {
    throw StorageReclamationError.unavailable
  }

  func reclaimStorage(
    _ plan: StorageReclamationPlan
  ) async throws -> StorageReclamationResult {
    throw StorageReclamationError.unavailable
  }
}

private enum StorageReclamationPreviewData {
  static let source = StorageReclamationSource(
    appleRuntimeCapturedAt: .now.addingTimeInterval(-30),
    appleRuntimeRevision: 4,
    inventoryRevision: 9,
    images: StorageResourceUsage(
      totalCount: 5,
      activeCount: 3,
      allocatedBytes: 4_000_000_000,
      reclaimableBytes: 820_000_000
    ),
    containers: StorageResourceUsage(
      totalCount: 3,
      activeCount: 2,
      allocatedBytes: 2_000_000_000,
      reclaimableBytes: 240_000_000
    ),
    volumes: StorageResourceUsage(
      totalCount: 3,
      activeCount: 1,
      allocatedBytes: 10_000_000_000,
      reclaimableBytes: 2_100_000_000
    )
  )

  static let request = StorageReclamationRequest(
    source: source,
    reclaimContainers: true
  )

  static let volume = VolumeRecord(
    id: "vol-archive-0123456789abcdef",
    name: "archive-cache",
    driver: "local",
    format: "ext4",
    source: "/private/var/archive-cache",
    createdAt: Date(timeIntervalSince1970: 1),
    sizeBytes: 8_000_000_000,
    allocatedBytes: 2_100_000_000,
    labels: [:],
    options: [:],
    isAnonymous: false,
    usedByContainerIDs: []
  )

  static let loadedPlan = StorageReclamationPlan(
    request: request,
    generatedAt: .now,
    containerPlan: ContainerPrunePlan(
      candidates: [
        ContainerPruneCandidate(
          id: "long-running-analysis-worker-that-is-now-stopped",
          ownershipID: UUID(),
          createdAt: .now.addingTimeInterval(-3_600),
          imageReference: "registry.example.com/analysis/worker:previous",
          imageDigest: "sha256:container",
          platform: "linux/arm64/v8",
          configurationSeal: Data("sealed".utf8),
          allocatedBytes: 240_000_000,
          hasPublishedSockets: false
        )
      ],
      generatedAt: .now
    ),
    imagePlan: ImagePrunePlan(
      mode: .allUnused,
      generatedAt: .now,
      candidates: [
        ImagePruneCandidate(
          reference: "registry.example.com/demo:old",
          digest: "sha256:0123456789abcdef0123456789abcdef",
          indexSizeBytes: 1_024
        )
      ],
      estimatedReclaimableBytes: 820_000_000
    ),
    volumePlan: VolumePrunePlan(
      candidates: [
        VolumeDeletionPlan(
          volume: volume,
          identity: volume.configurationIdentity,
          generatedAt: .now
        )
      ],
      generatedAt: .now
    )
  )

  static let emptyPlan = StorageReclamationPlan(
    request: StorageReclamationRequest(source: source),
    generatedAt: .now,
    containerPlan: nil,
    imagePlan: ImagePrunePlan(
      mode: .allUnused,
      generatedAt: .now,
      candidates: [],
      estimatedReclaimableBytes: 0
    ),
    volumePlan: VolumePrunePlan(candidates: [], generatedAt: .now)
  )

  static let partialResult = StorageReclamationResult(
    containerResult: ContainerCleanupResult(
      removedContainerIDs: ["old-worker"],
      failedContainers: [
        ResourceOperationFailure(
          resource: "changed-worker",
          message: "Changed or became active after review; skipped."
        )
      ],
      removedAllocatedBytes: 240_000_000
    ),
    imageResult: nil,
    volumeResult: nil,
    categoryFailures: []
  )
}

#Preview("Reclamation – Loaded") {
  StorageReclamationReviewSheet(
    model: StorageReclamationModel(
      service: PreviewStorageReclamationService(),
      currentSource: { StorageReclamationPreviewData.source },
      plan: StorageReclamationPreviewData.loadedPlan
    )
  )
}

#Preview("Reclamation – Loaded Dark") {
  StorageReclamationReviewSheet(
    model: StorageReclamationModel(
      service: PreviewStorageReclamationService(),
      currentSource: { StorageReclamationPreviewData.source },
      plan: StorageReclamationPreviewData.loadedPlan
    )
  )
  .preferredColorScheme(.dark)
}

#Preview("Reclamation – Empty") {
  StorageReclamationReviewSheet(
    model: StorageReclamationModel(
      service: PreviewStorageReclamationService(),
      currentSource: { StorageReclamationPreviewData.source },
      plan: StorageReclamationPreviewData.emptyPlan
    )
  )
}

#Preview("Reclamation – Cancelling") {
  StorageReclamationReviewSheet(
    model: StorageReclamationModel(
      service: PreviewStorageReclamationService(),
      currentSource: { StorageReclamationPreviewData.source },
      result: StorageReclamationPreviewData.partialResult,
      errorMessage: "Reclamation was cancelled after one confirmed removal."
    )
  )
  .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Reclamation – Preparing") {
  StorageReclamationReviewSheet(
    model: StorageReclamationModel(
      service: PreviewStorageReclamationService(),
      currentSource: { StorageReclamationPreviewData.source },
      isPreparing: true
    )
  )
  .frame(width: 700, height: 620)
}
