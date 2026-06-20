import SwiftUI

struct ContainerCreationView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerProvisioningModel
  @State private var draft = ContainerCreationDraft()
  @State private var validationMessage: String?

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerProvisioningModel())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Container") {
          TextField("Name", text: $draft.name, prompt: Text("my-container"))
          TextField("Image", text: $draft.imageReference, prompt: Text("alpine:latest"))
          Picker("Architecture", selection: $draft.architecture) {
            Text("Apple silicon (arm64)").tag(ContainerArchitecture.arm64)
            Text("Intel with Rosetta (amd64)").tag(ContainerArchitecture.amd64)
          }
        }

        Section("Resources") {
          Stepper(value: $draft.cpuCount, in: 1...maximumSuggestedCPUCount) {
            LabeledContent("CPUs", value: draft.cpuCount.formatted())
          }
          Picker("Memory", selection: $draft.memoryMiB) {
            ForEach(ContainerCreationDraft.memoryOptions, id: \.self) { memoryMiB in
              Text(memoryLabel(memoryMiB)).tag(memoryMiB)
            }
          }
        }

        Section("Process") {
          TextField(
            "Working directory",
            text: $draft.workingDirectory,
            prompt: Text("Use image default")
          )
          LabeledContent("Arguments") {
            TextEditor(text: $draft.argumentsText)
              .font(.body.monospaced())
              .frame(minHeight: 64)
              .overlay(alignment: .topLeading) {
                if draft.argumentsText.isEmpty {
                  Text("One argument per line; leave empty for image defaults")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                }
              }
          }
          LabeledContent("Environment") {
            TextEditor(text: $draft.environmentText)
              .font(.body.monospaced())
              .frame(minHeight: 76)
              .overlay(alignment: .topLeading) {
                if draft.environmentText.isEmpty {
                  Text("One KEY=value entry per line")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                }
              }
          }
        }

        Section("Published ports") {
          if draft.publishedPorts.isEmpty {
            Text("No host ports published")
              .foregroundStyle(.secondary)
          }
          ForEach($draft.publishedPorts) { $port in
            ContainerPortDraftRow(port: $port) {
              draft.publishedPorts.removeAll { $0.id == port.id }
            }
          }
          Button("Add Port", systemImage: "plus") {
            draft.publishedPorts.append(ContainerPortDraft())
          }
        }

        Section("Lifecycle") {
          Toggle("Start after creation", isOn: $draft.startAfterCreation)
          Toggle("Use a minimal init process", isOn: $draft.useInitProcess)
          Toggle("Forward SSH agent", isOn: $draft.forwardSSHAgent)
          Toggle("Read-only root filesystem", isOn: $draft.readOnlyRootFilesystem)
          Toggle("Remove automatically when stopped", isOn: $draft.removeWhenStopped)
        }

        if let message = validationMessage ?? model.errorMessage {
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if model.isWorking || model.progress != nil {
          Section("Progress") {
            ContainerOperationStatusView(progress: model.progress)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("New Container")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(model.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            create()
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || draft.name.isEmpty || draft.imageReference.isEmpty)
        }
      }
    }
    .frame(minWidth: 650, minHeight: 720)
    .interactiveDismissDisabled(model.isWorking)
  }

  private var maximumSuggestedCPUCount: Int {
    max(1, min(ProcessInfo.processInfo.activeProcessorCount, 32))
  }

  private func create() {
    do {
      let request = try draft.makeRequest()
      validationMessage = nil
      Task {
        if await model.createContainer(request) {
          dismiss()
        }
      }
    } catch {
      validationMessage = error.localizedDescription
    }
  }

  private func memoryLabel(_ memoryMiB: Int) -> String {
    Int64(memoryMiB * Int(ContainerCreationRequest.bytesPerMiB)).formatted(
      .byteCount(style: .memory)
    )
  }
}

struct ContainerPortDraftRow: View {
  @Binding var port: ContainerPortDraft
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TextField("Host address", text: $port.hostAddress)
        .frame(minWidth: 125)
      TextField("Host", value: $port.hostPort, format: .number)
        .frame(width: 74)
      Image(systemName: "arrow.right")
        .foregroundStyle(.tertiary)
      TextField("Guest", value: $port.containerPort, format: .number)
        .frame(width: 74)
      Picker("Protocol", selection: $port.transportProtocol) {
        ForEach(ContainerTransportProtocol.allCases) { transport in
          Text(transport.rawValue.uppercased()).tag(transport)
        }
      }
      .labelsHidden()
      .frame(width: 76)
      Button("Remove Port", systemImage: "minus.circle", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
  }
}

