import SwiftUI

struct NetworksView: View {
  let appModel: AppModel
  @State private var operations: NetworkManagementModel
  @State private var isShowingCreation = false
  @State private var deletionPlan: NetworkDeletionPlan?
  @State private var prunePlan: NetworkPrunePlan?
  @State private var operationTask: Task<Void, Never>?

  init(model: AppModel) {
    appModel = model
    _operations = State(initialValue: model.makeNetworkManagementModel())
  }

  var body: some View {
    Group {
      if appModel.networks.isEmpty {
        ContentUnavailableView(
          "No networks",
          systemImage: "network",
          description: Text(
            "Apple’s built-in container network appears when the runtime is initialized.")
        )
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(appModel.networks) { network in
                Button {
                  appModel.navigate(to: .network(network.id))
                } label: {
                  NetworkRow(
                    name: network.name,
                    mode: network.mode,
                    subnet: network.assignedIPv4Subnet,
                    isBuiltin: network.isBuiltin,
                    consumerCount: network.usedByContainerIDs.count
                  )
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .background(
                  selectedNetworkID == network.id
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 9)
                )
                .contextMenu {
                  Button("Review Deletion…", systemImage: "trash", role: .destructive) {
                    prepareDeletion(network.id)
                  }
                  .disabled(
                    operations.isWorking
                      || operationTask != nil
                      || network.isBuiltin
                      || !network.usedByContainerIDs.isEmpty
                  )
                }
              }
            }
            .padding(.vertical, 8)
          }
          .frame(minWidth: 330, idealWidth: 390)
          .background(.background.secondary)

          if let network = selectedNetwork {
            NetworkInspector(
              network: network,
              isOperationActive: operations.isWorking || operationTask != nil,
              onDelete: { prepareDeletion(network.id) }
            )
            .frame(minWidth: 430)
          } else {
            ContentUnavailableView(
              "Select a network",
              systemImage: "sidebar.right",
              description: Text("Inspect topology, assigned addresses, metadata, and consumers.")
            )
            .frame(minWidth: 430)
          }
        }
        .onChange(of: appModel.networks, initial: true) {
          synchronizeSelection()
        }
      }
    }
    .navigationTitle("Networks")
    .overlay(alignment: .bottomLeading) {
      VStack(alignment: .leading, spacing: 8) {
        if let cleanupResult = operations.cleanupResult {
          InfrastructureCleanupBanner(result: cleanupResult)
        }
        if let errorMessage = operations.errorMessage {
          InfrastructureErrorBanner(message: errorMessage)
        }
      }
      .padding()
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if operationTask != nil {
          Button("Cancel Operation", systemImage: "xmark.circle") {
            operationTask?.cancel()
          }
          .help("Cancel the active network operation")
        }
        Button("Prune Networks", systemImage: "trash.slash") {
          preparePrune()
        }
        .disabled(
          operations.isWorking
            || operationTask != nil
            || appModel.networks.allSatisfy(\.isBuiltin)
        )
        Button("New Network", systemImage: "plus") {
          isShowingCreation = true
        }
        .disabled(operations.isWorking || operationTask != nil)
      }
    }
    .onDisappear {
      operationTask?.cancel()
    }
    .sheet(isPresented: $isShowingCreation) {
      NetworkCreationView(model: operations)
    }
    .confirmationDialog(
      "Delete network?",
      isPresented: deletionPlanPresentation,
      presenting: deletionPlan
    ) { plan in
      Button("Delete \(plan.network.name)", role: .destructive) {
        deletionPlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          _ = await operations.deleteReviewedNetwork(plan)
        }
      }
    } message: { plan in
      Text(
        "Containers will no longer be able to join \(plan.network.name). Existing referring containers block this operation."
      )
    }
    .confirmationDialog(
      "Prune unused networks?",
      isPresented: prunePlanPresentation,
      presenting: prunePlan
    ) { plan in
      Button("Delete \(plan.candidates.count) Networks", role: .destructive) {
        prunePlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          _ = await operations.pruneReviewedNetworks(plan)
        }
      }
      .disabled(plan.candidates.isEmpty)
    } message: { plan in
      Text(
        "NativeContainers revalidates and removes only these reviewed, non-built-in networks with no container references: \(plan.candidates.map(\.network.name).formatted())."
      )
    }
  }

  private var selectedNetwork: NetworkRecord? {
    appModel.networks.first { $0.id == selectedNetworkID }
  }

  private var selectedNetworkID: NetworkRecord.ID? {
    guard case .network(let id) = appModel.workspaceRoute else { return nil }
    return id
  }

  private var deletionPlanPresentation: Binding<Bool> {
    Binding(
      get: { deletionPlan != nil },
      set: { if !$0 { deletionPlan = nil } }
    )
  }

  private var prunePlanPresentation: Binding<Bool> {
    Binding(
      get: { prunePlan != nil },
      set: { if !$0 { prunePlan = nil } }
    )
  }

  private func synchronizeSelection() {
    guard selectedNetwork == nil else { return }
    if let id = appModel.networks.first?.id {
      appModel.navigate(to: .network(id))
    }
  }

  private func prepareDeletion(_ id: String) {
    guard operationTask == nil, !operations.isWorking else { return }
    operationTask = Task {
      defer { operationTask = nil }
      deletionPlan = await operations.prepareDeletion(id: id)
    }
  }

  private func preparePrune() {
    guard operationTask == nil, !operations.isWorking else { return }
    operationTask = Task {
      defer { operationTask = nil }
      prunePlan = await operations.preparePrune()
    }
  }
}

