import Observation
import SwiftUI
import UniformTypeIdentifiers

struct KubernetesPodLogsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @State private var model: KubernetesPodLogsModel
  @State private var isExporting = false
  @State private var exportErrorMessage: String?
  @State private var commandModel: KubernetesPodCommandModel?
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
          Button("Run Command", systemImage: "chevron.left.forwardslash.chevron.right") {
            commandModel = model.makeCommandModel()
          }
          .disabled(
            terminalMachine == nil
              || !model.containerNames.contains(model.selectedContainerName)
          )

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
    .sheet(item: $commandModel) { commandModel in
      KubernetesPodCommandView(model: commandModel)
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
  typealias CommandExecutor =
    @Sendable (KubernetesPodCommandRequest) async throws -> KubernetesPodCommandResult

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
  private let commandExecutor: CommandExecutor

  @ObservationIgnored
  private let commandMachine: LinuxMachineIdentity?

  @ObservationIgnored
  private var refreshGeneration = 0

  init(
    service: any KubernetesClusterManaging,
    machine: LinuxMachineIdentity?,
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
    commandExecutor = { request in
      try await service.executePodCommand(request)
    }
    commandMachine = machine
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
    commandExecutor = { _ in
      throw KubernetesClusterError.unavailable
    }
    commandMachine = nil
  }

  func makeCommandModel() -> KubernetesPodCommandModel? {
    guard let commandMachine else { return nil }
    return KubernetesPodCommandModel(
      machine: commandMachine,
      podUID: podUID,
      namespace: namespace,
      podName: podName,
      containerName: selectedContainerName,
      executor: commandExecutor
    )
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

@MainActor
@Observable
final class KubernetesPodCommandModel: Identifiable {
  typealias Executor =
    @Sendable (KubernetesPodCommandRequest) async throws -> KubernetesPodCommandResult

  let id = UUID()
  let machine: LinuxMachineIdentity
  let podUID: String
  let namespace: String
  let podName: String
  let containerName: String

  private(set) var isRunning = false
  private(set) var result: KubernetesPodCommandResult?
  private(set) var errorMessage: String?

  @ObservationIgnored
  private let executor: Executor

  init(
    machine: LinuxMachineIdentity,
    podUID: String,
    namespace: String,
    podName: String,
    containerName: String,
    executor: @escaping Executor
  ) {
    self.machine = machine
    self.podUID = podUID
    self.namespace = namespace
    self.podName = podName
    self.containerName = containerName
    self.executor = executor
  }

  func execute(
    executable: String,
    arguments: [String],
    timeoutSeconds: Int
  ) async {
    guard !isRunning else { return }
    isRunning = true
    result = nil
    errorMessage = nil
    defer { isRunning = false }

    do {
      let request = try KubernetesPodCommandRequest(
        machine: machine,
        podUID: podUID,
        namespace: namespace,
        podName: podName,
        containerName: containerName,
        executable: executable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      let nextResult = try await executor(request)
      try Task.checkCancellation()
      guard nextResult.request == request else {
        throw KubernetesClusterError.invalidPodCommandResult
      }
      result = nextResult
    } catch is CancellationError {
      errorMessage = String(localized: "The Pod command was cancelled.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct KubernetesPodCommandView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: KubernetesPodCommandModel
  @State private var executable = ""
  @State private var argumentsText = ""
  @State private var timeoutSeconds = 30
  @State private var selectedOutput = KubernetesPodCommandOutputKind.standardOutput
  @State private var commandTask: Task<Void, Never>?

  init(model: KubernetesPodCommandModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack {
      Form {
        KubernetesPodCommandTargetSection(
          namespace: model.namespace,
          podName: model.podName,
          containerName: model.containerName
        )
        KubernetesPodCommandInputSection(
          executable: $executable,
          argumentsText: $argumentsText,
          timeoutSeconds: $timeoutSeconds
        )
        if let result = model.result {
          KubernetesPodCommandResultSection(
            result: result,
            selectedOutput: $selectedOutput
          )
        }
        if let errorMessage = model.errorMessage {
          KubernetesPodCommandErrorSection(message: errorMessage)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Run Pod Command")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isRunning ? "Stop" : "Close") {
            if model.isRunning {
              commandTask?.cancel()
            } else {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Run", systemImage: "play.fill") {
            runCommand()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            model.isRunning
              || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
    }
    .frame(minWidth: 680, minHeight: 640)
    .interactiveDismissDisabled(model.isRunning)
    .onDisappear {
      commandTask?.cancel()
    }
  }

  private func runCommand() {
    let arguments = argumentsText.components(separatedBy: .newlines)
      .filter { !$0.isEmpty }
    commandTask = Task {
      await model.execute(
        executable: executable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds
      )
      commandTask = nil
    }
  }
}

private struct KubernetesPodCommandTargetSection: View {
  let namespace: String
  let podName: String
  let containerName: String

  var body: some View {
    Section("Target") {
      LabeledContent("Namespace", value: namespace)
      LabeledContent("Pod", value: podName)
      LabeledContent("Container", value: containerName)
      Label(
        "The Pod UID is checked before and after execution. A same-name replacement is never addressed.",
        systemImage: "checkmark.shield"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct KubernetesPodCommandInputSection: View {
  @Binding var executable: String
  @Binding var argumentsText: String
  @Binding var timeoutSeconds: Int

  var body: some View {
    Section("Command") {
      TextField(
        "Executable",
        text: $executable,
        prompt: Text("For example: env or /bin/sh")
      )
      .font(.body.monospaced())

      LabeledContent("Arguments") {
        TextEditor(text: $argumentsText)
          .font(.body.monospaced())
          .frame(minHeight: 100)
      }
      Text(
        "Enter one argument per line; empty lines are omitted. NativeContainers passes the executable and arguments directly after kubectl’s separator; it does not add a shell."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Label(
        "Command output stays in memory and may contain sensitive application data.",
        systemImage: "lock.shield"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Stepper(
        value: $timeoutSeconds,
        in: 1...KubernetesPodCommandRequest.maximumTimeoutSeconds,
        step: 5
      ) {
        LabeledContent("Timeout") {
          Text("\(timeoutSeconds) seconds")
        }
      }
    }
  }
}

private struct KubernetesPodCommandResultSection: View {
  let result: KubernetesPodCommandResult
  @Binding var selectedOutput: KubernetesPodCommandOutputKind

  var body: some View {
    Section("Result") {
      HStack {
        Label(
          "Exit \(result.process.exitCode)",
          systemImage: result.process.exitCode == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
        )
        .foregroundStyle(result.process.exitCode == 0 ? .green : .orange)
        Spacer()
        Text(
          "\(durationSeconds, format: .number.precision(.fractionLength(2))) s"
        )
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Text(result.capturedAt, format: .dateTime.hour().minute().second())
          .foregroundStyle(.secondary)
      }

      Picker("Output", selection: $selectedOutput) {
        ForEach(KubernetesPodCommandOutputKind.allCases) { output in
          Text(output.title).tag(output)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      ScrollView([.horizontal, .vertical]) {
        Text(outputText.isEmpty ? "No output." : outputText)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .privacySensitive()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .frame(minHeight: 180, maxHeight: 320)
      .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
      .foregroundStyle(.white)

      if result.process.outputWasTruncated {
        Text("Showing the newest 1 MiB from each output stream.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var outputText: String {
    switch selectedOutput {
    case .standardOutput:
      result.process.standardOutput
    case .standardError:
      result.process.standardError
    }
  }

  private var durationSeconds: Double {
    let components = result.process.duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

private struct KubernetesPodCommandErrorSection: View {
  let message: String

  var body: some View {
    Section {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .textSelection(.enabled)
    }
  }
}

private enum KubernetesPodCommandOutputKind: String, CaseIterable, Identifiable {
  case standardOutput
  case standardError

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .standardOutput:
      "Standard Output"
    case .standardError:
      "Standard Error"
    }
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

#Preview("Kubernetes Pod Command") {
  KubernetesPodCommandView(
    model: KubernetesPodCommandModel(
      machine: LinuxMachineIdentity(
        id: "nativecontainers-kubernetes",
        imageReference: "docker.io/library/alpine:3.22",
        platform: "linux/arm64",
        createdAt: Date()
      ),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-7f8d9b6c4d-x2mqp",
      containerName: "api"
    ) { request in
      KubernetesPodCommandResult(
        request: request,
        process: ContainerCommandResult(
          exitCode: 0,
          standardOutput: "NAME=nativecontainers\n",
          standardError: "",
          outputWasTruncated: false,
          duration: .milliseconds(42)
        ),
        capturedAt: Date()
      )
    }
  )
}
