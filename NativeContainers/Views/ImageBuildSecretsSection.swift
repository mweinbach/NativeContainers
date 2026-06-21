import SwiftUI

struct ImageBuildSecretDraft: Equatable, Identifiable {
  let id: UUID
  var secretID: String
  var sourceURL: URL?

  init(
    id: UUID = UUID(),
    secretID: String = "",
    sourceURL: URL? = nil
  ) {
    self.id = id
    self.secretID = secretID
    self.sourceURL = sourceURL
  }
}

struct ImageBuildSecretsSection: View {
  @Binding var drafts: [ImageBuildSecretDraft]
  let isLocked: Bool
  let chooseSource: (UUID) -> Void

  var body: some View {
    Section("Build secrets") {
      ForEach($drafts) { $draft in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            TextField(
              "Secret ID",
              text: $draft.secretID,
              prompt: Text("npm-token")
            )
            .textFieldStyle(.roundedBorder)

            Button("Remove", systemImage: "minus.circle", role: .destructive) {
              drafts.removeAll { $0.id == draft.id }
            }
            .labelStyle(.iconOnly)
          }

          LabeledContent("Private file") {
            HStack {
              Text(draft.sourceURL?.path(percentEncoded: false) ?? "Not selected")
                .foregroundStyle(draft.sourceURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
              Button("Choose…") {
                chooseSource(draft.id)
              }
            }
          }
        }
        .privacySensitive()
      }

      Button("Add Secret", systemImage: "plus") {
        drafts.append(ImageBuildSecretDraft())
      }
      .disabled(drafts.count >= ImageBuildSecretPolicy.maximumCount)

      Text(
        "Secret files must be private to your macOS user, outside the build context, and at most 500 KiB each. Bytes are read only after confirmation, streamed over the worker’s private pipe, and never retained in the reviewed plan or build log."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(
        "Use RUN --mount=type=secret,id=… in the Dockerfile. The Dockerfile and build network can read mounted values, so treat both as trusted. Build arguments are visible metadata and are not for secrets."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .disabled(isLocked)
  }
}

#Preview("Build secrets") {
  Form {
    ImageBuildSecretsSection(
      drafts: .constant([
        ImageBuildSecretDraft(
          secretID: "npm-token",
          sourceURL: URL(filePath: "/Users/example/.secrets/npm-token")
        ),
        ImageBuildSecretDraft(secretID: "", sourceURL: nil),
      ]),
      isLocked: false,
      chooseSource: { _ in }
    )
  }
  .formStyle(.grouped)
  .frame(width: 680, height: 460)
}
