import SwiftUI

struct VolumesView: View {
  let volumes: [VolumeRecord]

  var body: some View {
    VStack(spacing: 0) {
      if volumes.isEmpty {
        ContentUnavailableView(
          "No volumes",
          systemImage: "externaldrive",
          description: Text("Persistent Apple container volumes appear here.")
        )
      } else {
        List(volumes) { volume in
          VolumeRow(volume: volume)
        }
      }
    }
    .navigationTitle("Volumes")
  }
}

struct VolumeRow: View {
  let volume: VolumeRecord

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "externaldrive.fill")
        .font(.title2)
        .foregroundStyle(.orange)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(volume.name)
            .font(.headline)
          if volume.isAnonymous {
            Text("Anonymous")
              .font(.caption)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
          }
        }
        Text("\(volume.driver) · \(volume.format)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let size = volume.sizeBytes {
        Text(Int64(clamping: size), format: .byteCount(style: .file))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.vertical, 7)
  }
}
