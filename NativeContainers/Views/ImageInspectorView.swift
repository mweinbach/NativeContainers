import SwiftUI

struct ImageInspectorView: View {
  let image: ImageRecord
  let appModel: AppModel
  @State private var inspector: ImageInspectorModel
  @State private var operations: ImageOperationsModel
  @State private var isShowingTag = false
  @State private var isShowingPush = false

  init(image: ImageRecord, appModel: AppModel) {
    self.image = image
    self.appModel = appModel
    _inspector = State(initialValue: appModel.makeImageInspector(reference: image.reference))
    _operations = State(initialValue: appModel.makeImageOperations(reference: image.reference))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header

        if inspector.isLoading, inspector.inspection == nil {
          ProgressView("Resolving OCI manifests and configuration…")
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let inspection = inspector.inspection {
          usage(inspection)
          aliases(inspection)
          variants(inspection)
          warnings(inspection)
        }

        if let error = inspector.errorMessage ?? operations.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(20)
    }
    .task(id: ImageInspectionRefreshID(image: image, inventoryRevision: appModel.lastRefresh)) {
      await inspector.load()
    }
    .sheet(isPresented: $isShowingTag) {
      ImageTagView(reference: image.reference, appModel: appModel)
    }
    .sheet(isPresented: $isShowingPush) {
      ImagePushView(reference: image.reference, appModel: appModel)
    }
    .confirmationDialog(
      "Delete image reference?",
      isPresented: Binding(
        get: { operations.deletionPlan != nil },
        set: { if !$0 { operations.clearPlans() } }
      ),
      presenting: operations.deletionPlan
    ) { plan in
      if plan.canDelete {
        Button("Delete \(plan.reference)", role: .destructive) {
          Task {
            _ = await operations.deleteReviewedImage(plan)
            operations.clearPlans()
          }
        }
      }
      Button("Cancel", role: .cancel) {
        operations.clearPlans()
      }
    } message: { plan in
      Text(deletionMessage(plan))
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.largeTitle)
        .foregroundStyle(.purple)
      VStack(alignment: .leading, spacing: 5) {
        Text(inspector.inspection?.displayReference ?? image.reference)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        Text(image.digest)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Tag", systemImage: "tag") {
        isShowingTag = true
      }
      Button("Push", systemImage: "arrow.up.to.line") {
        isShowingPush = true
      }
      Button("Delete", systemImage: "trash", role: .destructive) {
        Task { _ = await operations.prepareDeletion() }
      }
      .disabled(operations.isWorking)
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await inspector.load() }
      }
      .disabled(inspector.isLoading)
    }
  }

  @ViewBuilder
  private func usage(_ inspection: ImageInspection) -> some View {
    GroupBox("Usage") {
      VStack(alignment: .leading, spacing: 8) {
        if inspection.usedByContainerIDs.isEmpty {
          Label("Not referenced by a container", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Label(
            "Used by \(inspection.usedByContainerIDs.joined(separator: ", "))",
            systemImage: "shippingbox.fill"
          )
          .foregroundStyle(.orange)
        }
        LabeledContent("Media type", value: inspection.mediaType)
        LabeledContent(
          "Index descriptor",
          value: inspection.indexSizeBytes.formatted(.byteCount(style: .file))
        )
        if let createdAt = inspection.createdAt {
          LabeledContent(
            "Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func aliases(_ inspection: ImageInspection) -> some View {
    if !inspection.aliases.isEmpty {
      GroupBox("Other references to this digest") {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(inspection.aliases, id: \.self) { alias in
            Text(alias).font(.callout.monospaced()).textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func variants(_ inspection: ImageInspection) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Platform variants")
        .font(.headline)
      if inspection.variants.isEmpty {
        ContentUnavailableView(
          "No readable variants",
          systemImage: "exclamationmark.triangle",
          description: Text("The OCI index did not contain a readable platform manifest.")
        )
      } else {
        ForEach(inspection.variants) { variant in
          ImageVariantCard(variant: variant)
        }
      }
    }
  }

  @ViewBuilder
  private func warnings(_ inspection: ImageInspection) -> some View {
    if !inspection.warnings.isEmpty {
      GroupBox("Inspection warnings") {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(inspection.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func deletionMessage(_ plan: ImageDeletionPlan) -> String {
    if plan.isInfrastructureImage {
      return "This image is managed by Apple’s container runtime and is protected."
    }
    if !plan.usedByContainerIDs.isEmpty {
      return
        "This reference is used by \(plan.usedByContainerIDs.joined(separator: ", ")). Remove those containers before deleting it."
    }
    let aliasNote =
      plan.aliases.isEmpty
      ? "No other references point to this digest."
      : "Other references remain: \(plan.aliases.joined(separator: ", "))."
    return
      "Only the reference is removed first. Unreferenced blobs are reclaimed afterward. \(aliasNote)"
  }
}

private struct ImageVariantCard: View {
  let variant: ImageVariantInspection

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(variant.platform, systemImage: "cpu")
            .font(.headline)
          Spacer()
          Text(variant.sizeBytes, format: .byteCount(style: .file))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Text(variant.manifestDigest)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
          metadataRow("Layers", value: variant.layerCount.formatted())
          metadataRow("User", value: variant.user ?? "Image default")
          metadataRow("Working directory", value: variant.workingDirectory ?? "/")
          if let author = variant.author { metadataRow("Author", value: author) }
          if let createdAt = variant.createdAt {
            metadataRow("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
          }
        }

        commandBlock("Entrypoint", values: variant.entrypoint)
        commandBlock("Command", values: variant.command)

        if !variant.environment.isEmpty || !variant.labels.isEmpty {
          DisclosureGroup("Environment and labels") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(variant.environment, id: \.self) { value in
                Text(value).font(.caption.monospaced()).textSelection(.enabled)
              }
              ForEach(variant.labels.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                Text("\(entry.key)=\(entry.value)")
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
              }
            }
            .padding(.top, 6)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func metadataRow(_ title: String, value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func commandBlock(_ title: String, values: [String]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(values.joined(separator: " "))
          .font(.callout.monospaced())
          .textSelection(.enabled)
      }
    }
  }
}
