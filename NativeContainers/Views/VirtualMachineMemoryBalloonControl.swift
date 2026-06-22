import SwiftUI

struct VirtualMachineMemoryBalloonControl: View {
  let snapshot: VirtualMachineMemoryBalloonSnapshot?
  let canChangeTarget: Bool
  let requestTarget: (UInt64) -> Void

  var body: some View {
    if let snapshot {
      Menu {
        ForEach(snapshot.targetOptions) { option in
          Button(
            option.kind.label,
            systemImage: option.memoryBytes == snapshot.targetMemoryBytes
              ? "checkmark" : "circle.dashed"
          ) {
            requestTarget(option.memoryBytes)
          }
          .disabled(option.memoryBytes == snapshot.targetMemoryBytes)
        }
      } label: {
        Label {
          Text(
            Int64(clamping: snapshot.targetMemoryBytes),
            format: .byteCount(style: .file)
          )
        } icon: {
          Image(systemName: "memorychip")
        }
      }
      .menuStyle(.borderlessButton)
      .disabled(!canChangeTarget || !snapshot.canRequestAnotherTarget)
      .help(
        "Ask the running guest to cooperatively release memory or restore its full configured allocation."
      )
      .accessibilityLabel("Guest memory target")
      .accessibilityValue(
        Text(
          Int64(clamping: snapshot.targetMemoryBytes),
          format: .byteCount(style: .file)
        )
      )
    }
  }
}

struct VirtualMachineMemoryBalloonNotice: View {
  let snapshot: VirtualMachineMemoryBalloonSnapshot?

  var body: some View {
    if let snapshot, snapshot.isRequestingReclamation {
      HStack(spacing: 8) {
        Image(systemName: "memorychip")
        Text(
          "Guest memory target: \(Int64(clamping: snapshot.targetMemoryBytes), format: .byteCount(style: .file)). Reclamation is cooperative; the guest may keep more memory."
        )
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.bottom, 10)
    }
  }
}

#Preview("Guest memory target") {
  VStack(alignment: .leading, spacing: 12) {
    VirtualMachineMemoryBalloonControl(
      snapshot: VirtualMachineMemoryBalloonSnapshot(
        configuredMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        minimumTargetMemoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
        targetMemoryBytes: 4 * VirtualMachineResources.bytesPerGiB
      ),
      canChangeTarget: true,
      requestTarget: { _ in }
    )
    VirtualMachineMemoryBalloonNotice(
      snapshot: VirtualMachineMemoryBalloonSnapshot(
        configuredMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        minimumTargetMemoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
        targetMemoryBytes: 4 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
  .padding()
  .frame(width: 520)
}