struct ImagePullView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ContainerProvisioningModel
  @State private var reference = ""
  @State private var platform = ImagePlatformRequest.current
  @State private var transport = RegistryTransport.automatic
  @State private var unpackAfterPull = true
  @State private var maxConcurrentDownloads = 3
  @State private var isConfirmingPull = false
  @State private var operationTask: Task<Void, Never>?

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeContainerProvisioningModel())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("OCI image") {
          TextField("Reference", text: $reference, prompt: Text("alpine:latest"))
          Text("Unqualified references use the registry configured by Apple’s container runtime.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("Platform", selection: $platform) {
            ForEach(ImagePlatformRequest.allCases) { platform in
              Text(platform.title).tag(platform)
            }
          }
          Picker("Transport", selection: $transport) {
            ForEach(RegistryTransport.allCases) { transport in
              Text(transport.title).tag(transport)
            }
          }
          Text(
            "Automatic uses HTTPS publicly and HTTP for localhost, private IPv4, and Apple’s internal container DNS domain. Resolved HTTP is confirmed before transfer."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section("Advanced") {
          Toggle("Unpack after pull", isOn: $unpackAfterPull)
          Stepper(value: $maxConcurrentDownloads, in: 1...16) {
            LabeledContent(
              "Concurrent downloads",
              value: maxConcurrentDownloads.formatted()
            )
          }
          if platform == .all, unpackAfterPull {
            Label(
              "Unpacking every platform can consume substantial disk space.",
              systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if let result = model.pullResult {
          Section("Local result") {
            LabeledContent("Reference", value: result.reference)
              .textSelection(.enabled)
            LabeledContent("Digest", value: result.digest)
              .textSelection(.enabled)
            if let outcome = result.unpackOutcome {
              ForEach(outcome.platforms) { platform in
                LabeledContent(platform.platform.description) {
                  Text(unpackStateLabel(platform.state))
                }
              }
              if !outcome.isComplete {
                Text(
                  "The download is local, but one or more platform snapshots are not ready. Review the failures before retrying."
                )
                .font(.caption)
                .foregroundStyle(.orange)
              }
            } else {
              Text("Downloaded without preparing a filesystem snapshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        if model.isWorking || model.progress != nil {
          Section("Progress") {
            ContainerOperationStatusView(progress: model.progress)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(isBusy)
      .navigationTitle("Pull Image")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isBusy ? "Cancel Operation" : "Cancel") {
            if let operationTask {
              operationTask.cancel()
            } else {
              model.clearPullPlan()
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Pull") {
            preparePull()
          }
          .buttonStyle(.borderedProminent)
          .disabled(isBusy || reference.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .frame(minWidth: 560, minHeight: 520)
    .interactiveDismissDisabled(isBusy)
    .onChange(of: reference) { model.clearPullPlan() }
    .onChange(of: platform) { model.clearPullPlan() }
    .onChange(of: transport) { model.clearPullPlan() }
    .onChange(of: unpackAfterPull) { model.clearPullPlan() }
    .onChange(of: maxConcurrentDownloads) { model.clearPullPlan() }
    .onDisappear { operationTask?.cancel() }
    .confirmationDialog(
      "Pull reviewed image?",
      isPresented: $isConfirmingPull,
      presenting: model.pullPlan
    ) { plan in
      Button("Pull \(plan.normalizedReference)", role: .destructive) {
        submitPull(plan)
      }
      Button("Cancel", role: .cancel) {
        model.clearPullPlan()
      }
    } message: { plan in
      Text(pullConfirmationMessage(plan))
    }
  }

  private func preparePull() {
    startOperation {
      guard
        let plan = await model.prepareImagePull(
          reference: reference,
          platform: platform,
          transport: transport,
          unpackAfterPull: unpackAfterPull,
          maxConcurrentDownloads: maxConcurrentDownloads
        )
      else { return }
      guard !Task.isCancelled else { return }
      if plan.requiresInsecureConfirmation || plan.replacesExistingReference
        || plan.requiresAllPlatformConfirmation
      {
        isConfirmingPull = true
      } else {
        await performPull(plan)
      }
    }
  }

  private func submitPull(_ plan: ImagePullPlan) {
    startOperation {
      await performPull(plan)
    }
  }

  private func performPull(_ plan: ImagePullPlan) async {
    let authorization = ImagePullAuthorization(
      allowsInsecureTransport: plan.requiresInsecureConfirmation,
      allowsExistingReferenceReplacement: plan.replacesExistingReference,
      allowsAllPlatforms: plan.requiresAllPlatformConfirmation
    )
    if await model.pullReviewedImage(plan, authorization: authorization) {
      dismiss()
    }
  }

  private var isBusy: Bool {
    model.isWorking || operationTask != nil
  }

  private func startOperation(
    _ operation: @escaping @MainActor () async -> Void
  ) {
    guard operationTask == nil else { return }
    operationTask = Task { @MainActor in
      defer { operationTask = nil }
      await operation()
    }
  }

  private func pullConfirmationMessage(_ plan: ImagePullPlan) -> String {
    var messages = [
      "Reference: \(plan.normalizedReference). Platform: \(plan.platform.description). Transport: \(plan.resolvedTransport.title)."
    ]
    if plan.replacesExistingReference {
      messages.append("The current local reference may move to a different remote digest.")
    }
    if plan.requiresInsecureConfirmation {
      messages.append("HTTP is unencrypted.")
    }
    if plan.requiresAllPlatformConfirmation {
      messages.append(
        plan.unpackAfterPull
          ? "Every available platform will be downloaded and unpacked."
          : "Every available platform will be downloaded."
      )
    }
    return messages.joined(separator: " ")
  }

  private func unpackStateLabel(_ state: ImagePlatformUnpackState) -> String {
    switch state {
    case .alreadyPresent:
      "Already prepared"
    case .created:
      "Prepared"
    case .failed(let message):
      "Failed: \(message)"
    }
  }
}

struct ContainerOperationStatusView: View {
  let progress: ContainerOperationProgress?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let progress {
        Text(progress.message)
          .font(.headline)
        if let fraction = progress.fractionCompleted {
          ProgressView(value: fraction)
        } else if progress.phase == .completed {
          ProgressView(value: 1)
        } else {
          ProgressView()
        }
        if progress.totalBytes > 0 {
          Text(
            "\(Int64(progress.transferredBytes), format: .byteCount(style: .file)) of \(Int64(progress.totalBytes), format: .byteCount(style: .file))"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      } else {
        ProgressView("Preparing…")
      }
    }
  }
}

private struct ContainerCreationDraft {
  static let memoryOptions = [512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]

  var name = ""
  var imageReference = ""
  var architecture = ContainerArchitecture.arm64
  var cpuCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
  var memoryMiB = 1_024
  var argumentsText = ""
  var environmentText = ""
  var workingDirectory = ""
  var publishedPorts: [ContainerPortDraft] = []
  var startAfterCreation = true
  var removeWhenStopped = false
  var forwardSSHAgent = false
  var readOnlyRootFilesystem = false
  var useInitProcess = true

  func makeRequest() throws -> ContainerCreationRequest {
    try ContainerCreationRequest(
      name: name,
      imageReference: imageReference,
      architecture: architecture,
      cpuCount: cpuCount,
      memoryBytes: UInt64(memoryMiB) * ContainerCreationRequest.bytesPerMiB,
      arguments: argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty },
      environment: try environmentVariables(),
      workingDirectory: workingDirectory,
      publishedPorts: try publishedPorts.map { try $0.publication() },
      startAfterCreation: startAfterCreation,
      removeWhenStopped: removeWhenStopped,
      forwardSSHAgent: forwardSSHAgent,
      readOnlyRootFilesystem: readOnlyRootFilesystem,
      useInitProcess: useInitProcess
    )
  }

  private func environmentVariables() throws -> [ContainerEnvironmentVariable] {
    var result: [ContainerEnvironmentVariable] = []
    for (offset, rawLine) in environmentText.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let separator = line.firstIndex(of: "=") else {
        throw ContainerCreationValidationError.malformedEnvironmentLine(offset + 1)
      }
      result.append(
        try ContainerEnvironmentVariable(
          key: String(line[..<separator]),
          value: String(line[line.index(after: separator)...])
        )
      )
    }
    return result
  }
}

struct ContainerPortDraft: Identifiable {
  let id = UUID()
  var hostAddress = "127.0.0.1"
  var hostPort = 8_080
  var containerPort = 8_080
  var transportProtocol = ContainerTransportProtocol.tcp

  func publication() throws -> ContainerPortPublication {
    guard let hostPort = UInt16(exactly: hostPort),
      let containerPort = UInt16(exactly: containerPort),
      hostPort > 0, containerPort > 0
    else {
      throw ContainerCreationValidationError.invalidPort
    }
    return try ContainerPortPublication(
      hostAddress: hostAddress,
      hostPort: hostPort,
      containerPort: containerPort,
      transportProtocol: transportProtocol
    )
  }
}

#Preview("New container") {
  ContainerCreationView(appModel: .preview)
}

#Preview("Pull image") {
  ImagePullView(appModel: .preview)
}
