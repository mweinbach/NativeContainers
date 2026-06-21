import SwiftUI

struct OverviewView: View {
  let model: AppModel
  @State private var storageModel: StorageOverviewModel
  @State private var storageReclamationModel: StorageReclamationModel
  @State private var virtualMachineStorageReclamationModel: VirtualMachineStorageReclamationModel

  init(model: AppModel) {
    self.model = model
    _storageModel = State(initialValue: model.makeStorageOverviewModel())
    _storageReclamationModel = State(
      initialValue: model.makeStorageReclamationModel()
    )
    _virtualMachineStorageReclamationModel = State(
      initialValue: model.makeVirtualMachineStorageReclamationModel()
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        OverviewHeader(
          systemInfo: model.systemInfo,
          lastRefresh: model.lastRefresh,
          isRefreshing: model.isRefreshing
        )
        ResourceSummaryGrid(
          runningContainers: model.containers.count(where: { $0.state.isRunning }),
          containerCount: model.containers.count,
          composeProjectCount: model.composeProjects.count,
          imageCount: model.images.count,
          volumeCount: model.volumes.count,
          networkCount: model.networks.count,
          linuxMachineCount: model.linuxMachines.count,
          virtualMachineCount: model.virtualMachines.count,
          onNavigate: { route in model.navigate(to: route) }
        )
        StorageOverviewSection(
          model: storageModel,
          reclamationModel: storageReclamationModel,
          virtualMachineReclamationModel:
            virtualMachineStorageReclamationModel,
          containerInventoryRevision: model.containerInventoryRevision,
          virtualMachineInventoryRevision:
            model.virtualMachineInventoryRevision
        )
        if !model.composeProjects.isEmpty {
          ComposeProjectsOverviewSection(
            projects: model.composeProjects,
            onOpen: { route in model.navigate(to: route) }
          )
        }
        ActiveResourcesSection(
          containers: model.containers.filter { $0.state.isRunning },
          machines: model.linuxMachines.filter { $0.state.isRunning },
          onOpen: { route in model.navigate(to: route) }
        )
      }
      .padding(28)
    }
    .navigationTitle("Overview")
  }
}

struct OverviewHeader: View {
  let systemInfo: ContainerSystemInfo?
  let lastRefresh: Date?
  let isRefreshing: Bool

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Native runtime")
          .font(.largeTitle.bold())
        if let systemInfo {
          Label("Apple container services are running", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text(systemInfo.version)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else {
          Label(
            "Apple container services are unavailable", systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
        }
      }

      Spacer()

      if isRefreshing {
        ProgressView()
          .controlSize(.small)
      } else if let lastRefresh {
        Text("Updated \(lastRefresh, format: .relative(presentation: .named))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct ResourceSummaryGrid: View {
  let runningContainers: Int
  let containerCount: Int
  let composeProjectCount: Int
  let imageCount: Int
  let volumeCount: Int
  let networkCount: Int
  let linuxMachineCount: Int
  let virtualMachineCount: Int
  let onNavigate: (WorkspaceRoute) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 14) {
      SummaryCard(
        title: "Containers",
        value: "\(runningContainers) / \(containerCount)",
        detail: "running",
        systemImage: "shippingbox",
        tint: .blue,
        action: { onNavigate(.containers) }
      )
      SummaryCard(
        title: "Compose",
        value: composeProjectCount.formatted(),
        detail: "observed projects",
        systemImage: "square.stack.3d.down.right",
        tint: .indigo,
        action: { onNavigate(.composeProjects) }
      )
      SummaryCard(
        title: "Images",
        value: imageCount.formatted(),
        detail: "locally available",
        systemImage: "square.stack.3d.up",
        tint: .purple,
        action: { onNavigate(.images) }
      )
      SummaryCard(
        title: "Volumes",
        value: volumeCount.formatted(),
        detail: "persistent stores",
        systemImage: "externaldrive",
        tint: .orange,
        action: { onNavigate(.volumes) }
      )
      SummaryCard(
        title: "Networks",
        value: networkCount.formatted(),
        detail: "virtual subnets",
        systemImage: "network",
        tint: .teal,
        action: { onNavigate(.networks) }
      )
      SummaryCard(
        title: "Linux Machines",
        value: linuxMachineCount.formatted(),
        detail: "development VMs",
        systemImage: "terminal",
        tint: .green,
        action: { onNavigate(.linuxMachines) }
      )
      SummaryCard(
        title: "macOS VMs",
        value: virtualMachineCount.formatted(),
        detail: "managed bundles",
        systemImage: "macwindow",
        tint: .indigo,
        action: { onNavigate(.macOSVirtualMachines) }
      )
    }
  }
}

struct SummaryCard: View {
  let title: LocalizedStringResource
  let value: String
  let detail: LocalizedStringResource
  let systemImage: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(tint)
          Spacer()
          Text(value)
            .font(.title2.bold().monospacedDigit())
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this resource category")
  }
}

struct ActiveResourcesSection: View {
  let containers: [ContainerRecord]
  let machines: [LinuxMachineRecord]
  let onOpen: (WorkspaceRoute) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Active now")
        .font(.title2.bold())

      if containers.isEmpty && machines.isEmpty {
        ContentUnavailableView(
          "Nothing running",
          systemImage: "moon.zzz",
          description: Text("Start a container or Linux machine to see it here.")
        )
        .frame(maxWidth: .infinity, minHeight: 170)
      } else {
        VStack(spacing: 0) {
          ForEach(containers) { container in
            ActiveResourceRow(
              name: container.id,
              detail: container.imageReference,
              address: container.ipAddress,
              systemImage: "shippingbox.fill",
              action: { onOpen(.container(container.id)) }
            )
            if container.id != containers.last?.id || !machines.isEmpty {
              Divider()
            }
          }
          ForEach(machines) { machine in
            ActiveResourceRow(
              name: machine.id,
              detail: machine.imageReference,
              address: machine.ipAddress,
              systemImage: "terminal.fill",
              action: { onOpen(.linuxMachine(machine.id)) }
            )
            if machine.id != machines.last?.id {
              Divider()
            }
          }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
      }
    }
  }
}

struct ActiveResourceRow: View {
  let name: String
  let detail: String
  let address: String?
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .foregroundStyle(.green)
          .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(name)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let address {
          Text(address)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this resource")
  }
}

#Preview("Overview") {
  NavigationStack {
    OverviewView(model: .preview)
  }
  .frame(width: 1_080, height: 760)
}
