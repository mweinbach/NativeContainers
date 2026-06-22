import Observation
import SwiftUI

struct KubernetesResourcesSection: View {
  let workloadCount: Int?
  let podCount: Int?
  let serviceCount: Int?
  let capturedAt: Date?
  let isBusy: Bool
  let onBrowse: () -> Void

  var body: some View {
    Section("Cluster resources") {
      if let workloadCount, let podCount, let serviceCount {
        LabeledContent("Workloads") {
          Text(workloadCount, format: .number)
            .monospacedDigit()
        }
        LabeledContent("Pods") {
          Text(podCount, format: .number)
            .monospacedDigit()
        }
        LabeledContent("Services") {
          Text(serviceCount, format: .number)
            .monospacedDigit()
        }
        if let capturedAt {
          LabeledContent("Last loaded") {
            Text(capturedAt, format: .dateTime.hour().minute().second())
          }
        }
      } else {
        Text(
          "Load a bounded, read-only inventory directly from K3s without exporting kubeconfig or reading Kubernetes secrets."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button("Browse Resources…", systemImage: "square.grid.2x2") {
        onBrowse()
      }
      .disabled(isBusy)
    }
  }
}

struct KubernetesResourceBrowserView: View {
  let model: KubernetesClusterModel

  @Environment(\.dismiss) private var dismiss
  @State private var browser = KubernetesResourceBrowserModel()
  @State private var selectedPod: KubernetesPodRecord?
  @State private var workloadToScale: KubernetesWorkloadRecord?
  @State private var workloadToRestart: KubernetesWorkloadRecord?
  @State private var workloadToDelete: KubernetesWorkloadRecord?

  var body: some View {
    @Bindable var browser = browser

    NavigationStack {
      VStack(spacing: 0) {
        Picker("Resource type", selection: $browser.selection) {
          ForEach(KubernetesResourceKind.allCases) { kind in
            Text(kind.title)
              .tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .padding()

        Divider()

        KubernetesResourceBrowserContent(
          selection: browser.selection,
          workloads: browser.visibleWorkloads,
          pods: browser.visiblePods,
          services: browser.visibleServices,
          hasInventory: model.resourceInventory != nil,
          isLoading: model.isLoadingResources,
          isBusy: model.isBusy,
          errorMessage: model.resourceErrorMessage,
          hasSearchText: browser.hasSearchQuery,
          onRetry: {
            Task {
              await refreshResources()
            }
          },
          onViewPodLogs: { pod in
            selectedPod = pod
          },
          onScaleWorkload: { workload in
            model.clearResourceError()
            workloadToScale = workload
          },
          onRestartWorkload: { workload in
            model.clearResourceError()
            workloadToRestart = workload
          },
          onDeleteWorkload: { workload in
            model.clearResourceError()
            workloadToDelete = workload
          }
        )
      }
      .navigationTitle("Kubernetes Resources")
      .searchable(
        text: $browser.searchText,
        placement: .automatic,
        prompt: "Search resources"
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh Resources", systemImage: "arrow.clockwise") {
            Task {
              await refreshResources()
            }
          }
          .disabled(model.isBusy)
        }
      }
    }
    .frame(minWidth: 760, minHeight: 560)
    .task {
      await refreshResources()
    }
    .sheet(item: $selectedPod) { pod in
      KubernetesPodLogsView(clusterModel: model, pod: pod)
    }
    .sheet(
      item: $workloadToScale,
      onDismiss: {
        browser.replaceInventory(model.resourceInventory)
      },
      content: { workload in
        KubernetesWorkloadScaleView(
          model: model,
          workload: workload
        )
      }
    )
    .sheet(
      item: $workloadToRestart,
      onDismiss: {
        browser.replaceInventory(model.resourceInventory)
      },
      content: { workload in
        KubernetesWorkloadRestartView(
          model: model,
          workload: workload
        )
      }
    )
    .sheet(
      item: $workloadToDelete,
      onDismiss: {
        browser.replaceInventory(model.resourceInventory)
      },
      content: { workload in
        KubernetesWorkloadDeleteView(
          model: model,
          workload: workload
        )
      }
    )
  }

  private func refreshResources() async {
    await model.loadResources()
    browser.replaceInventory(model.resourceInventory)
  }
}

private enum KubernetesResourceKind: String, CaseIterable, Identifiable {
  case workloads
  case pods
  case services

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .workloads:
      "Workloads"
    case .pods:
      "Pods"
    case .services:
      "Services"
    }
  }
}

