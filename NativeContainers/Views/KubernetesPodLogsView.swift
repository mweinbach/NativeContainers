import Observation
import SwiftUI
import UniformTypeIdentifiers

struct KubernetesPodLogsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @State private var model: KubernetesPodLogsModel
  @State private var isExporting = false
  @State private var exportErrorMessage: String?
  private let terminalMachine: LinuxMachineIdentity?

  init(clusterModel: KubernetesClusterModel, pod: KubernetesPodRecord) {
    _model = State(initialValue: clusterModel.makePodLogsModel(for: pod))
    terminalMachine = clusterModel.snapshot.descriptor?.machine
  }

  init(model: KubernetesPodLogsModel) {
    _model = State(initialValue: model)
    terminalMachine = nil
  }

  var body: some View {
    @Bindable var model = model

    NavigationStack {
      VStack(spacing: 0) {
        KubernetesPodLogHeader(
          namespace: model.namespace,
          podName: model.podName,
          containerNames: model.containerNames,
          selectedContainerName: $model.selectedContainerName
        )

        Label(
          "Recent logs stay in memory unless you export them. Logs can contain sensitive application data.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 10)

        Divider()

        if let errorMessage = model.errorMessage {
          KubernetesPodLogErrorBanner(
            message: errorMessage,
            onRetry: {
              Task {
                await model.refresh()
              }
            }
          )
        }

        KubernetesPodLogContent(
          text: model.visibleText,
          hasSnapshot: model.snapshot != nil,
          hasSearchText: model.hasSearchText,
          matchCount: model.matchCount,
          isLoading: model.isLoading,
          isTruncated: model.snapshot?.isTruncated ?? false,
          capturedAt: model.snapshot?.capturedAt,
          hasContainers: !model.containerNames.isEmpty,
          onRetry: {
            Task {
              await model.refresh()
            }
          }
        )

        if let exportErrorMessage {
          Text(exportErrorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
      }
      .navigationTitle("Pod Logs")
      .searchable(
        text: $model.searchText,
        placement: .automatic,
        prompt: "Search Pod logs"
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button("Open Terminal", systemImage: "terminal") {
            openPodTerminal()
          }
          .disabled(
            terminalMachine == nil
              || !model.containerNames.contains(model.selectedContainerName)
          )

          Button("Export Logs", systemImage: "square.and.arrow.up") {
            isExporting = true
          }
          .disabled(model.visibleText.isEmpty)

          Button("Refresh Logs", systemImage: "arrow.clockwise") {
            Task {
              await model.refresh()
            }
          }
          .disabled(model.isLoading || model.containerNames.isEmpty)
        }
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .task(id: model.selectedContainerName) {
      await model.refresh()
    }
    .fileExporter(
      isPresented: $isExporting,
      document: ContainerLogDocument(text: model.visibleText),
      contentType: .plainText,
      defaultFilename:
        "\(model.namespace)-\(model.podName)-\(model.selectedContainerName).log"
    ) { result in
      switch result {
      case .success:
        exportErrorMessage = nil
      case .failure(let error):
        exportErrorMessage = error.localizedDescription
      }
    }
  }

  private func openPodTerminal() {
    guard let terminalMachine else { return }
    let target = KubernetesPodTerminalIdentity(
      machine: terminalMachine,
      podUID: model.podUID,
      namespace: model.namespace,
      podName: model.podName,
      containerName: model.selectedContainerName
    )
    openWindow(
      id: "terminal-workspace",
      value: TerminalWindowRequest(target: .kubernetesPod(target))
    )
  }
}

@MainActor
@Observable
final class KubernetesPodLogsModel {
  typealias Loader =
    @Sendable (KubernetesPodLogRequest) async throws -> KubernetesPodLogSnapshot

  let namespace: String
  let podName: String
  let podUID: String
  let containerNames: [String]

  var selectedContainerName: String {
    didSet {
      guard selectedContainerName != oldValue else { return }
      refreshGeneration &+= 1
      isLoading = false
      snapshot = nil
      errorMessage = nil
    }
  }

  var searchText = "" {
    didSet {
      recomputeVisibleText()
    }
  }

  private(set) var snapshot: KubernetesPodLogSnapshot? {
    didSet {
      recomputeVisibleText()
    }
  }

  private(set) var visibleText = ""
  private(set) var matchCount = 0
  private(set) var isLoading = false
  private(set) var errorMessage: String?

  var hasSearchText: Bool {
    !normalizedSearchText.isEmpty
  }

  @ObservationIgnored
  private let loader: Loader

  @ObservationIgnored
  private var refreshGeneration = 0

  init(
    service: any KubernetesClusterManaging,
    pod: KubernetesPodRecord
  ) {
    namespace = pod.namespace
    podName = pod.name
    podUID = pod.uid
    containerNames = pod.containerNames
    selectedContainerName = pod.containerNames.first ?? ""
    loader = { request in
      try await service.loadPodLogs(request)
    }
  }

  init(
    pod: KubernetesPodRecord,
    loader: @escaping Loader
  ) {
    namespace = pod.namespace
    podName = pod.name
    podUID = pod.uid
    containerNames = pod.containerNames
    selectedContainerName = pod.containerNames.first ?? ""
    self.loader = loader
  }

  func refresh() async {
    guard containerNames.contains(selectedContainerName) else {
      if !containerNames.isEmpty {
        errorMessage =
          KubernetesClusterError.invalidKubernetesResourceReference
          .localizedDescription
      }
      return
    }

    refreshGeneration &+= 1
    let generation = refreshGeneration
    isLoading = true
    errorMessage = nil

    let request = KubernetesPodLogRequest(
      podUID: podUID,
      namespace: namespace,
      podName: podName,
      containerName: selectedContainerName
    )

    defer {
      if refreshGeneration == generation {
        isLoading = false
      }
    }

    do {
      let nextSnapshot = try await loader(request)
      try Task.checkCancellation()
      guard
        refreshGeneration == generation,
        selectedContainerName == request.containerName,
        nextSnapshot.request == request
      else {
        return
      }
      snapshot = nextSnapshot
    } catch is CancellationError {
      return
    } catch {
      guard refreshGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func recomputeVisibleText() {
    guard let snapshot else {
      visibleText = ""
      matchCount = 0
      return
    }

    let query = normalizedSearchText
    guard !query.isEmpty else {
      visibleText = snapshot.text
      matchCount = 0
      return
    }

    let matchingLines = snapshot.text.components(separatedBy: .newlines)
      .filter { $0.localizedCaseInsensitiveContains(query) }
    visibleText = matchingLines.joined(separator: "\n")
    matchCount = matchingLines.count
  }

  private var normalizedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct KubernetesPodLogHeader: View {
  let namespace: String
  let podName: String
  let containerNames: [String]
  @Binding var selectedContainerName: String

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(podName)
          .font(.headline)
          .textSelection(.enabled)
        Text(namespace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer()

      if containerNames.count > 1 {
        Picker("Container", selection: $selectedContainerName) {
          ForEach(containerNames, id: \.self) { containerName in
            Text(containerName)
              .tag(containerName)
          }
        }
        .frame(width: 260)
      } else if let containerName = containerNames.first {
        LabeledContent("Container") {
          Text(containerName)
            .textSelection(.enabled)
        }
        .frame(maxWidth: 320)
      }
    }
    .padding()
  }
}

private struct KubernetesPodLogContent: View {
  let text: String
  let hasSnapshot: Bool
  let hasSearchText: Bool
  let matchCount: Int
  let isLoading: Bool
  let isTruncated: Bool
  let capturedAt: Date?
  let hasContainers: Bool
  let onRetry: () -> Void

  var body: some View {
    if !hasContainers {
      KubernetesPodLogUnavailableView(
        title: "No standard containers",
        description: "This Pod does not expose a standard container log stream.",
        onRetry: nil
      )
    } else if !hasSnapshot && isLoading {
      VStack(spacing: 12) {
        ProgressView()
        Text("Loading Pod logs…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !hasSnapshot {
      KubernetesPodLogUnavailableView(
        title: "Logs are unavailable",
        description: "Try loading this container's recent log snapshot again.",
        onRetry: onRetry
      )
    } else {
      VStack(spacing: 0) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .padding(.top, 8)
        }

        ScrollView([.horizontal, .vertical]) {
          if text.isEmpty {
            ContentUnavailableView(
              hasSearchText ? "No matching log lines" : "No log output",
              systemImage: hasSearchText ? "text.magnifyingglass" : "doc.plaintext",
              description: Text(
                hasSearchText
                  ? "Try a different search."
                  : "The selected container returned an empty log snapshot."
              )
            )
            .frame(maxWidth: .infinity, minHeight: 360)
          } else {
            Text(text)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
          }
        }
        .background(.black.opacity(0.88))
        .foregroundStyle(.white)

        HStack {
          if hasSearchText {
            Text("\(matchCount) matching lines")
              .monospacedDigit()
          }
          if isTruncated {
            Label(
              "Showing the last 512 KiB of the bounded snapshot.",
              systemImage: "scissors"
            )
          }
          Spacer()
          if let capturedAt {
            Text(capturedAt, format: .dateTime.hour().minute().second())
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
    }
  }
}

private struct KubernetesPodLogErrorBanner: View {
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

private struct KubernetesPodLogUnavailableView: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let onRetry: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.plaintext")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(description)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let onRetry {
        Button("Try Again", action: onRetry)
          .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

#Preview("Kubernetes Pod Logs") {
  KubernetesPodLogsView(
    model: KubernetesPodLogsModel(
      pod: KubernetesPodRecord(
        uid: "11111111-1111-4111-8111-111111111111",
        namespace: "default",
        name: "api-7f8d9b6c4d-x2mqp",
        phase: .running,
        readyContainerCount: 2,
        containerNames: ["api", "metrics"],
        restartCount: 0,
        nodeName: "nativecontainers-kubernetes"
      )
    ) { request in
      KubernetesPodLogSnapshot(
        request: request,
        text: """
          2026-06-22T13:30:00.000000000Z server listening on :8080
          2026-06-22T13:30:01.000000000Z health check ready
          2026-06-22T13:30:02.000000000Z GET /api/projects 200 18ms
          """,
        capturedAt: Date(),
        isTruncated: false
      )
    }
  )
}
