import SwiftUI

struct VirtualMachineStorageReclamationReviewSheet: View {
  @Bindable var model: VirtualMachineStorageReclamationModel
  @Environment(\.dismiss) private var dismiss
  @State private var isConfirming = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VirtualMachineReclamationBoundarySection()
          if model.result == nil {
            VirtualMachineReclamationScopeSection(model: model)
          }

          if model.isPreparing {
            VirtualMachineReclamationProgressSection(
              title: model.isCancelling
                ? "Cancelling scan…"
                : "Scanning exact VM artifacts…",
              detail: model.isCancelling
                ? "Finishing the current safe inspection."
                : "Acquiring short-lived library and VM leases."
            )
          } else if model.isReclaiming {
            VirtualMachineReclamationProgressSection(
              title: model.isCancelling
                ? "Finishing committed cleanup…"
                : "Reclaiming reviewed VM storage…",
              detail:
                "Committed removals stay removed; changed or active items are skipped."
            )
          } else if let plan = model.plan {
            VirtualMachineReclamationPlanSection(plan: plan)
          } else if let result = model.result {
            VirtualMachineReclamationResultSection(result: result)
          } else if model.errorMessage == nil {
            ContentUnavailableView(
              "No review is loaded",
              systemImage: "internaldrive",
              description: Text("Measure VM storage, then scan again.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          }

          if let message = model.errorMessage {
            VirtualMachineReclamationMessageSection(message: message)
          }
        }
        .padding(20)
      }
      .navigationTitle("VM Storage Reclamation")
      .frame(minWidth: 720, minHeight: 610)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.isWorking {
            Button(
              model.isReclaiming ? "Cancel Remaining" : "Cancel Scan",
              role: .cancel
            ) {
              model.cancelCurrentOperation()
            }
            .disabled(model.isCancelling)
          } else {
            Button("Close", role: .cancel) {
              dismiss()
            }
            .keyboardShortcut(.cancelAction)
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          if let plan = model.plan, !plan.isEmpty, model.result == nil {
            Button(
              "Reclaim \(plan.candidateCount) Item\(plan.candidateCount == 1 ? "" : "s")…",
              role: .destructive
            ) {
              isConfirming = true
            }
            .disabled(model.isWorking)
          } else if model.plan == nil, model.result == nil, !model.isWorking {
            Button("Scan Again") {
              model.startPreparing()
            }
            .disabled(!model.hasSelectedScope)
          }
        }
      }
    }
    .interactiveDismissDisabled(model.isWorking)
    .confirmationDialog(
      confirmationTitle,
      isPresented: $isConfirming,
      titleVisibility: .visible
    ) {
      if let plan = model.plan {
        Button(
          "Reclaim \(plan.candidateCount) Reviewed Item\(plan.candidateCount == 1 ? "" : "s")",
          role: .destructive
        ) {
          model.startReclaiming()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Saved states cannot be recovered. Only the exact reviewed app-owned artifacts are eligible; active, replaced, or changed items are skipped. VM disks and restore images are never touched."
      )
    }
  }

  private var confirmationTitle: String {
    guard let plan = model.plan else {
      return "Permanently reclaim reviewed VM storage?"
    }
    return
      "Permanently reclaim \(plan.candidateCount) reviewed item\(plan.candidateCount == 1 ? "" : "s")?"
  }
}

private struct VirtualMachineReclamationScopeSection: View {
  @Bindable var model: VirtualMachineStorageReclamationModel

