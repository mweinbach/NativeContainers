import SwiftUI
import UniformTypeIdentifiers

struct ContainersView: View {
  let model: AppModel
  @State private var pendingDeletion: ContainerRecord?
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
                  onSelect: { model.navigate(to: .container(container.id)) },
                  onStart: { Task { await model.startContainer(id: container.id) } },
                  onStop: { Task { await model.stopContainer(id: container.id) } },
                  onRestart: { Task { await model.restartContainer(id: container.id) } },
                  onForceStop: { Task { await model.forceStopContainer(id: container.id) } },
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
          model.navigate(to: .containers)
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

  private var selectedContainerID: ContainerRecord.ID? {
    guard case .container(let id) = model.workspaceRoute else { return nil }
    return id
  }

  private func synchronizeSelection() {
    guard selectedContainer == nil else { return }
    if let id = model.containers.first?.id {
      model.navigate(to: .container(id))
    }
  }
}

struct ContainerRow: View {
  let container: ContainerRecord
  let isSelected: Bool
  let onSelect: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onRestart: () -> Void
  let onForceStop: () -> Void
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
        onRestart: onRestart,
        onForceStop: onForceStop,
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
  @State private var isLive = true
  @State private var followsLogs = true
  @State private var logQuery = ""
  @State private var isShowingTerminal = false
  @State private var isShowingExec = false
  @State private var isShowingFileTransfer = false

  init(container: ContainerRecord, appModel: AppModel) {
    self.container = container
    self.appModel = appModel
    _model = State(initialValue: appModel.makeContainerInspector(for: container))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        ContainerInspectorHeader(
          container: container,
          isLoading: model.isLoading,
          lastUpdated: model.lastUpdated,
          isLive: $isLive,
          onRefresh: { Task { await model.load() } },
          onStart: { Task { await appModel.startContainer(id: container.id) } },
          onStop: { Task { await appModel.stopContainer(id: container.id) } },
          onRestart: { Task { await appModel.restartContainer(id: container.id) } },
          onForceStop: { Task { await appModel.forceStopContainer(id: container.id) } },
          onTerminal: { isShowingTerminal = true },
          onExec: { isShowingExec = true },
          onCopyFiles: { isShowingFileTransfer = true }
        )

        if let errorMessage = model.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }

        ContainerAllocationSection(container: container)

        if let inspection = model.inspection {
          ContainerMetricsSection(
            inspection: inspection,
            latestSample: model.samples.last,
            sampleCount: model.samples.count
          )
          ContainerPortsSection(
            containerID: container.id,
            containerCreatedAt: container.createdAt,
            ports: container.ports,
            appModel: appModel
          )
          ContainerLogsSection(
            containerID: container.id,
            inspection: inspection,
            isRunning: container.state.isRunning,
            selection: $selectedLog,
            followsLogs: $followsLogs,
            query: $logQuery
          )
        } else if model.isLoading {
          ProgressView("Loading container details…")
            .frame(maxWidth: .infinity, minHeight: 180)
        }
      }
      .padding(24)
    }
    .background(.background)
    .task(id: ContainerMonitorConfiguration(isLive: isLive, followsLogs: followsLogs)) {
      await model.load()
      guard isLive, container.state.isRunning else { return }
      await model.monitor(followLogs: followsLogs)
    }
    .sheet(isPresented: $isShowingExec) {
      ContainerExecView(containerID: container.id, appModel: appModel)
    }
    .sheet(isPresented: $isShowingTerminal) {
      ContainerTerminalView(containerID: container.id, appModel: appModel)
    }
    .sheet(isPresented: $isShowingFileTransfer) {
      ContainerFileTransferView(containerID: container.id, appModel: appModel)
    }
  }
}

private struct ContainerMonitorConfiguration: Hashable {
  let isLive: Bool
  let followsLogs: Bool
}