@MainActor
@Observable
private final class KubernetesResourceBrowserModel {
  var selection = KubernetesResourceKind.workloads
  var searchText = "" {
    didSet {
      recomputeVisibleResources()
    }
  }

  private(set) var hasSearchQuery = false
  private(set) var visibleWorkloads: [KubernetesWorkloadRecord] = []
  private(set) var visiblePods: [KubernetesPodRecord] = []
  private(set) var visibleServices: [KubernetesServiceRecord] = []

  @ObservationIgnored
  private var inventory: KubernetesResourceInventory?

  func replaceInventory(_ inventory: KubernetesResourceInventory?) {
    self.inventory = inventory
    recomputeVisibleResources()
  }

  private func recomputeVisibleResources() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    hasSearchQuery = !query.isEmpty

    guard let inventory else {
      visibleWorkloads = []
      visiblePods = []
      visibleServices = []
      return
    }

    guard hasSearchQuery else {
      visibleWorkloads = inventory.workloads
      visiblePods = inventory.pods
      visibleServices = inventory.services
      return
    }

    visibleWorkloads = inventory.workloads.filter {
      matches(
        query,
        values: [$0.namespace, $0.name, $0.kind.rawValue]
      )
    }
    visiblePods = inventory.pods.filter {
      matches(
        query,
        values: [
          $0.namespace,
          $0.name,
          $0.phase.rawValue,
          $0.nodeName ?? "",
        ]
      )
    }
    visibleServices = inventory.services.filter {
      matches(
        query,
        values: [
          $0.namespace,
          $0.name,
          $0.type,
          $0.clusterIP ?? "",
        ]
      )
    }
  }

  private func matches(_ query: String, values: [String]) -> Bool {
    values.contains {
      $0.localizedCaseInsensitiveContains(query)
    }
  }
}

private struct KubernetesResourceBrowserContent: View {
  let selection: KubernetesResourceKind
  let workloads: [KubernetesWorkloadRecord]
  let pods: [KubernetesPodRecord]
  let services: [KubernetesServiceRecord]
  let hasInventory: Bool
  let isLoading: Bool
  let isBusy: Bool
  let errorMessage: String?
  let hasSearchText: Bool
  let onRetry: () -> Void
  let onViewPodLogs: (KubernetesPodRecord) -> Void
  let onScaleWorkload: (KubernetesWorkloadRecord) -> Void
  let onRestartWorkload: (KubernetesWorkloadRecord) -> Void
  let onDeleteWorkload: (KubernetesWorkloadRecord) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        KubernetesResourceErrorBanner(
          message: errorMessage,
          onRetry: onRetry
        )
      }

      if !hasInventory && isLoading {
        KubernetesResourceLoadingView()
      } else if !hasInventory {
        KubernetesResourceUnavailableView(onRetry: onRetry)
      } else {
        switch selection {
        case .workloads:
          KubernetesWorkloadList(
            workloads: workloads,
            hasSearchText: hasSearchText,
            isBusy: isBusy,
            onScale: onScaleWorkload,
            onRestart: onRestartWorkload,
            onDelete: onDeleteWorkload
          )
        case .pods:
          KubernetesPodList(
            pods: pods,
            hasSearchText: hasSearchText,
            onViewLogs: onViewPodLogs
          )
        case .services:
          KubernetesServiceList(
            services: services,
            hasSearchText: hasSearchText
          )
        }
      }
    }
  }
}

