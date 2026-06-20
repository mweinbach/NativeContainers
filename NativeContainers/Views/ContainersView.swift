import SwiftUI

struct ContainersView: View {
  let model: AppModel
  @State private var pendingDeletion: ContainerRecord?

  var body: some View {
    VStack(spacing: 0) {
      if model.containers.isEmpty {
        ContentUnavailableView(
          "No containers",
          systemImage: "shippingbox",
          description: Text("Containers created with Apple’s container runtime appear here.")
        )
      } else {
        List(model.containers) { container in
          ContainerRow(
            container: container,
            onStart: { Task { await model.startContainer(id: container.id) } },
            onStop: { Task { await model.stopContainer(id: container.id) } },
            onDelete: { pendingDeletion = container }
          )
        }
      }
    }
    .navigationTitle("Containers")
    .confirmationDialog(
      "Delete container?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { container in
      Button("Delete \(container.id)", role: .destructive) {
        pendingDeletion = nil
        Task { await model.deleteContainer(id: container.id) }
      }
    } message: { container in
      Text(
        "The container \(container.id) and its writable filesystem will be removed. Named volumes are retained."
      )
    }
  }
}

struct ContainerRow: View {
  let container: ContainerRecord
  let onStart: () -> Void
  let onStop: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      RuntimeStatusIndicator(state: container.state)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(container.id)
            .font(.headline)
          RuntimeStateBadge(state: container.state)
        }
        Text(container.imageReference)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        ContainerMetadataLine(container: container)
      }
      Spacer(minLength: 16)
      ResourceActionMenu(
        isRunning: container.state.isRunning,
        onStart: onStart,
        onStop: onStop,
        onDelete: onDelete
      )
    }
    .padding(.vertical, 7)
  }
}

struct ContainerMetadataLine: View {
  let container: ContainerRecord

  var body: some View {
    HStack(spacing: 12) {
      Label("\(container.cpuCount) CPUs", systemImage: "cpu")
      Label {
        Text(Int64(clamping: container.memoryBytes), format: .byteCount(style: .memory))
      } icon: {
        Image(systemName: "memorychip")
      }
      if let ipAddress = container.ipAddress {
        Label(ipAddress, systemImage: "network")
      }
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
  }
}