struct ContainerInspectorHeader: View {
  let container: ContainerRecord
  let isLoading: Bool
  let lastUpdated: Date?
  @Binding var isLive: Bool
  let onRefresh: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onRestart: () -> Void
  let onForceStop: () -> Void
  let onTerminal: () -> Void
  let onExec: () -> Void
  let onCopyFiles: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "shippingbox.fill")
          .font(.largeTitle)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(container.id)
              .font(.title.bold())
              .lineLimit(1)
            RuntimeStateBadge(state: container.state)
          }
          Text(container.imageReference)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
        Spacer()
      }

      HStack {
        if let lastUpdated {
          Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if container.state.isRunning {
          Button("Terminal", systemImage: "terminal.fill", action: onTerminal)
            .buttonStyle(.borderedProminent)
          Button("Exec", systemImage: "chevron.left.forwardslash.chevron.right", action: onExec)
          Toggle("Live", systemImage: "waveform.path.ecg", isOn: $isLive)
            .toggleStyle(.button)
            .help("Sample runtime statistics every two seconds")
        }
        Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
          .labelStyle(.iconOnly)
          .disabled(isLoading)
        if container.state.isRunning {
          Button("Restart", systemImage: "arrow.trianglehead.2.clockwise", action: onRestart)
            .labelStyle(.iconOnly)
            .help("Restart container")
          Button("Stop", systemImage: "stop.fill", action: onStop)
          Menu("More", systemImage: "ellipsis.circle") {
            Button("Copy Files…", systemImage: "doc.on.doc", action: onCopyFiles)
            Button(
              "Force Stop",
              systemImage: "bolt.fill",
              role: .destructive,
              action: onForceStop
            )
          }
          .menuStyle(.borderlessButton)
        } else {
          Button("Copy Files…", systemImage: "doc.on.doc", action: onCopyFiles)
          Button("Start", systemImage: "play.fill", action: onStart)
            .buttonStyle(.borderedProminent)
        }
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
  let latestSample: ContainerRuntimeSample?
  let sampleCount: Int

  private let columns = [GridItem(.adaptive(minimum: 125, maximum: 190), spacing: 10)]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Resource usage")
          .font(.headline)
        Spacer()
        if sampleCount > 1 {
          Label("\(sampleCount) live samples", systemImage: "waveform.path.ecg")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
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
            title: "CPU",
            value: formattedCPU(statistics),
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

  private func formattedCPU(_ statistics: ContainerStatistics) -> String {
    if let cpuPercentage = latestSample?.cpuPercentage {
      return cpuPercentage.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    let microseconds = statistics.cpuUsageMicroseconds
    guard let microseconds else { return "—" }
    let seconds = Double(microseconds) / 1_000_000
    return seconds.formatted(.number.precision(.fractionLength(1))) + " s total"
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
  @Environment(\.openURL) private var openURL
  let containerID: String
  let containerCreatedAt: Date
  let ports: [ContainerPort]
  let appModel: AppModel

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
            ContainerPortRow(
              hostAddress: port.hostAddress,
              hostPort: port.hostPort,
              containerPort: port.containerPort,
              protocolName: port.protocolName,
              onOpenHTTP: {
                open(port: port, scheme: .http)
              },
              onOpenHTTPS: {
                open(port: port, scheme: .https)
              }
            )
          }
        }
      }
    }
  }

  private func open(port: ContainerPort, scheme: ContainerBrowserScheme) {
    Task {
      let target = ContainerBrowserTarget(
        containerID: containerID,
        containerCreatedAt: containerCreatedAt,
        portID: port.id,
        scheme: scheme
      )
      if let url = await appModel.resolveContainerBrowserURL(target) {
        openURL(url)
      }
    }
  }
}

struct ContainerPortRow: View {
  let hostAddress: String
  let hostPort: UInt16
  let containerPort: UInt16
  let protocolName: String
  let onOpenHTTP: () -> Void
  let onOpenHTTPS: () -> Void

  var body: some View {
    HStack {
      Text("\(hostAddress):\(hostPort)")
        .textSelection(.enabled)
      Image(systemName: "arrow.right")
        .foregroundStyle(.tertiary)
      Text("\(containerPort)/\(protocolName)")
        .monospaced()
      Spacer()
      if protocolName.lowercased() == ContainerTransportProtocol.tcp.rawValue {
        Menu("Open in Browser", systemImage: "safari") {
          Button("HTTP", action: onOpenHTTP)
          Button("HTTPS", action: onOpenHTTPS)
        }
        .menuStyle(.borderlessButton)
      }
    }
    .padding(.vertical, 7)
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
  let containerID: String
  let inspection: ContainerInspection
  let isRunning: Bool
  @Binding var selection: ContainerLogKind
  @Binding var followsLogs: Bool
  @Binding var query: String
  @State private var isExporting = false
  @State private var exportError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Logs")
          .font(.headline)
        Spacer()
        Toggle("Follow", systemImage: "dot.radiowaves.left.and.right", isOn: $followsLogs)
          .toggleStyle(.button)
          .disabled(!isRunning)
        Picker("Log source", selection: $selection) {
          ForEach(ContainerLogKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
      }

      HStack {
        TextField("Search logs", text: $query)
          .textFieldStyle(.roundedBorder)
        if !query.isEmpty {
          Text("\(matchCount) matching lines")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Export", systemImage: "square.and.arrow.up") {
          isExporting = true
        }
        .disabled(filteredLogText.isEmpty)
      }

      ScrollView([.horizontal, .vertical]) {
        Group {
          if !query.isEmpty && filteredLogText.isEmpty {
            Text("No matching log lines.")
          } else if filteredLogText.isEmpty {
            Text("No log output.")
          } else {
            Text(filteredLogText)
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
      if let exportError {
        Text(exportError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .fileExporter(
      isPresented: $isExporting,
      document: ContainerLogDocument(text: filteredLogText),
      contentType: .plainText,
      defaultFilename: "\(containerID)-\(selection.rawValue).log"
    ) { result in
      if case .failure(let error) = result {
        exportError = error.localizedDescription
      } else {
        exportError = nil
      }
    }
  }

  private var logText: String {
    switch selection {
    case .standardOutput: inspection.standardOutput
    case .boot: inspection.bootLog
    }
  }

  private var filteredLines: [String] {
    let lines = logText.components(separatedBy: .newlines)
    guard !query.isEmpty else { return lines }
    return lines.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  private var filteredLogText: String {
    filteredLines.joined(separator: "\n")
  }

  private var matchCount: Int {
    query.isEmpty ? 0 : filteredLines.count
  }
}

struct ContainerLogDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.plainText]

  let text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    let data = configuration.file.regularFileContents ?? Data()
    text = String(decoding: data, as: UTF8.self)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

#Preview("Container inspector") {
  ContainersView(model: .previewContainers)
    .frame(width: 1120, height: 720)
}