#Preview("Networks") {
  NavigationStack {
    NetworksView(model: .preview)
  }
  .frame(width: 980, height: 680)
}

struct NetworkRow: View {
  let name: String
  let mode: ContainerNetworkMode
  let subnet: String
  let isBuiltin: Bool
  let consumerCount: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "network")
        .font(.title2)
        .foregroundStyle(.teal)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(name)
            .font(.headline)
          if isBuiltin {
            Text("Built-in")
              .font(.caption)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
          }
        }
        Text("\(mode.title) · \(subnet)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if consumerCount > 0 {
        Label("\(consumerCount)", systemImage: "shippingbox")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }
}

struct NetworkInspector: View {
  let network: NetworkRecord
  let isOperationActive: Bool
  let onDelete: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        NetworkInspectorHeader(
          name: network.name,
          mode: network.mode,
          isBuiltin: network.isBuiltin,
          canDelete:
            !isOperationActive && !network.isBuiltin && network.usedByContainerIDs.isEmpty,
          onDelete: onDelete
        )
        NetworkAddressSection(
          configuredIPv4Subnet: network.configuredIPv4Subnet,
          configuredIPv6Subnet: network.configuredIPv6Subnet,
          assignedIPv4Subnet: network.assignedIPv4Subnet,
          assignedIPv6Subnet: network.assignedIPv6Subnet,
          ipv4Gateway: network.ipv4Gateway
        )
        NetworkProviderSection(
          plugin: network.plugin,
          createdAt: network.createdAt
        )
        InfrastructureConsumersSection(
          title: "Container references",
          resourceNames: network.usedByContainerIDs,
          emptyMessage: "No container configuration references this network."
        )
        InfrastructureMetadataSection(
          labels: network.labels,
          options: network.options
        )
      }
      .padding(24)
    }
  }
}

struct NetworkInspectorHeader: View {
  let name: String
  let mode: ContainerNetworkMode
  let isBuiltin: Bool
  let canDelete: Bool
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "network")
        .font(.largeTitle)
        .foregroundStyle(.teal)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(name)
            .font(.title.bold())
            .textSelection(.enabled)
          if isBuiltin {
            Text("Built-in")
              .font(.caption)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
          }
        }
        Text(mode == .nat ? "NAT container network" : "Host-only container network")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        .disabled(!canDelete)
        .help(deleteHelp)
    }
  }

  private var deleteHelp: String {
    if isBuiltin {
      return "Apple’s built-in network cannot be deleted"
    }
    return canDelete ? "Review network deletion" : "Remove all referring containers first"
  }
}