  var body: some View {
    VirtualMachineReclamationCard {
      Text("Review scope")
        .font(.headline)

      Toggle(
        "Saved states (\(model.measuredSavedStateCount))",
        isOn: Binding(
          get: { model.reclaimSavedStates },
          set: { model.setReclaimSavedStates($0) }
        )
      )
      .disabled(model.measuredSavedStateCount == 0 || model.isWorking)

      Toggle(
        "Interrupted-operation residue",
        isOn: Binding(
          get: { model.reclaimInterruptedResidue },
          set: { model.setReclaimInterruptedResidue($0) }
        )
      )
      .disabled(model.isWorking)

      Text(
        "Changing scope discards the current plan. Scan again to review the new exact candidate set."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct VirtualMachineReclamationBoundarySection: View {
  var body: some View {
    VirtualMachineReclamationCard {
      Label("Exact reviewed cleanup", systemImage: "checkmark.shield")
        .font(.headline)
      Text(
        "This pass can discard committed same-host saved states and exact allowlisted residue from interrupted app operations. It never starts, stops, force-stops, or kills a VM."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          boundaryLabel("No disk compaction", systemImage: "internaldrive")
          boundaryLabel("No restore-image deletion", systemImage: "arrow.down.doc")
          boundaryLabel("Commit-time revalidation", systemImage: "arrow.triangle.2.circlepath")
        }
        VStack(alignment: .leading, spacing: 8) {
          boundaryLabel("No disk compaction", systemImage: "internaldrive")
          boundaryLabel("No restore-image deletion", systemImage: "arrow.down.doc")
          boundaryLabel("Commit-time revalidation", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func boundaryLabel(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
  }
}

private struct VirtualMachineReclamationProgressSection: View {
  let title: LocalizedStringKey
  let detail: LocalizedStringKey

  var body: some View {
    VirtualMachineReclamationCard {
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct VirtualMachineReclamationPlanSection: View {
  let plan: VirtualMachineStorageReclamationPlan

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VirtualMachineReclamationCard {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Reviewed plan")
              .font(.headline)
            Text(
              "Generated \(plan.generatedAt.formatted(date: .abbreviated, time: .standard)) from the VM measurement captured \(plan.request.source.capturedAt.formatted(date: .abbreviated, time: .standard))."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(plan.candidateCount)")
              .font(.title2.bold().monospacedDigit())
            Text("exact candidates")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        LabeledContent("Estimated allocated bytes") {
          Text(StorageByteFormatter.string(from: plan.estimatedAllocatedBytes))
            .monospacedDigit()
        }
        .font(.callout)

        Text(
          "Allocated bytes are a filesystem estimate. APFS sharing means host free-space growth may be smaller."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if plan.isEmpty {
        ContentUnavailableView(
          "Nothing eligible was found",
          systemImage: "checkmark.circle",
          description: Text(
            "No selected saved state or exact interrupted-operation residue is currently reclaimable."
          )
        )
        .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        if let savedStates = plan.savedStatePlan?.candidates,
          !savedStates.isEmpty
        {
          VirtualMachineSavedStateCandidateSection(candidates: savedStates)
        }

        if let residue = plan.residuePlan?.candidates, !residue.isEmpty {
          VirtualMachineResidueCandidateSection(candidates: residue)
        }
      }

      if !plan.issues.isEmpty {
        VirtualMachineReclamationIssueSection(issues: plan.issues)
      }
    }
  }
}

private struct VirtualMachineSavedStateCandidateSection: View {
  let candidates: [VirtualMachineSavedStateReclamationCandidate]

  var body: some View {
    VirtualMachineReclamationCard {
      Label("Saved states", systemImage: "memorychip")
        .font(.headline)

      ForEach(candidates) { candidate in
        Divider()
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(candidate.machineName)
              .fontWeight(.semibold)
            Text(candidate.machineID.uuidString.lowercased())
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .textSelection(.enabled)
            Text(
              "Created \(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Text(
            StorageByteFormatter.string(
              from: candidate.estimatedAllocatedBytes
            )
          )
          .monospacedDigit()
        }
      }
    }
  }
}

private struct VirtualMachineResidueCandidateSection: View {
  let candidates: [VirtualMachineStorageResidueCandidate]

  var body: some View {
    VirtualMachineReclamationCard {
      Label("Interrupted-operation residue", systemImage: "shippingbox.and.arrow.backward")
        .font(.headline)

      ForEach(candidates) { candidate in
        Divider()
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: candidate.kind.title))
              .fontWeight(.semibold)
            Text(candidate.machineName ?? "VM library")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(candidate.entryName)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .textSelection(.enabled)
              .lineLimit(2)
          }
          Spacer()
          Text(
            StorageByteFormatter.string(
              from: candidate.estimatedAllocatedBytes
            )
          )
          .monospacedDigit()
        }
      }
    }
  }
}

private struct VirtualMachineReclamationIssueSection: View {
  let issues: [VirtualMachineStorageReclamationPlanningIssue]

  var body: some View {
    VirtualMachineReclamationCard {
      Label("Preserved items", systemImage: "exclamationmark.shield")
        .font(.headline)
      Text(
        "These items were not added to the reviewed plan because ownership, safety, or lease checks did not pass."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ForEach(issues) { issue in
        Divider()
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct VirtualMachineReclamationResultSection: View {
  let result: VirtualMachineStorageReclamationResult

  var body: some View {
    VirtualMachineReclamationCard {
      Label(
        result.failedCandidateCount == 0 && result.staleCandidateCount == 0
          ? "Reclamation complete"
          : "Reclamation completed with preserved items",
        systemImage:
          result.failedCandidateCount == 0 && result.staleCandidateCount == 0
          ? "checkmark.circle.fill"
          : "exclamationmark.triangle.fill"
      )
      .font(.headline)

      LabeledContent("Removed") {
        Text("\(result.removedCandidateCount)")
          .monospacedDigit()
      }
      LabeledContent("Changed or stale") {
        Text("\(result.staleCandidateCount)")
          .monospacedDigit()
      }
      LabeledContent("Failed") {
        Text("\(result.failedCandidateCount)")
          .monospacedDigit()
      }
      LabeledContent("Estimated removed allocation") {
        Text(
          StorageByteFormatter.string(from: result.removedAllocatedBytes)
        )
        .monospacedDigit()
      }
    }
  }
}

private struct VirtualMachineReclamationMessageSection: View {
  let message: String

  var body: some View {
    VirtualMachineReclamationCard {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
    }
  }
}

private struct VirtualMachineReclamationCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct PreviewVirtualMachineReclamationService:
  VirtualMachineStorageReclamationManaging
{
  func prepareVirtualMachineStorageReclamation(
    _ request: VirtualMachineStorageReclamationRequest
  ) async throws -> VirtualMachineStorageReclamationPlan {
    throw VirtualMachineStorageReclamationError.unavailable
  }

  func reclaimVirtualMachineStorage(
    _ plan: VirtualMachineStorageReclamationPlan
  ) async throws -> VirtualMachineStorageReclamationResult {
    throw VirtualMachineStorageReclamationError.unavailable
  }
}

private enum VirtualMachineReclamationPreviewData {
  static let machineID = UUID(
    uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  )!
  static let source = VirtualMachineStorageReclamationSource(
    capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
    measurementRevision: 4,
    libraryRevision: 7,
    measuredSavedStateMachineIDs: [machineID]
  )
  static let identity = VirtualMachineStorageArtifactIdentity(
    device: 1,
    inode: 2,
    fileType: .directory,
    ownerUserID: 501,
    linkCount: 2,
    logicalBytes: 6_442_450_944,
    allocatedBytes: 3_221_225_472,
    entryCount: 3,
    modificationSeconds: 1,
    modificationNanoseconds: 2,
    statusChangeSeconds: 3,
    statusChangeNanoseconds: 4,
    treeFingerprint: String(repeating: "a", count: 64)
  )
  static let plan = VirtualMachineStorageReclamationPlan(
    request: VirtualMachineStorageReclamationRequest(source: source),
    generatedAt: Date(timeIntervalSince1970: 1_750_000_060),
    savedStatePlan: VirtualMachineSavedStateReclamationPlan(
      candidates: [
        VirtualMachineSavedStateReclamationCandidate(
          machineID: machineID,
          machineName:
            "macOS Development Environment With A Deliberately Long Name",
          createdAt: Date(timeIntervalSince1970: 1_749_999_000),
          stateSizeBytes: 6_442_450_944,
          configurationFingerprint: String(repeating: "b", count: 64),
          artifactIdentity: identity
        )
      ],
      issues: []
    ),
    residuePlan: VirtualMachineStorageResidueReclamationPlan(
      candidates: [
        VirtualMachineStorageResidueCandidate(
          id: "library-residue:.Clone-preview.partial",
          kind: .cloneStaging,
          entryName:
            ".Clone-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-11111111-2222-3333-4444-555555555555.partial",
          machineID: nil,
          machineName: nil,
          manifestFingerprint: nil,
          artifactIdentity: VirtualMachineStorageArtifactIdentity(
            device: 1,
            inode: 8,
            fileType: .directory,
            ownerUserID: 501,
            linkCount: 2,
            logicalBytes: 10,
            allocatedBytes: 4_096,
            entryCount: 2,
            modificationSeconds: 1,
            modificationNanoseconds: 2,
            statusChangeSeconds: 3,
            statusChangeNanoseconds: 4,
            treeFingerprint: String(repeating: "c", count: 64)
          )
        )
      ],
      issues: [
        VirtualMachineStorageReclamationPlanningIssue(
          id: "preview-issue",
          category: .interruptedResidue,
          machineID: machineID,
          message:
            "A changed shared-folder staging file was preserved because its filesystem identity no longer matched."
        )
      ]
    )
  )
  static let emptyPlan = VirtualMachineStorageReclamationPlan(
    request: VirtualMachineStorageReclamationRequest(source: source),
    generatedAt: Date(timeIntervalSince1970: 1_750_000_060),
    savedStatePlan: VirtualMachineSavedStateReclamationPlan(
      candidates: [],
      issues: []
    ),
    residuePlan: VirtualMachineStorageResidueReclamationPlan(
      candidates: [],
      issues: []
    )
  )
  static let partialResult = VirtualMachineStorageReclamationResult(
    savedStateResult: VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: ["saved-state:\(machineID.uuidString)"],
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: identity.allocatedBytes
    ),
    residueResult: VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: [],
      staleCandidateIDs: ["library-residue:.Clone-preview.partial"],
      failedCandidates: [],
      removedAllocatedBytes: 0
    ),
    categoryFailures: []
  )
}

#Preview("VM Reclamation – Reviewing") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      plan: VirtualMachineReclamationPreviewData.plan
    )
  )
}

#Preview("VM Reclamation – Reviewing Dark") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      plan: VirtualMachineReclamationPreviewData.plan
    )
  )
  .environment(\.colorScheme, .dark)
}

#Preview("VM Reclamation – Large Text") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      plan: VirtualMachineReclamationPreviewData.plan
    )
  )
  .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("VM Reclamation – Preparing") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      isPreparing: true
    )
  )
}

#Preview("VM Reclamation – Empty") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      plan: VirtualMachineReclamationPreviewData.emptyPlan
    )
  )
}

#Preview("VM Reclamation – Partial Result") {
  VirtualMachineStorageReclamationReviewSheet(
    model: VirtualMachineStorageReclamationModel(
      service: PreviewVirtualMachineReclamationService(),
      currentSource: { VirtualMachineReclamationPreviewData.source },
      result: VirtualMachineReclamationPreviewData.partialResult,
      errorMessage:
        "One reviewed item changed after review and was preserved."
    )
  )
}
