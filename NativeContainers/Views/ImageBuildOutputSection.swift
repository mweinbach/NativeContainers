import SwiftUI

struct ImageBuildOutputSection: View {
  @Binding var kind: ImageBuildOutputKind
  @Binding var reference: String
  @Binding var platform: ImageBuildPlatformSelection
  @Binding var targetStage: String
  @Binding var destinationParent: URL?
  @Binding var destinationName: String

  let isLocked: Bool
  let chooseDestinationParent: () -> Void
  let kindDidChange: (ImageBuildOutputKind) -> Void

  var body: some View {
    Section("Build output") {
      Picker("Output", selection: $kind) {
        ForEach(ImageBuildOutputKind.allCases, id: \.self) { outputKind in
          Label(outputKind.title, systemImage: outputKind.systemImage)
            .tag(outputKind)
        }
      }
      .onChange(of: kind) { _, newValue in
        kindDidChange(newValue)
      }

      if kind == .imageStore {
        TextField("Tag", text: $reference, prompt: Text("example/app:latest"))
        Text(
          "The reviewed canonical tag is checked again immediately before import and tagging."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if kind == .ociArchive {
        TextField(
          "Image reference",
          text: $reference,
          prompt: Text("example/app:archive")
        )
        Text(
          "The logical reference is embedded in the OCI image layout. It does not create or replace a local image tag."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Picker("Platform", selection: $platform) {
        ForEach(ImageBuildPlatformSelection.allCases) { value in
          Text(value.title).tag(value)
        }
      }
      TextField("Target stage (optional)", text: $targetStage)

      if kind.requiresDestination {
        LabeledContent("Destination folder") {
          HStack {
            Text(destinationParent?.path(percentEncoded: false) ?? "Not selected")
              .foregroundStyle(destinationParent == nil ? .secondary : .primary)
              .lineLimit(1)
              .truncationMode(.middle)
              .privacySensitive()
            Button("Choose…", action: chooseDestinationParent)
          }
        }
        TextField(
          kind == .rootFilesystemDirectory ? "New folder name" : "Archive file name",
          text: $destinationName
        )
        Text(destinationGuidance)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(isLocked)
  }

  private var destinationGuidance: LocalizedStringResource {
    switch kind {
    case .imageStore:
      ""
    case .ociArchive:
      "Exports a runnable OCI image archive for the selected platform. A reviewed existing regular file can be replaced only with explicit confirmation."
    case .rootFilesystemArchive:
      "Exports the final stage’s files as a tar archive, not as a runnable image. One exact platform is required; the archive retains BuildKit’s platform directory envelope."
    case .rootFilesystemDirectory:
      "Exports one exact platform’s final-stage files directly into a new folder. Existing folders are never merged or replaced."
    }
  }
}

#Preview("OCI archive output") {
  @Previewable @State var kind: ImageBuildOutputKind = .ociArchive
  @Previewable @State var reference = "example/app:archive"
  @Previewable @State var platform: ImageBuildPlatformSelection = .current
  @Previewable @State var targetStage = "runtime"
  @Previewable @State var destinationParent: URL? = URL(
    filePath: "/Users/example/Exports",
    directoryHint: .isDirectory
  )
  @Previewable @State var destinationName = "example-app.oci.tar"

  Form {
    ImageBuildOutputSection(
      kind: $kind,
      reference: $reference,
      platform: $platform,
      targetStage: $targetStage,
      destinationParent: $destinationParent,
      destinationName: $destinationName,
      isLocked: false,
      chooseDestinationParent: {},
      kindDidChange: { _ in }
    )
  }
  .formStyle(.grouped)
  .frame(width: 640, height: 460)
}

#Preview("Root filesystem folder – Dark") {
  @Previewable @State var kind: ImageBuildOutputKind = .rootFilesystemDirectory
  @Previewable @State var reference = ""
  @Previewable @State var platform: ImageBuildPlatformSelection = .amd64
  @Previewable @State var targetStage = ""
  @Previewable @State var destinationParent: URL? = nil
  @Previewable @State var destinationName = "rootfs"

  Form {
    ImageBuildOutputSection(
      kind: $kind,
      reference: $reference,
      platform: $platform,
      targetStage: $targetStage,
      destinationParent: $destinationParent,
      destinationName: $destinationName,
      isLocked: false,
      chooseDestinationParent: {},
      kindDidChange: { _ in }
    )
  }
  .formStyle(.grouped)
  .frame(width: 640, height: 460)
  .preferredColorScheme(.dark)
}

enum ImageBuildPlatformSelection: String, CaseIterable, Identifiable {
  case current
  case amd64

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .current:
      "Linux arm64/v8 (this Mac)"
    case .amd64:
      "Linux amd64"
    }
  }

  var value: ContainerBuildPlatform {
    switch self {
    case .current:
      .current
    case .amd64:
      .amd64
    }
  }
}
