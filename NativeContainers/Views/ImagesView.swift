import SwiftUI

struct ImagesView: View {
  let model: AppModel
  @State private var selectedReference: ImageRecord.ID?
  @State private var isShowingPull = false
  @State private var isShowingPrune = false

  var body: some View {
    Group {
      if model.images.isEmpty {
        ContentUnavailableView(
          "No images",
          systemImage: "square.stack.3d.up",
          description: Text("Pull or build an OCI image to populate the local image store.")
        )
        .navigationTitle("Images")
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(model.images) { image in
                ImageRow(
                  image: image,
                  isSelected: selectedReference == image.id,
                  onSelect: { selectedReference = image.id }
                )
              }
            }
            .padding(8)
          }
          .frame(minWidth: 340, idealWidth: 420)
          .background(.background.secondary)

          if let selectedImage {
            ImageInspectorView(image: selectedImage, appModel: model)
              .id(selectedImage.inspectionID)
              .frame(minWidth: 460)
          } else {
            ContentUnavailableView(
              "Select an image",
              systemImage: "sidebar.right",
              description: Text("Inspect platforms, configuration, aliases, and usage.")
            )
            .frame(minWidth: 460)
          }
        }
        .navigationTitle("Images")
        .onChange(of: model.images, initial: true) {
          synchronizeSelection()
        }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Prune Images", systemImage: "sparkles") {
          isShowingPrune = true
        }
        Button("Pull Image", systemImage: "square.and.arrow.down") {
          isShowingPull = true
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .sheet(isPresented: $isShowingPull) {
      ImagePullView(appModel: model)
    }
    .sheet(isPresented: $isShowingPrune) {
      ImagePruneView(appModel: model)
    }
  }

  private var selectedImage: ImageRecord? {
    model.images.first { $0.id == selectedReference }
  }

  private func synchronizeSelection() {
    guard selectedImage == nil else { return }
    selectedReference = model.images.first?.id
  }
}

struct ImageRow: View {
  let image: ImageRecord
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 14) {
        Image(systemName: "square.stack.3d.up.fill")
          .font(.title2)
          .foregroundStyle(.purple)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(image.reference)
            .font(.headline)
            .lineLimit(1)
          Text(image.digest)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 12)
        Text("Index \(image.indexSizeBytes, format: .byteCount(style: .file))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
          .help("Size of the OCI index descriptor; variant sizes appear in the inspector")
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }
}

#Preview("Images") {
  ImagesView(model: .preview)
    .frame(width: 1_100, height: 720)
}
