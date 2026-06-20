import SwiftUI

struct ContainersView: View {
  let model: AppModel
  @State private var pendingDeletion: ContainerRecord?
  @State private var selectedContainerID: ContainerRecord.ID?
  @State private var isShowingCreation = false

  var body: some View {
    Group {
      if model.containers.isEmpty {
        ContentUnavailableView(
          "No containers",
          systemImage: "shippingbox",
          description: Text("Containers created with Apple’s container runtime appear here.")
        )
        .navigationTitle("Containers")
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(model.containers) { container in
                ContainerRow(
                  container: container,
                  isSelected: selectedContainerID == container.id,
                  onSelect: { selectedContainerID = container.id },
                  onStart: { Task { await model.startContainer(id: container.id) } },
                  onStop: { Task { await model.stopContainer(id: container.id) } },
                  onDelete: { pendingDeletion = container }
                )
              }
            }
            .padding(8)
          }
          .frame(minWidth: 360, idealWidth: 430)
          .background(.background.secondary)

          if let container = selectedContainer {
            ContainerInspectorView(container: container, appModel: model)
              .id(container.id)
              .frame(minWidth: 430)
          } else {
            ContentUnavailableView(
              "Select a container",
              systemImage: "sidebar.right",
              description: Text("Inspect resource usage, ports, and logs.")
            )
            .frame(minWidth: 430)
          }
        }
        .navigationTitle("Containers")
        .onChange(of: model.containers, initial: true) {
          synchronizeSelection()
        }
      }
    }
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
        if selectedContainerID == container.id {
          selectedContainerID = nil
        }
        Task { await model.deleteContainer(id: container.id) }
      }
    } message: { container in
      Text(
        "The container \(container.id) and its writable filesystem will be removed. Named volumes are retained."
      )
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New Container", systemImage: "plus") {
          isShowingCreation = true
        }
      }
    }
    .sheet(isPresented: $isShowingCreation) {
      ContainerCreationView(appModel: model)
    }
  }

  private var selectedContainer: ContainerRecord? {
    model.containers.first { $0.id == selectedContainerID }
  }

  private func synchronizeSelection() {
    guard selectedContainer == nil else { return }
    selectedContainerID = model.containers.first?.id
  }
}

struct ContainerRow: View {
  let container: ContainerRecord
  let isSelected: Bool
  let onSelect: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button(action: onSelect) {
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
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isSelected ? "Selected" : "Not selected")

      ResourceActionMenu(
        isRunning: container.state.isRunning,
        onStart: onStart,
        onStop: onStop,
        onDelete: onDelete
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
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

struct ContainerInspectorView: View {
  let container: ContainerRecord
  let appModel: AppModel
  @State private var model: ContainerInspectorModel
  @State private var selectedLog = ContainerLogKind.standardOutput

  init(container: ContainerRecord, appModel: AppModel) {
    self.container = container
    self.appModel = appModel
    _model = State(initialValue: appModel.makeContainerInspector(containerID: container.id))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        ContainerInspectorHeader(
          container: container,
          isLoading: model.isLoading,
          onRefresh: { Task { await model.load() } },
          onStart: { Task { await appModel.startContainer(id: container.id) } },
          onStop: { Task { await appModel.stopContainer(id: container.id) } }
        )

        if let errorMessage = model.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }

        ContainerAllocationSection(container: container)

        if let inspection = model.inspection {
          ContainerMetricsSection(inspection: inspection)
          ContainerPortsSection(ports: container.ports)
          ContainerLogsSection(
            inspection: inspection,
            selection: $selectedLog
          )
        } else if model.isLoading {
          ProgressView("Loading container details…")
            .frame(maxWidth: .infinity, minHeight: 180)
        }
      }
      .padding(24)
    }
    .background(.background)
    .task {
      await model.load()
    }
  }
}

struct ContainerInspectorHeader: View {
  let container: ContainerRecord
  let isLoading: Bool
  let onRefresh: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "shippingbox.fill")
        .font(.largeTitle)
        .foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(container.id)
            .font(.title.bold())
          RuntimeStateBadge(state: container.state)
        }
        Text(container.imageReference)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
        .labelStyle(.iconOnly)
        .disabled(isLoading)
      if container.state.isRunning {
        Button("Stop", systemImage: "stop.fill", action: onStop)
      } else {
        Button("Start", systemImage: "play.fill", action: onStart)
          .buttonStyle(.borderedProminent)
      }
    }
  }
}

