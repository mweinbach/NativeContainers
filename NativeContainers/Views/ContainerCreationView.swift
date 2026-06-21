import SwiftUI

struct ContainerCreationView: View {
  @Environment(\.dismiss) private var dismiss
  private let appModel: AppModel

  @State private var model: ContainerProvisioningModel
  @State private var draft: ContainerCreationDraft
  @State private var validationMessage: String?
  @State private var operationTask: Task<Void, Never>?

  init(appModel: AppModel) {
    self.appModel = appModel
    _model = State(initialValue: appModel.makeContainerProvisioningModel())
    _draft = State(
      initialValue: ContainerCreationDraft(
        defaultNetworkID: appModel.networks.first(where: \.isBuiltin)?.id
      )
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        ContainerIdentitySection(
          name: $draft.name,
          imageReference: $draft.imageReference,
          architecture: $draft.architecture
        )
        ContainerResourcesSection(
          cpuCount: $draft.cpuCount,
          memoryMiB: $draft.memoryMiB,
          maximumSuggestedCPUCount: maximumSuggestedCPUCount
        )
        ContainerProcessSection(
          workingDirectory: $draft.workingDirectory,
          argumentsText: $draft.argumentsText,
          environmentText: $draft.environmentText
        )
        ContainerPortPublicationsSection(ports: $draft.publishedPorts)
        ContainerStorageSection(
          mounts: $draft.volumeMounts,
          volumes: appModel.volumes
        )
        ContainerNetworksSection(
          attachments: $draft.networkAttachments,
          networks: appModel.networks
        )
        ContainerSocketPublicationsSection(
          sockets: $draft.publishedSockets,
          socketRootPath: model.attachmentEnvironment?.publishedSocketRootPath
        )
        ContainerHostAccessSection(
          isRequired: $draft.requiresHostAccess,
          selectedConfigurationID: $draft.selectedHostAccessID,
          catalog: model.attachmentEnvironment?.hostAccess
        )
        ContainerLifecycleSection(
          startAfterCreation: $draft.startAfterCreation,
          useInitProcess: $draft.useInitProcess,
          forwardSSHAgent: $draft.forwardSSHAgent,
          readOnlyRootFilesystem: $draft.readOnlyRootFilesystem,
          removeWhenStopped: $draft.removeWhenStopped
        )

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
      .disabled(isBusy)
      .navigationTitle("New Container")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if isBusy {
            Button("Cancel and Clean Up") {
              operationTask?.cancel()
            }
            .help("Cancel creation, force-stop any owned container, and remove partial state")
          } else {
            Button("Cancel") {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            create()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            isBusy
              || draft.name.isEmpty
              || draft.imageReference.isEmpty
              || draft.networkAttachments.isEmpty
          )
        }
      }
    }
    .frame(minWidth: 700, minHeight: 760)
    .interactiveDismissDisabled(isBusy)
    .task {
      await model.loadAttachmentEnvironment()
      draft.ensureDefaultNetwork(from: appModel.networks)
    }
    .onChange(of: appModel.networks) {
      draft.ensureDefaultNetwork(from: appModel.networks)
    }
    .onDisappear {
      operationTask?.cancel()
    }
  }

  private var isBusy: Bool {
    model.isWorking || operationTask != nil
  }

  private var maximumSuggestedCPUCount: Int {
    max(1, min(ProcessInfo.processInfo.activeProcessorCount, 32))
  }

  private func create() {
    guard operationTask == nil, !model.isWorking else { return }
    do {
      let request = try draft.makeRequest(
        availableVolumes: appModel.volumes,
        availableNetworks: appModel.networks,
        attachmentEnvironment: model.attachmentEnvironment
      )
      validationMessage = nil
      operationTask = Task { @MainActor in
        defer { operationTask = nil }
        if await model.createContainer(request) {
          dismiss()
        }
      }
    } catch {
      validationMessage = error.localizedDescription
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

#Preview("New container") {
  ContainerCreationView(appModel: .preview)
}

#Preview("Pull image") {
  ImagePullView(appModel: .preview)
}
