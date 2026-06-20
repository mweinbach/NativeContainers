import SwiftUI

struct ImageTagView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ImageOperationsModel
  @State private var target = ""
  @State private var isConfirmingReplacement = false

  init(reference: String, appModel: AppModel) {
    _model = State(initialValue: appModel.makeImageOperations(reference: reference))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("New reference") {
          TextField("Reference", text: $target, prompt: Text("example/app:release"))
          Text("Unqualified names use Apple container’s configured default registry.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
        if model.isWorking {
          Section { ProgressView("Checking image references…") }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("Tag Image")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Tag") {
            Task {
              guard let plan = await model.prepareTag(target: target) else { return }
              if plan.replacesDifferentImage {
                isConfirmingReplacement = true
              } else if await model.applyTag(replacingExisting: false) {
                dismiss()
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .frame(minWidth: 520, minHeight: 300)
    .interactiveDismissDisabled(model.isWorking)
    .confirmationDialog(
      "Replace existing tag?",
      isPresented: $isConfirmingReplacement,
      presenting: model.tagPlan
    ) { plan in
      Button("Replace \(plan.displayTargetReference)", role: .destructive) {
        Task {
          if await model.applyTag(replacingExisting: true) {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {
        model.clearPlans()
      }
    } message: { plan in
      Text(
        "That tag points to a different digest. Replacing it moves the mutable reference to this image."
      )
    }
  }
}

struct ImagePruneView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ImageOperationsModel
  @State private var mode = ImagePruneMode.dangling
  @State private var isConfirmingPrune = false

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeImageOperations())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Scope") {
          Picker("Images", selection: $mode) {
            ForEach(ImagePruneMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          Text(mode.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let plan = model.prunePlan {
          Section("Review") {
            if plan.candidates.isEmpty {
              Label("No matching images are safe to prune.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              ForEach(plan.candidates) { candidate in
                VStack(alignment: .leading, spacing: 3) {
                  Text(candidate.reference)
                  Text(candidate.digest)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              if let estimate = plan.estimatedReclaimableBytes {
                LabeledContent(
                  "Estimated reclaimable",
                  value: estimate.formatted(.byteCount(style: .file))
                )
              }
              Text(
                "Candidates are revalidated immediately before deletion. New or active images are never added to this reviewed set."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }

        if let result = model.cleanupResult {
          Section("Result") {
            LabeledContent("References removed", value: result.removedReferences.count.formatted())
            LabeledContent(
              "Space reclaimed",
              value: result.reclaimedBytes.formatted(.byteCount(style: .file))
            )
            if !result.failedReferences.isEmpty {
              ForEach(result.failedReferences) { failure in
                Label(
                  "\(failure.reference): \(failure.message)",
                  systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
              }
            }
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if model.isWorking {
          Section { ProgressView("Working with Apple’s image store…") }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("Prune Images")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if let plan = model.prunePlan, !plan.candidates.isEmpty {
            Button("Prune \(plan.candidates.count) Images", role: .destructive) {
              isConfirmingPrune = true
            }
          } else {
            Button("Scan") {
              Task { _ = await model.preparePrune(mode: mode) }
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    }
    .frame(minWidth: 620, minHeight: 520)
    .interactiveDismissDisabled(model.isWorking)
    .onChange(of: mode) {
      model.resetReview()
    }
    .confirmationDialog(
      "Prune reviewed images?",
      isPresented: $isConfirmingPrune,
      presenting: model.prunePlan
    ) { plan in
      Button("Prune \(plan.candidates.count) Images", role: .destructive) {
        Task { _ = await model.pruneReviewedImages() }
      }
      Button("Cancel", role: .cancel) {}
    } message: { plan in
      Text(
        "This removes the reviewed references and then asks Apple’s image service to reclaim blobs no longer used by any remaining reference."
      )
    }
  }
}