private struct KubernetesResourceErrorBanner: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .textSelection(.enabled)
      Spacer()
      Button("Retry", action: onRetry)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.08))
  }
}

private struct KubernetesResourceLoadingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading Kubernetes resources…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct KubernetesResourceUnavailableView: View {
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "square.grid.2x2")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Resources are unavailable")
        .font(.headline)
      Text("Start the cluster and try loading its inventory again.")
        .foregroundStyle(.secondary)
      Button("Try Again", action: onRetry)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

private struct KubernetesWorkloadList: View {
  let workloads: [KubernetesWorkloadRecord]
  let hasSearchText: Bool
  let isBusy: Bool
  let onScale: (KubernetesWorkloadRecord) -> Void
  let onRestart: (KubernetesWorkloadRecord) -> Void
  let onDelete: (KubernetesWorkloadRecord) -> Void

  var body: some View {
    if workloads.isEmpty {
      KubernetesResourceEmptyView(
        title: hasSearchText ? "No matching workloads" : "No workloads",
        systemImage: "square.stack.3d.up",
        description:
          hasSearchText
          ? "Try a different name or namespace."
          : "The cluster has no Deployments, StatefulSets, DaemonSets, or Jobs."
      )
    } else {
      List(workloads) { workload in
        KubernetesWorkloadRow(
          namespace: workload.namespace,
          name: workload.name,
          kind: workload.kind,
          desiredCount: workload.desiredCount,
          readyCount: workload.readyCount,
          availableCount: workload.availableCount,
          failedCount: workload.failedCount,
          canScale: workload.kind.supportsScaling,
          canRestart: workload.kind.supportsRestart,
          isBusy: isBusy,
          onScale: {
            onScale(workload)
          },
          onRestart: {
            onRestart(workload)
          },
          onDelete: {
            onDelete(workload)
          }
        )
      }
      .listStyle(.inset)
    }
  }
}

private struct KubernetesWorkloadRow: View {
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind
  let desiredCount: Int
  let readyCount: Int
  let availableCount: Int
  let failedCount: Int
  let canScale: Bool
  let canRestart: Bool
  let isBusy: Bool
  let onScale: () -> Void
  let onRestart: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind.systemImage)
        .foregroundStyle(kind.tint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.headline)
          .textSelection(.enabled)
        Text(namespace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text(kind.title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(readinessDescription)
          .monospacedDigit()
        if failedCount > 0 {
          Text("\(failedCount) failed")
            .font(.caption)
            .foregroundStyle(.red)
            .monospacedDigit()
        } else if kind == .job {
          Text("\(availableCount) active")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else {
          Text("\(availableCount) available")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }

      Menu("Actions", systemImage: "ellipsis.circle") {
        if canScale {
          Button("Scale…", systemImage: "arrow.up.arrow.down", action: onScale)
        }
        if canRestart {
          Button(
            "Restart…",
            systemImage: "arrow.trianglehead.2.clockwise",
            action: onRestart
          )
        }
        if canScale || canRestart {
          Divider()
        }
        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(isBusy)
    }
    .padding(.vertical, 4)
  }

  private var readinessDescription: LocalizedStringResource {
    if kind == .job {
      "\(readyCount) of \(desiredCount) succeeded"
    } else {
      "\(readyCount) of \(desiredCount) ready"
    }
  }
}

private struct KubernetesWorkloadScaleView: View {
  @Environment(\.dismiss) private var dismiss

  let model: KubernetesClusterModel
  let workload: KubernetesWorkloadRecord

  @State private var targetReplicas: Int
  @State private var isSubmitting = false

  init(
    model: KubernetesClusterModel,
    workload: KubernetesWorkloadRecord
  ) {
    self.model = model
    self.workload = workload
    _targetReplicas = State(initialValue: workload.desiredCount)
  }

  var body: some View {
    NavigationStack {
      Form {
        KubernetesWorkloadIdentitySection(
          name: workload.name,
          namespace: workload.namespace,
          kind: workload.kind
        )
        KubernetesWorkloadScaleReplicaSection(
          currentReplicas: workload.desiredCount,
          targetReplicas: $targetReplicas
        )

        if let errorMessage = model.resourceErrorMessage {
          KubernetesWorkloadMutationErrorSection(
            title: "Scale failed",
            message: errorMessage
          )
        }

        if isSubmitting {
          KubernetesWorkloadMutationProgressSection(
            title: "Scaling workload…"
          )
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Scale Workload")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Scale to \(targetReplicas)") {
            submit()
          }
          .disabled(
            isSubmitting
              || targetReplicas == workload.desiredCount
          )
        }
      }
    }
    .frame(minWidth: 480, minHeight: 390)
    .interactiveDismissDisabled(isSubmitting)
  }

  private func submit() {
    guard
      !isSubmitting,
      targetReplicas != workload.desiredCount
    else {
      return
    }
    isSubmitting = true
    Task {
      let succeeded = await model.scaleWorkload(
        workload,
        to: targetReplicas
      )
      isSubmitting = false
      if succeeded {
        dismiss()
      }
    }
  }
}