struct ContainerAllocationSection: View {
  let container: ContainerRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Configuration")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
        GridRow {
          LabeledContent("Platform", value: container.platform)
          LabeledContent("CPUs", value: container.cpuCount.formatted())
        }
        GridRow {
          LabeledContent("Memory") {
            Text(Int64(clamping: container.memoryBytes), format: .byteCount(style: .memory))
          }
          LabeledContent("Address", value: container.ipAddress ?? "Not assigned")
        }
      }
      .foregroundStyle(.secondary)
    }
  }
}

struct ContainerMetricsSection: View {
  let inspection: ContainerInspection

  private let columns = [GridItem(.adaptive(minimum: 125, maximum: 190), spacing: 10)]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Resource usage")
        .font(.headline)
      LazyVGrid(columns: columns, spacing: 10) {
        ContainerMetricCard(
          title: "Disk",
          value: Int64(clamping: inspection.diskUsageBytes).formatted(.byteCount(style: .file)),
          systemImage: "internaldrive"
        )
        if let statistics = inspection.statistics {
          ContainerMetricCard(
            title: "Memory",
            value: formattedMemory(statistics),
            systemImage: "memorychip"
          )
          ContainerMetricCard(
            title: "CPU time",
            value: formattedCPUTime(statistics.cpuUsageMicroseconds),
            systemImage: "cpu"
          )
          ContainerMetricCard(
            title: "Network",
            value: formattedPair(
              received: statistics.networkReceivedBytes,
              sent: statistics.networkTransmittedBytes
            ),
            systemImage: "arrow.up.arrow.down"
          )
          ContainerMetricCard(
            title: "Block I/O",
            value: formattedPair(
              received: statistics.blockReadBytes,
              sent: statistics.blockWrittenBytes
            ),
            systemImage: "externaldrive.badge.timemachine"
          )
          ContainerMetricCard(
            title: "Processes",
            value: statistics.processCount?.formatted() ?? "—",
            systemImage: "list.number"
          )
        }
      }
    }
  }

  private func formattedMemory(_ statistics: ContainerStatistics) -> String {
    let used =
      statistics.memoryUsageBytes.map {
        Int64(clamping: $0).formatted(.byteCount(style: .memory))
      } ?? "—"
    guard let limit = statistics.memoryLimitBytes else { return used }
    return "\(used) / \(Int64(clamping: limit).formatted(.byteCount(style: .memory)))"
  }

  private func formattedCPUTime(_ microseconds: UInt64?) -> String {
    guard let microseconds else { return "—" }
    let seconds = Double(microseconds) / 1_000_000
    return seconds.formatted(.number.precision(.fractionLength(1))) + " s"
  }

  private func formattedPair(received: UInt64?, sent: UInt64?) -> String {
    let first = received.map { Int64(clamping: $0).formatted(.byteCount(style: .file)) } ?? "—"
    let second = sent.map { Int64(clamping: $0).formatted(.byteCount(style: .file)) } ?? "—"
    return "\(first) ↓ / \(second) ↑"
  }
}

struct ContainerMetricCard: View {
  let title: LocalizedStringResource
  let value: String
  let systemImage: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct ContainerPortsSection: View {
  let ports: [ContainerPort]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Published ports")
        .font(.headline)
      if ports.isEmpty {
        Text("No ports published")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(ports) { port in
            HStack {
              Text("\(port.hostAddress):\(port.hostPort)")
                .textSelection(.enabled)
              Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
              Text("\(port.containerPort)/\(port.protocolName)")
                .monospaced()
              Spacer()
            }
            .padding(.vertical, 7)
          }
        }
      }
    }
  }
}

enum ContainerLogKind: String, CaseIterable, Identifiable {
  case standardOutput
  case boot

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .standardOutput: "Output"
    case .boot: "Boot"
    }
  }
}

struct ContainerLogsSection: View {
  let inspection: ContainerInspection
  @Binding var selection: ContainerLogKind

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Logs")
          .font(.headline)
        Spacer()
        Picker("Log source", selection: $selection) {
          ForEach(ContainerLogKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
      }

      ScrollView([.horizontal, .vertical]) {
        Group {
          if logText.isEmpty {
            Text("No log output.")
          } else {
            Text(logText)
          }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .frame(minHeight: 150, maxHeight: 320)
      .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
      .foregroundStyle(.white)

      if inspection.logsAreTruncated {
        Text("Showing the last 512 KiB of available log data.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var logText: String {
    switch selection {
    case .standardOutput: inspection.standardOutput
    case .boot: inspection.bootLog
    }
  }
}

#Preview("Container inspector") {
  ContainersView(model: .previewContainers)
    .frame(width: 1120, height: 720)
}