struct NetworkAddressSection: View {
  let configuredIPv4Subnet: String?
  let configuredIPv6Subnet: String?
  let assignedIPv4Subnet: String
  let assignedIPv6Subnet: String?
  let ipv4Gateway: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Addresses")
        .font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
        GridRow {
          LabeledContent("Assigned IPv4", value: assignedIPv4Subnet)
          LabeledContent("IPv4 gateway", value: ipv4Gateway)
        }
        GridRow {
          LabeledContent("Requested IPv4", value: configuredIPv4Subnet ?? "Automatic")
          LabeledContent("Requested IPv6", value: configuredIPv6Subnet ?? "Disabled")
        }
        if let assignedIPv6Subnet {
          GridRow {
            LabeledContent("Assigned IPv6", value: assignedIPv6Subnet)
            Color.clear
          }
        }
      }
      .textSelection(.enabled)
    }
  }
}

struct NetworkProviderSection: View {
  let plugin: String
  let createdAt: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Provider")
        .font(.headline)
      LabeledContent("Plugin", value: plugin)
        .textSelection(.enabled)
      LabeledContent("Created") {
        Text(createdAt, format: .dateTime.year().month().day().hour().minute())
      }
    }
  }
}

struct NetworkCreationView: View {
  @Environment(\.dismiss) private var dismiss
  let model: NetworkManagementModel
  @State private var name = ""
  @State private var mode = ContainerNetworkMode.nat
  @State private var ipv4Subnet = ""
  @State private var ipv6Subnet = ""
  @State private var labelsText = ""
  @State private var validationMessage: String?
  @State private var reviewedPlan: NetworkCreationPlan?
  @State private var operationTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Network") {
          TextField("Name", text: $name, prompt: Text("backend"))
          Picker("Mode", selection: $mode) {
            ForEach(ContainerNetworkMode.allCases) { candidate in
              Text(candidate.title).tag(candidate)
            }
          }
          Text(
            mode == .nat
              ? "NAT networks can reach external services through the host."
              : "Host-only networks isolate traffic to containers on the same subnet."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Address allocation") {
          TextField(
            "IPv4 subnet",
            text: $ipv4Subnet,
            prompt: Text("Automatic, or 192.168.100.0/24")
          )
          TextField(
            "IPv6 subnet",
            text: $ipv6Subnet,
            prompt: Text("Disabled, or fd00:100::/64")
          )
          Text(
            "Apple’s network service assigns container addresses; static per-container IP requests are not exposed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Labels") {
          TextEditor(text: $labelsText)
            .font(.body.monospaced())
            .frame(minHeight: 90)
          Text("Optional KEY=value metadata, one entry per line.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking || operationTask != nil)
      .navigationTitle("New Network")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.isWorking || operationTask != nil {
            Button("Cancel Operation") {
              operationTask?.cancel()
            }
          } else {
            Button("Cancel") { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Review") { review() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || operationTask != nil || name.isEmpty)
        }
      }
    }
    .frame(minWidth: 580, minHeight: 590)
    .interactiveDismissDisabled(model.isWorking || operationTask != nil)
    .confirmationDialog(
      "Create network?",
      isPresented: reviewedPlanPresentation,
      presenting: reviewedPlan
    ) { plan in
      Button("Create \(plan.request.name)") {
        guard operationTask == nil else { return }
        reviewedPlan = nil
        operationTask = Task {
          defer { operationTask = nil }
          if await model.createReviewedNetwork(plan) {
            dismiss()
          }
        }
      }
    } message: { plan in
      Text(
        "Create a \(plan.request.mode.title.lowercased()) network using Apple’s container-network-vmnet plugin."
      )
    }
  }

  private var reviewedPlanPresentation: Binding<Bool> {
    Binding(
      get: { reviewedPlan != nil },
      set: { if !$0 { reviewedPlan = nil } }
    )
  }

  private func review() {
    guard operationTask == nil, !model.isWorking else { return }
    do {
      let labels = try ResourceMetadataParser.parse(labelsText)
      let request = try NetworkCreateRequest(
        name: name,
        mode: mode,
        ipv4Subnet: ipv4Subnet,
        ipv6Subnet: ipv6Subnet,
        labels: labels
      )
      validationMessage = nil
      operationTask = Task {
        defer { operationTask = nil }
        reviewedPlan = await model.prepareCreation(request)
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}