private struct KubernetesWorkloadRestartView: View {
  @Environment(\.dismiss) private var dismiss

  let model: KubernetesClusterModel
  let workload: KubernetesWorkloadRecord

  @State private var isSubmitting = false

  var body: some View {
    NavigationStack {
      Form {
        KubernetesWorkloadIdentitySection(
          name: workload.name,
          namespace: workload.namespace,
          kind: workload.kind
        )
        KubernetesWorkloadRestartEffectSection()

        if let errorMessage = model.resourceErrorMessage {
          KubernetesWorkloadMutationErrorSection(
            title: "Restart failed",
            message: errorMessage
          )
        }

        if isSubmitting {
          KubernetesWorkloadMutationProgressSection(
            title: "Restarting workload…"
          )
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Restart Workload")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Restart Workload") {
            submit()
          }
          .disabled(isSubmitting)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .interactiveDismissDisabled(isSubmitting)
  }

  private func submit() {
    guard !isSubmitting else { return }
    isSubmitting = true
    Task {
      let succeeded = await model.restartWorkload(workload)
      isSubmitting = false
      if succeeded {
        dismiss()
      }
    }
  }
}

private struct KubernetesWorkloadDeleteView: View {
  private static let systemNamespaces: Set<String> = [
    "kube-system",
    "kube-public",
    "kube-node-lease",
  ]

  @Environment(\.dismiss) private var dismiss

  let model: KubernetesClusterModel
  let workload: KubernetesWorkloadRecord

  @State private var confirmationText = ""
  @State private var isSubmitting = false

  var body: some View {
    NavigationStack {
      Form {
        KubernetesWorkloadIdentitySection(
          name: workload.name,
          namespace: workload.namespace,
          kind: workload.kind
        )
        KubernetesWorkloadDeleteEffectSection(
          isSystemNamespace: Self.systemNamespaces.contains(workload.namespace)
        )
        KubernetesWorkloadDeleteConfirmationSection(
          workloadName: workload.name,
          confirmationText: $confirmationText
        )

        if let errorMessage = model.resourceErrorMessage {
          KubernetesWorkloadMutationErrorSection(
            title: "Deletion failed",
            message: errorMessage
          )
        }

        if isSubmitting {
          KubernetesWorkloadMutationProgressSection(
            title: "Deleting workload…"
          )
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Delete Workload")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Delete Workload", role: .destructive) {
            submit()
          }
          .disabled(
            isSubmitting
              || confirmationText != workload.name
          )
        }
      }
    }
    .frame(minWidth: 500, minHeight: 430)
    .interactiveDismissDisabled(isSubmitting)
  }

  private func submit() {
    guard
      !isSubmitting,
      confirmationText == workload.name
    else {
      return
    }
    isSubmitting = true
    Task {
      let succeeded = await model.deleteWorkload(workload)
      isSubmitting = false
      if succeeded {
        dismiss()
      }
    }
  }
}

private struct KubernetesWorkloadDeleteEffectSection: View {
  let isSystemNamespace: Bool

