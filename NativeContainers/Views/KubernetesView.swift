import SwiftUI
import UniformTypeIdentifiers

struct KubernetesView: View {
  let model: KubernetesClusterModel

  @State private var presentsProvisioning = false
  @State private var presentsResourceBrowser = false
  @State private var confirmsDeletion = false
  @State private var confirmsForceStop = false
  @State private var confirmsForget = false
  @State private var exportDocument: KubernetesKubeconfigDocument?
  @State private var exportFileName = "NativeContainers-kubeconfig.yaml"
  @State private var presentsExporter = false
  @State private var exportErrorMessage: String?

  var body: some View {
    Form {
      KubernetesStatusSection(
        state: model.snapshot.state,
        detail: model.snapshot.detail,
        progress: model.progress,
        isBusy: model.isBusy
      )

      if model.snapshot.state == .absent {
        KubernetesSetupSection {
          model.beginProvisioning()
          presentsProvisioning = true
        }
      } else {
        KubernetesClusterDetailsSection(
          machineName: model.snapshot.machine?.id
            ?? model.snapshot.descriptor?.machine.id,
          imageReference: model.snapshot.machine?.imageReference
            ?? model.snapshot.descriptor?.machine.imageReference,
          machineState: model.snapshot.machine?.state,
          ipAddress: model.snapshot.machine?.ipAddress,
          k3sVersion: model.snapshot.k3sVersion
            ?? model.snapshot.descriptor?.distribution.version,
          readyNodeCount: model.snapshot.readyNodeCount,
          nodeCount: model.snapshot.nodeCount,
          runningPodCount: model.snapshot.runningPodCount,
          podCount: model.snapshot.podCount
        )

        if model.snapshot.state == .ready || model.snapshot.state == .degraded {
          KubernetesResourcesSection(
            workloadCount: model.resourceInventory?.workloads.count,
            podCount: model.resourceInventory?.pods.count,
            serviceCount: model.resourceInventory?.services.count,
            capturedAt: model.resourceInventory?.capturedAt,
            isBusy: model.isBusy,
            onBrowse: { presentsResourceBrowser = true }
          )
        }

        KubernetesClusterActionsSection(
          state: model.snapshot.state,
          machineState: model.snapshot.machine?.state,
          isBusy: model.isBusy,
          onRetry: { Task { await model.retryProvisioning() } },
          onStart: { Task { await model.start() } },
          onStop: { Task { await model.stop() } },
          onForceStop: { confirmsForceStop = true },
          onExport: prepareExport,
          onDelete: { confirmsDeletion = true },
          onForget: { confirmsForget = true }
        )
      }

      if let errorMessage = model.errorMessage ?? exportErrorMessage {
        Section("Operation error") {
          Text(errorMessage)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Kubernetes")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh Kubernetes", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .disabled(model.isBusy)
      }
    }
    .task {
      await model.refresh()
    }
    .sheet(isPresented: $presentsProvisioning) {
      KubernetesProvisioningView(model: model)
    }
    .sheet(isPresented: $presentsResourceBrowser) {
      KubernetesResourceBrowserView(model: model)
    }
    .alert(
      "Delete Kubernetes Cluster?",
      isPresented: $confirmsDeletion
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Cluster", role: .destructive) {
        Task { await model.delete() }
      }
    } message: {
      Text(
        "This gracefully stops and permanently deletes the dedicated Apple Linux machine and every Kubernetes workload and volume stored inside it."
      )
    }
    .alert(
      "Force Stop Kubernetes?",
      isPresented: $confirmsForceStop
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Force Stop", role: .destructive) {
        Task { await model.forceStop() }
      }
    } message: {
      Text(
        "KILL is sent only to the exact current backing container for the identity-pinned Kubernetes machine. Workloads may lose unwritten data."
      )
    }
    .alert(
      "Forget Kubernetes Record?",
      isPresented: $confirmsForget
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Forget Record", role: .destructive) {
        Task { await model.forget() }
      }
    } message: {
      Text(
        "This removes only NativeContainers’ private cluster binding. A replacement machine with the same name is never modified."
      )
    }
    .fileExporter(
      isPresented: $presentsExporter,
      document: exportDocument,
      contentType: .yaml,
      defaultFilename: exportFileName
    ) { result in
      exportDocument = nil
      if case .failure(let error) = result {
        exportErrorMessage = error.localizedDescription
      }
    }
  }

  private func prepareExport() {
    Task {
      guard let export = await model.prepareKubeconfigExport() else { return }
      exportDocument = KubernetesKubeconfigDocument(data: export.data)
      exportFileName = export.fileName
      exportErrorMessage = nil
      presentsExporter = true
    }
  }
}

