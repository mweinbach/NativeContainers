import SwiftUI

struct ImagesView: View {
  let model: AppModel
  @State private var isShowingPull = false

  var body: some View {
    VStack(spacing: 0) {
      if model.images.isEmpty {
        ContentUnavailableView(
          "No images",
          systemImage: "square.stack.3d.up",
          description: Text("Pull or build an OCI image to populate the local image store.")
        )
      } else {
        List(model.images) { image in
          ImageRow(image: image)
        }
      }
    }
    .navigationTitle("Images")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Pull Image", systemImage: "square.and.arrow.down") {
          isShowingPull = true
        }
      }
    }
    .sheet(isPresented: $isShowingPull) {
      ImagePullView(appModel: model)
    }
  }
}

struct ImageRow: View {
  let image: ImageRecord

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.title2)
        .foregroundStyle(.purple)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(image.reference)
          .font(.headline)
          .textSelection(.enabled)
        Text(image.digest)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)
      }
      Spacer()
      Text(image.compressedSizeBytes, format: .byteCount(style: .file))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.vertical, 7)
  }
}