  var body: some View {
    Section {
      Label(
        "This permanently deletes the workload controller and deletes its managed dependents, including Pods, in the foreground.",
        systemImage: "trash"
      )
      .foregroundStyle(.red)
      Label(
        "Force deletion is not used. Kubernetes applies default graceful termination and waits for dependents and finalizers.",
        systemImage: "shield"
      )
      if isSystemNamespace {
        Label(
          "This workload is in a Kubernetes system namespace. Deleting it can make the cluster unavailable.",
          systemImage: "exclamationmark.octagon.fill"
        )
        .foregroundStyle(.red)
      }
    } header: {
      Text("Deletion behavior")
    } footer: {
      Text(
        "Deletion commits only if both the workload UID and resource version still match this review. A same-name replacement is never deleted."
      )
    }
  }
}

private struct KubernetesWorkloadDeleteConfirmationSection: View {
  let workloadName: String
  @Binding var confirmationText: String

  var body: some View {
    Section("Confirm deletion") {
      TextField("Workload name", text: $confirmationText)
    } footer: {
      Text("Enter the exact workload name “\(workloadName)” to enable deletion.")
    }
  }
}

private struct KubernetesWorkloadIdentitySection: View {
  let name: String
  let namespace: String
  let kind: KubernetesWorkloadKind

  var body: some View {
    Section("Workload") {
      LabeledContent("Name", value: name)
      LabeledContent("Namespace", value: namespace)
      LabeledContent("Kind") {
        Text(kind.title)
      }
    }
  }
}

private struct KubernetesWorkloadScaleReplicaSection: View {
  let currentReplicas: Int
  @Binding var targetReplicas: Int

  var body: some View {
    Section {
      LabeledContent("Current") {
        Text(currentReplicas, format: .number)
          .monospacedDigit()
      }
      LabeledContent("Target") {
        Stepper(
          value: $targetReplicas,
          in: 0...KubernetesWorkloadScaleRequest.maximumReplicaCount
        ) {
          Text(targetReplicas, format: .number)
            .monospacedDigit()
        }
      }
      if targetReplicas == 0 {
        Label(
          "Scaling to zero stops every replica of this workload.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
      }
    } header: {
      Text("Replica count")
    } footer: {
      Text(
        "The scale commits only if the workload UID, resource version, and current replica count still match this review."
      )
    }
  }
}

private struct KubernetesWorkloadRestartEffectSection: View {
  var body: some View {
    Section {
      Label(
        "Kubernetes will create a new rollout by changing only the Pod-template restart annotation.",
        systemImage: "arrow.trianglehead.2.clockwise"
      )
      Label(
        "Managed Pods may be replaced and temporarily unavailable during the rollout.",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.orange)
    } header: {
      Text("Restart behavior")
    } footer: {
      Text(
        "The replace commits only if the workload UID and resource version still match this review. The controller then follows its configured update strategy; OnDelete strategies do not replace existing Pods automatically."
      )
    }
  }
}

private struct KubernetesWorkloadMutationErrorSection: View {
  let title: LocalizedStringResource
  let message: String

  var body: some View {
    Section {
      Text(message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
    } header: {
      Text(title)
    }
  }
}

private struct KubernetesWorkloadMutationProgressSection: View {
  let title: LocalizedStringResource

  var body: some View {
    Section {
      ProgressView {
        Text(title)
      }
    }
  }
}

private struct KubernetesPodList: View {
  let pods: [KubernetesPodRecord]
  let hasSearchText: Bool
  let onViewLogs: (KubernetesPodRecord) -> Void

