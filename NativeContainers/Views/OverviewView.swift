import SwiftUI

struct OverviewView: View {
  let model: AppModel

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
          imageCount: model.images.count,
          volumeCount: model.volumes.count,
          networkCount: model.networks.count,
          linuxMachineCount: model.linuxMachines.count,
          virtualMachineCount: model.virtualMachines.count
        )
        ActiveResourcesSection(
          containers: model.containers.filter { $0.state.isRunning },
          machines: model.linuxMachines.filter { $0.state.isRunning }
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
  let imageCount: Int
  let volumeCount: Int
  let networkCount: Int
  let linuxMachineCount: Int
  let virtualMachineCount: Int

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
        tint: .blue
      )
      SummaryCard(
        title: "Images",
        value: imageCount.formatted(),
        detail: "locally available",
        systemImage: "square.stack.3d.up",
        tint: .purple
      )
      SummaryCard(
        title: "Volumes",
        value: volumeCount.formatted(),
        detail: "persistent stores",
        systemImage: "externaldrive",
        tint: .orange
      )
      SummaryCard(
        title: "Networks",
        value: networkCount.formatted(),
        detail: "virtual subnets",
        systemImage: "network",
        tint: .teal
      )
      SummaryCard(
        title: "Linux Machines",
        value: linuxMachineCount.formatted(),
        detail: "development VMs",
        systemImage: "terminal",
        tint: .green
      )
      SummaryCard(
        title: "macOS VMs",
        value: virtualMachineCount.formatted(),
        detail: "managed bundles",
        systemImage: "macwindow",
        tint: .indigo
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

  var body: some View {
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
  }
}

struct ActiveResourcesSection: View {
  let containers: [ContainerRecord]
  let machines: [LinuxMachineRecord]

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
              systemImage: "shippingbox.fill"
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
              systemImage: "terminal.fill"
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

  var body: some View {
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
  }
}