private struct KubernetesStatusSection: View {
  let state: KubernetesClusterState
  let detail: String?
  let progress: KubernetesClusterProgress?
  let isBusy: Bool

  var body: some View {
    Section("Cluster status") {
      LabeledContent("Status") {
        Label(state.title, systemImage: state.systemImage)
          .foregroundStyle(state.tint)
      }

      if let progress {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(progress.phase.title)
            Spacer()
            if let fraction = progress.fractionCompleted {
              Text(fraction, format: .percent.precision(.fractionLength(0)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          ProgressView(value: progress.fractionCompleted)
          if let detail = progress.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else if isBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Updating Kubernetes")
      }

      if let detail {
        Label(detail, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
  }
}

private struct KubernetesSetupSection: View {
  let onConfigure: () -> Void

  var body: some View {
    Section("Dedicated local cluster") {
      Label(
        "K3s runs as a native Linux service inside one persistent Apple container machine.",
        systemImage: "circles.hexagongrid"
      )
      Text(
        "The cluster receives its own CPU, memory, disk, IP address, and lifecycle. Your Mac home directory is not mounted into the machine."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Set Up Kubernetes…", systemImage: "plus") {
        onConfigure()
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

private struct KubernetesClusterDetailsSection: View {
  let machineName: String?
  let imageReference: String?
  let machineState: RuntimeState?
  let ipAddress: String?
  let k3sVersion: String?
  let readyNodeCount: Int
  let nodeCount: Int
  let runningPodCount: Int
  let podCount: Int

  var body: some View {
    Section("Dedicated machine") {
      if let machineName {
        LabeledContent("Machine", value: machineName)
      }
      if let imageReference {
        LabeledContent("Image") {
          Text(imageReference)
            .textSelection(.enabled)
        }
      }
      if let machineState {
        LabeledContent("Machine state") {
          Text(machineState.title)
        }
      }
      if let ipAddress {
        LabeledContent("Address") {
          Text(ipAddress)
            .monospaced()
            .textSelection(.enabled)
        }
      }
      if let k3sVersion {
        LabeledContent("K3s") {
          Text(k3sVersion)
            .textSelection(.enabled)
        }
      }

      if nodeCount > 0 {
        LabeledContent("Nodes") {
          Text("\(readyNodeCount) of \(nodeCount) ready")
        }
      }
      if podCount > 0 {
        LabeledContent("Pods") {
          Text("\(runningPodCount) of \(podCount) running")
        }
      }

      Text(
        "Kubeconfig is read from the guest only when you export it. The API server address is rewritten in memory to the machine’s current dedicated IP."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct KubernetesClusterActionsSection: View {
  let state: KubernetesClusterState
  let machineState: RuntimeState?
  let isBusy: Bool
  let onRetry: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onForceStop: () -> Void
  let onExport: () -> Void
  let onDelete: () -> Void
  let onForget: () -> Void

  var body: some View {
    Section("Cluster actions") {
      ViewThatFits {
        HStack {
          KubernetesClusterActionButtons(
            state: state,
            machineState: machineState,
            onRetry: onRetry,
            onStart: onStart,
            onStop: onStop,
            onForceStop: onForceStop,
            onExport: onExport,
            onDelete: onDelete,
            onForget: onForget
          )
        }
        VStack(alignment: .leading) {
          KubernetesClusterActionButtons(
            state: state,
            machineState: machineState,
            onRetry: onRetry,
            onStart: onStart,
            onStop: onStop,
            onForceStop: onForceStop,
            onExport: onExport,
            onDelete: onDelete,
            onForget: onForget
          )
        }
      }
      .disabled(isBusy)

      if state == .provisioning {
        Text(
          "Retry is idempotent: it verifies the pinned installer again and resumes the existing exact machine rather than creating another cluster."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

private struct KubernetesClusterActionButtons: View {
  let state: KubernetesClusterState
  let machineState: RuntimeState?
  let onRetry: () -> Void
  let onStart: () -> Void
  let onStop: () -> Void
  let onForceStop: () -> Void
  let onExport: () -> Void
  let onDelete: () -> Void
  let onForget: () -> Void

  var body: some View {
    switch state {
    case .absent:
      EmptyView()
    case .provisioning:
      Button("Retry Setup", systemImage: "arrow.clockwise") {
        onRetry()
      }
      Button("Delete Cluster", systemImage: "trash", role: .destructive) {
        onDelete()
      }
      if machineState == .running || machineState == .stopping {
        Button("Force Stop", systemImage: "stop.fill", role: .destructive) {
          onForceStop()
        }
      }
    case .stopped:
      Button("Start", systemImage: "play.fill") {
        onStart()
      }
      Button("Delete Cluster", systemImage: "trash", role: .destructive) {
        onDelete()
      }
    case .ready, .degraded:
      Button("Stop", systemImage: "stop.fill") {
        onStop()
      }
      Button("Force Stop", systemImage: "exclamationmark.octagon", role: .destructive) {
        onForceStop()
      }
      Button("Export Kubeconfig…", systemImage: "square.and.arrow.up") {
        onExport()
      }
      Button("Delete Cluster", systemImage: "trash", role: .destructive) {
        onDelete()
      }
    case .missing, .stale:
      Button("Forget Record", systemImage: "trash", role: .destructive) {
        onForget()
      }
    }
  }
}

private struct KubernetesProvisioningView: View {
  let model: KubernetesClusterModel

  @Environment(\.dismiss) private var dismiss
  @State private var machineName =
    KubernetesClusterProvisionRequest.defaultMachineName
  @State private var imageReference =
    KubernetesClusterProvisionRequest.defaultImageReference
  @State private var cpuCount = 4
  @State private var memoryGiB = 4
  @State private var validationError: String?

  var body: some View {
    NavigationStack {
      Form {
        KubernetesProvisionIdentitySection(
          machineName: $machineName,
          imageReference: $imageReference
        )
        KubernetesProvisionResourceSection(
          cpuCount: $cpuCount,
          memoryGiB: $memoryGiB
        )
        KubernetesProvisionTrustSection()

        if let progress = model.progress {
          KubernetesProvisionProgressSection(progress: progress)
        }
        if let error = validationError ?? model.errorMessage {
          Section("Setup error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set Up Kubernetes")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(model.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create Cluster") {
            create()
          }
          .disabled(model.isBusy)
        }
      }
      .interactiveDismissDisabled(model.isWorking)
    }
    .frame(minWidth: 620, minHeight: 620)
  }

  private func create() {
    do {
      let request = try KubernetesClusterProvisionRequest(
        machineName: machineName,
        imageReference: imageReference,
        cpuCount: cpuCount,
        memoryBytes: UInt64(memoryGiB) * 1_024 * 1_024 * 1_024
      )
      validationError = nil
      Task {
        if await model.provision(request) {
          dismiss()
        }
      }
    } catch {
      validationError = error.localizedDescription
    }
  }
}

private struct KubernetesProvisionIdentitySection: View {
  @Binding var machineName: String
  @Binding var imageReference: String

  var body: some View {
    Section("Machine identity") {
      TextField("Machine name", text: $machineName)
        .textContentType(.username)
      TextField("OCI machine image", text: $imageReference)
        .textContentType(.URL)

      Text(
        "The image must support Apple container machines and provide either apk or apt-get. NativeContainers installs only the packages needed by K3s."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct KubernetesProvisionResourceSection: View {
  @Binding var cpuCount: Int
  @Binding var memoryGiB: Int

  var body: some View {
    Section("Resources") {
      Stepper(value: $cpuCount, in: 2...32) {
        LabeledContent("Virtual CPUs") {
          Text(cpuCount, format: .number)
            .monospacedDigit()
        }
      }
      Stepper(value: $memoryGiB, in: 2...64) {
        LabeledContent("Memory") {
          Text("\(memoryGiB) GiB")
            .monospacedDigit()
        }
      }
      Text(
        "K3s documents a two-core, 2 GiB minimum for a server. Four cores and 4 GiB leave useful room for local workloads."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct KubernetesProvisionTrustSection: View {
  var body: some View {
    Section("Pinned software") {
      LabeledContent("K3s release") {
        Text(KubernetesDistribution.current.version)
          .textSelection(.enabled)
      }
      LabeledContent("Installer SHA-256") {
        Text(KubernetesDistribution.current.installScriptSHA256)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      Text(
        "NativeContainers downloads the installer from the exact K3s release tag, verifies this embedded SHA-256 before execution, and lets the official installer verify the release binary checksum. Kubernetes secret encryption is enabled and kubeconfig remains mode 0600 in the guest."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct KubernetesProvisionProgressSection: View {
  let progress: KubernetesClusterProgress

  var body: some View {
    Section("Progress") {
      Text(progress.phase.title)
      ProgressView(value: progress.fractionCompleted)
      if let detail = progress.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct KubernetesKubeconfigDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.yaml]

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension KubernetesClusterState {
  fileprivate var systemImage: String {
    switch self {
    case .absent:
      "circle.dashed"
    case .provisioning:
      "arrow.trianglehead.2.clockwise.rotate.90"
    case .stopped:
      "stop.circle"
    case .ready:
      "checkmark.circle.fill"
    case .degraded:
      "exclamationmark.triangle.fill"
    case .missing:
      "questionmark.folder"
    case .stale:
      "exclamationmark.shield"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .ready:
      .green
    case .provisioning:
      .blue
    case .degraded, .missing, .stale:
      .orange
    case .absent, .stopped:
      .secondary
    }
  }
}

extension RuntimeState {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .unknown:
      "Unknown"
    case .stopped:
      "Stopped"
    case .running:
      "Running"
    case .stopping:
      "Stopping"
    }
  }
}

#Preview("Ready Kubernetes Cluster") {
  KubernetesView(
    model: KubernetesClusterModel(
      service: PreviewKubernetesClusterService(snapshot: .previewReady),
      initialSnapshot: .previewReady
    )
  )
  .frame(width: 760, height: 720)
}

#Preview("Kubernetes Setup") {
  KubernetesView(
    model: KubernetesClusterModel(
      service: PreviewKubernetesClusterService(snapshot: .absent)
    )
  )
  .frame(width: 760, height: 720)
}

#Preview("Kubernetes Resource Browser") {
  KubernetesResourceBrowserView(
    model: KubernetesClusterModel(
      service: PreviewKubernetesClusterService(snapshot: .previewReady),
      initialSnapshot: .previewReady
    )
  )
  .frame(width: 900, height: 640)
}

private struct PreviewKubernetesClusterService: KubernetesClusterManaging {
  let snapshot: KubernetesClusterSnapshot

  func load() async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func loadResourceInventory() async throws -> KubernetesResourceInventory {
    .preview
  }

  func loadPodLogs(
    _ request: KubernetesPodLogRequest
  ) async throws -> KubernetesPodLogSnapshot {
    KubernetesPodLogSnapshot(
      request: request,
      text: "2026-06-22T13:30:00Z preview log output\n",
      capturedAt: Date(),
      isTruncated: false
    )
  }

  func scaleWorkload(
    _ request: KubernetesWorkloadScaleRequest
  ) async throws -> KubernetesWorkloadScaleResult {
    KubernetesWorkloadScaleResult(
      request: request,
      resourceVersion: "preview-\(request.targetReplicas)",
      observedReplicas: request.targetReplicas,
      capturedAt: Date()
    )
  }

  func restartWorkload(
    _ request: KubernetesWorkloadRestartRequest
  ) async throws -> KubernetesWorkloadRestartResult {
    KubernetesWorkloadRestartResult(
      request: request,
      resourceVersion: "preview-restart",
      capturedAt: Date()
    )
  }

  func provision(
    _ request: KubernetesClusterProvisionRequest,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func retryProvisioning(
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func start() async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func stop() async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func forceStop() async throws -> KubernetesClusterSnapshot {
    snapshot
  }

  func delete() async throws {}

  func forget() async throws {}

  func exportKubeconfig() async throws -> KubernetesKubeconfigExport {
    KubernetesKubeconfigExport(
      fileName: "NativeContainers-kubeconfig.yaml",
      data: Data("apiVersion: v1\n".utf8)
    )
  }
}

extension KubernetesResourceInventory {
  fileprivate static let preview = Self(
    workloads: [
      KubernetesWorkloadRecord(
        uid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        resourceVersion: "101",
        namespace: "default",
        name: "api",
        kind: .deployment,
        desiredCount: 3,
        readyCount: 3,
        availableCount: 3,
        failedCount: 0
      ),
      KubernetesWorkloadRecord(
        uid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        resourceVersion: "202",
        namespace: "data",
        name: "postgres",
        kind: .statefulSet,
        desiredCount: 1,
        readyCount: 1,
        availableCount: 1,
        failedCount: 0
      ),
      KubernetesWorkloadRecord(
        uid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        resourceVersion: "303",
        namespace: "default",
        name: "database-migration",
        kind: .job,
        desiredCount: 1,
        readyCount: 1,
        availableCount: 0,
        failedCount: 0
      ),
    ],
    pods: [
      KubernetesPodRecord(
        uid: "11111111-1111-4111-8111-111111111111",
        namespace: "default",
        name: "api-7f8d9b6c4d-x2mqp",
        phase: .running,
        readyContainerCount: 1,
        containerNames: ["api"],
        restartCount: 0,
        nodeName: "nativecontainers-kubernetes"
      ),
      KubernetesPodRecord(
        uid: "22222222-2222-4222-8222-222222222222",
        namespace: "data",
        name: "postgres-0",
        phase: .running,
        readyContainerCount: 1,
        containerNames: ["postgres"],
        restartCount: 1,
        nodeName: "nativecontainers-kubernetes"
      ),
      KubernetesPodRecord(
        uid: "33333333-3333-4333-8333-333333333333",
        namespace: "kube-system",
        name: "metrics-server-6f4c6675d5-hm8tz",
        phase: .running,
        readyContainerCount: 1,
        containerNames: ["metrics-server"],
        restartCount: 0,
        nodeName: "nativecontainers-kubernetes"
      ),
    ],
    services: [
      KubernetesServiceRecord(
        namespace: "default",
        name: "api",
        type: "ClusterIP",
        clusterIP: "10.43.84.12",
        ports: [
          KubernetesServicePortRecord(
            name: "http",
            protocolName: "TCP",
            port: 80,
            targetPort: "8080",
            nodePort: nil
          )
        ]
      ),
      KubernetesServiceRecord(
        namespace: "kube-system",
        name: "kube-dns",
        type: "ClusterIP",
        clusterIP: "10.43.0.10",
        ports: [
          KubernetesServicePortRecord(
            name: "dns",
            protocolName: "UDP",
            port: 53,
            targetPort: "53",
            nodePort: nil
          )
        ]
      ),
    ],
    capturedAt: Date()
  )
}

extension KubernetesClusterSnapshot {
  fileprivate static let previewReady: Self = {
    let machine = LinuxMachineRecord(
      id: "nativecontainers-kubernetes",
      imageReference: "docker.io/library/alpine:3.22",
      platform: "linux/arm64",
      state: .running,
      ipAddress: "192.168.64.42",
      createdAt: Date().addingTimeInterval(-86_400),
      startedAt: Date().addingTimeInterval(-600),
      diskSizeBytes: 20 * 1_024 * 1_024 * 1_024,
      cpuCount: 4,
      memoryBytes: 4 * 1_024 * 1_024 * 1_024,
      homeMount: .none,
      isInitialized: true
    )
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date().addingTimeInterval(-86_400)
    )
    return Self(
      state: .ready,
      descriptor: descriptor,
      machine: machine,
      k3sVersion: "k3s version v1.36.1+k3s1",
      nodeCount: 1,
      readyNodeCount: 1,
      podCount: 8,
      runningPodCount: 8
    )
  }()
}
