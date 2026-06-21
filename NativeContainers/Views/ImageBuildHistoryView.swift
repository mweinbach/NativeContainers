import SwiftUI

struct ImageBuildHistoryView: View {
  let model: ImageBuildHistoryModel

  @State private var isClearConfirmationPresented = false

  var body: some View {
    Group {
      if model.records.isEmpty {
        VStack(spacing: 16) {
          ContentUnavailableView(
            "No build history",
            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            description: Text("Native build attempts will appear here.")
          )

          if model.rejectedRecordCount > 0 {
            ImageBuildHistoryWarningRow(count: model.rejectedRecordCount)
          }

          if let errorMessage = model.errorMessage {
            ImageBuildHistoryErrorRow(
              message: errorMessage,
              dismiss: model.clearError
            )
          }
        }
        .padding()
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            if model.rejectedRecordCount > 0 {
              ImageBuildHistoryWarningRow(count: model.rejectedRecordCount)
                .padding()
              Divider()
            }

            if let errorMessage = model.errorMessage {
              ImageBuildHistoryErrorRow(
                message: errorMessage,
                dismiss: model.clearError
              )
              .padding()
              Divider()
            }

            ForEach(model.records) { record in
              HStack(alignment: .top, spacing: 8) {
                ImageBuildHistoryRow(record: record)

                Button("Delete", systemImage: "trash", role: .destructive) {
                  Task { await model.remove(id: record.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
              }
              .padding(.horizontal)
              Divider()
            }
          }
        }
      }
    }
    .overlay {
      if model.isBusy, model.records.isEmpty {
        ProgressView("Loading build history…")
          .controlSize(.small)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Refresh History", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .disabled(model.isBusy)

        Button("Clear History…", systemImage: "trash", role: .destructive) {
          isClearConfirmationPresented = true
        }
        .disabled(
          model.isBusy
            || (model.records.isEmpty && model.rejectedRecordCount == 0)
        )
      }
    }
    .task {
      await model.observe()
    }
    .confirmationDialog(
      "Clear all local build history?",
      isPresented: $isClearConfirmationPresented
    ) {
      Button("Clear Build History", role: .destructive) {
        Task { await model.removeAll() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes NativeContainers’ private history records. It does not delete images, the builder, or BuildKit cache."
      )
    }
  }
}

private struct ImageBuildHistoryWarningRow: View {
  let count: Int

  var body: some View {
    Label {
      if count == 1 {
        Text("Skipped one unreadable history record.")
      } else {
        Text("Skipped \(count) unreadable history records.")
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
    }
    .foregroundStyle(.orange)
  }
}

private struct ImageBuildHistoryErrorRow: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .privacySensitive()

      Spacer()

      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
  }
}

private struct ImageBuildHistoryRow: View {
  let record: ImageBuildHistoryRecord

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: record.status.systemImage)
        .foregroundStyle(record.status.tint)
        .font(.title3)
        .frame(width: 24)
        .accessibilityLabel(Text(record.status.title))

      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .firstTextBaseline) {
          Text(record.contextDisplayName)
            .font(.headline)
            .privacySensitive()

          Spacer(minLength: 12)

          Text(record.status.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(record.status.tint)
        }

        Label(
          record.requestedTags.joined(separator: ", "),
          systemImage: "tag"
        )
        .font(.subheadline)
        .lineLimit(2)
        .privacySensitive()

        if record.status == .partiallySucceeded {
          Label {
            if record.completedTags.isEmpty {
              Text("No requested tags completed.")
            } else {
              Text("Completed tags: \(record.completedTags.joined(separator: ", "))")
            }
          } icon: {
            Image(systemName: "checkmark.circle")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .privacySensitive()
        }

        ForEach(record.retainedImages) { image in
          Label {
            Text(verbatim: "\(image.reference)@\(image.digest)")
          } icon: {
            Image(systemName: "shippingbox")
          }
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .privacySensitive()
        }

        Label(
          record.platforms.map(\.description).joined(separator: ", "),
          systemImage: "cpu"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          Label {
            if let finishedAt = record.finishedAt {
              Text(finishedAt, format: .dateTime.month().day().hour().minute().second())
            } else {
              Text(record.startedAt, format: .dateTime.month().day().hour().minute().second())
            }
          } icon: {
            Image(systemName: record.finishedAt == nil ? "play.circle" : "clock")
          }

          if let durationMilliseconds = record.durationMilliseconds {
            Label(
              Duration.milliseconds(durationMilliseconds).formatted(.units()),
              systemImage: "timer"
            )
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let failureKind = record.failureKind {
          Label {
            Text(failureKind.guidance)
          } icon: {
            Image(systemName: "info.circle")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if let imageDigest = record.imageDigest {
          Text(imageDigest)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .privacySensitive()
        }
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .contain)
  }
}

extension ImageBuildHistoryStatus {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .running: "Running"
    case .succeeded: "Succeeded"
    case .partiallySucceeded: "Partially Succeeded"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    case .interrupted: "Interrupted"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .running: "hammer.circle.fill"
    case .succeeded: "checkmark.circle.fill"
    case .partiallySucceeded: "exclamationmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "nosign"
    case .interrupted: "bolt.slash.circle.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .running: .blue
    case .succeeded: .green
    case .partiallySucceeded: .orange
    case .failed: .red
    case .cancelled, .interrupted: .secondary
    }
  }
}

extension ImageBuildHistoryFailureKind {
  fileprivate var guidance: LocalizedStringResource {
    switch self {
    case .authorization:
      "The reviewed authorization was not sufficient."
    case .staleReview:
      "Reviewed build inputs changed before execution."
    case .context:
      "The build context or requested options were rejected."
    case .secretReview:
      "The private secret review could not be used."
    case .builder:
      "The native builder or its worker did not complete."
    case .artifact:
      "The built artifact did not pass validation."
    case .partialFinalization:
      "The image was imported, but final tags were only partly applied."
    case .partialImport:
      "At least one image was imported before artifact validation failed."
    case .unknown:
      "The build did not complete."
    }
  }
}

#Preview("Build history") {
  let snapshot = ImageBuildHistorySnapshot(
    records: [
      ImageBuildHistoryRecord(
        id: UUID(),
        buildID: UUID(),
        launchID: UUID(),
        contextDisplayName: "sample-api",
        contextFingerprint: "context-fingerprint",
        dockerfileSHA256: "dockerfile-sha256",
        requestedTags: ["sample-api:latest"],
        completedTags: ["sample-api:latest"],
        platforms: [.current],
        buildArgumentKeys: ["CONFIGURATION"],
        labelKeys: ["org.opencontainers.image.source"],
        targetStage: "release",
        startedAt: Date().addingTimeInterval(-42),
        finishedAt: Date(),
        durationMilliseconds: 42_000,
        status: .succeeded,
        imageDigest: "sha256:1234567890abcdef1234567890abcdef",
        retainedImages: [],
        failureKind: nil,
        secretCount: 1,
        noCache: false,
        pullLatest: true
      ),
      ImageBuildHistoryRecord(
        id: UUID(),
        buildID: UUID(),
        launchID: UUID(),
        contextDisplayName: "worker",
        contextFingerprint: "context-fingerprint",
        dockerfileSHA256: "dockerfile-sha256",
        requestedTags: ["worker:review"],
        completedTags: [],
        platforms: [.amd64],
        buildArgumentKeys: [],
        labelKeys: [],
        targetStage: "",
        startedAt: Date().addingTimeInterval(-120),
        finishedAt: Date().addingTimeInterval(-90),
        durationMilliseconds: 30_000,
        status: .partiallySucceeded,
        imageDigest: nil,
        retainedImages: [
          ImageBuildHistoryRetainedImage(
            reference: "worker:recovery-amd64",
            digest: "sha256:abcdef1234567890abcdef1234567890"
          ),
          ImageBuildHistoryRetainedImage(
            reference: "worker:recovery-arm64",
            digest: "sha256:1234567890abcdef1234567890abcdef"
          ),
        ],
        failureKind: .partialImport,
        secretCount: 0,
        noCache: true,
        pullLatest: false
      ),
    ],
    rejectedRecordCount: 1
  )
  ImageBuildHistoryView(
    model: ImageBuildHistoryModel(
      service: NoopImageBuildHistoryStore(snapshot: snapshot),
      initialSnapshot: snapshot
    )
  )
  .frame(width: 780, height: 520)
}
