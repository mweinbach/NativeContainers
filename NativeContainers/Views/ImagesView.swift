import SwiftUI

struct ImagesView: View {
  let images: [ImageRecord]

  var body: some View {
    VStack(spacing: 0) {
      if images.isEmpty {
        ContentUnavailableView(
          "No images",
          systemImage: "square.stack.3d.up",
          description: Text("Pull or build an OCI image to populate the local image store.")
        )
      } else {
        List(images) { image in
          ImageRow(image: image)
        }
      }
    }
    .navigationTitle("Images")
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