  var body: some View {
    if pods.isEmpty {
      KubernetesResourceEmptyView(
        title: hasSearchText ? "No matching pods" : "No pods",
        systemImage: "shippingbox",
        description:
          hasSearchText
          ? "Try a different name, namespace, phase, or node."
          : "The cluster has no pods."
      )
    } else {
      List(pods) { pod in
        KubernetesPodRow(
          namespace: pod.namespace,
          name: pod.name,
          phase: pod.phase,
          readyContainerCount: pod.readyContainerCount,
          containerCount: pod.containerCount,
          restartCount: pod.restartCount,
          nodeName: pod.nodeName,
          onViewLogs: {
            onViewLogs(pod)
          }
        )
      }
      .listStyle(.inset)
    }
  }
}

private struct KubernetesPodRow: View {
  let namespace: String
  let name: String
  let phase: KubernetesPodPhase
  let readyContainerCount: Int
  let containerCount: Int
  let restartCount: Int
  let nodeName: String?
  let onViewLogs: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "shippingbox")
        .foregroundStyle(phase.tint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.headline)
          .textSelection(.enabled)
        Text(namespace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Label(phase.title, systemImage: phase.systemImage)
          .foregroundStyle(phase.tint)
        Text("\(readyContainerCount) of \(containerCount) containers ready")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if restartCount > 0 {
          Text("\(restartCount) restarts")
            .font(.caption)
            .foregroundStyle(.orange)
            .monospacedDigit()
        }
        if let nodeName {
          Text(nodeName)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
      }

      Button("View Logs", systemImage: "doc.plaintext", action: onViewLogs)
        .buttonStyle(.borderless)
        .disabled(containerCount == 0)
    }
    .padding(.vertical, 4)
  }
}

private struct KubernetesServiceList: View {
  let services: [KubernetesServiceRecord]
  let hasSearchText: Bool

  var body: some View {
    if services.isEmpty {
      KubernetesResourceEmptyView(
        title: hasSearchText ? "No matching services" : "No services",
        systemImage: "network",
        description:
          hasSearchText
          ? "Try a different name, namespace, type, or cluster address."
          : "The cluster has no services."
      )
    } else {
      List(services) { service in
        KubernetesServiceRow(
          namespace: service.namespace,
          name: service.name,
          type: service.type,
          clusterIP: service.clusterIP,
          portCount: service.ports.count,
          primaryPort: service.ports.first
        )
      }
      .listStyle(.inset)
    }
  }
}

private struct KubernetesServiceRow: View {
  let namespace: String
  let name: String
  let type: String
  let clusterIP: String?
  let portCount: Int
  let primaryPort: KubernetesServicePortRecord?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "network")
        .foregroundStyle(.blue)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.headline)
          .textSelection(.enabled)
        Text(namespace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text(type)
        if let clusterIP {
          Text(clusterIP)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospaced()
            .textSelection(.enabled)
        }
        if let primaryPort {
          Text(
            "\(primaryPort.protocolName) \(primaryPort.port) → \(primaryPort.targetPort)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          if portCount > 1 {
            Text("\(portCount) ports total")
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
        } else {
          Text("\(portCount) ports")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .padding(.vertical, 4)
  }
}

private struct KubernetesResourceEmptyView: View {
  let title: LocalizedStringResource
  let systemImage: String
  let description: LocalizedStringResource

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(description)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

extension KubernetesWorkloadKind {
  fileprivate var systemImage: String {
    switch self {
    case .deployment:
      "square.stack.3d.up"
    case .statefulSet:
      "externaldrive.connected.to.line.below"
    case .daemonSet:
      "circle.grid.3x3"
    case .job:
      "checklist"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .deployment:
      .blue
    case .statefulSet:
      .purple
    case .daemonSet:
      .indigo
    case .job:
      .teal
    }
  }
}

extension KubernetesPodPhase {
  fileprivate var systemImage: String {
    switch self {
    case .pending:
      "clock"
    case .running:
      "checkmark.circle.fill"
    case .succeeded:
      "checkmark.seal.fill"
    case .failed:
      "xmark.octagon.fill"
    case .unknown:
      "questionmark.circle"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .pending:
      .orange
    case .running, .succeeded:
      .green
    case .failed:
      .red
    case .unknown:
      .secondary
    }
  }
}
