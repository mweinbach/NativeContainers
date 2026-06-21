import SwiftUI
import UniformTypeIdentifiers

struct ImageBuildCreationView: View {
  @State private var model: ImageBuildModel
  @State private var contextDirectory: URL?
  @State private var dockerfile: URL?
  @State private var outputKind = ImageBuildOutputKind.imageStore
  @State private var tag = ""
  @State private var outputDestinationParent: URL?
  @State private var outputDestinationName = ""
  @State private var platform = ImageBuildPlatformSelection.current
  @State private var buildArguments = ""
  @State private var labels = ""
  @State private var secretDrafts: [ImageBuildSecretDraft] = []
  @State private var targetStage = ""
  @State private var noCache = false
  @State private var pullLatest = true
  @State private var usesCustomBuilderResources = false
  @State private var builderCPUCount = 2
  @State private var builderMemoryMiB = 2_048
  @State private var allowsTagReplacement = false
  @State private var allowsRecreateStoppedBuilder = false
  @State private var allowsStopRunningBuilder = false
  @State private var allowsOutputReplacement = false
  @State private var isChoosingContext = false
  @State private var isChoosingDockerfile = false
  @State private var isChoosingOutputDestination = false
  @State private var isChoosingSecret = false
  @State private var selectedSecretDraftID: UUID?
  @State private var isConfirmingBuild = false
  @State private var operationTask: Task<Void, Never>?

  init(model: ImageBuildModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    Form {
      sourceSection
      ImageBuildOutputSection(
        kind: $outputKind,
        reference: $tag,
        platform: $platform,
        targetStage: $targetStage,
        destinationParent: $outputDestinationParent,
        destinationName: $outputDestinationName,
        isLocked: inputsAreLocked,
        chooseDestinationParent: {
          isChoosingOutputDestination = true
        },
        kindDidChange: resetOutputDraft
      )
      optionsSection
      ImageBuildSecretsSection(
        drafts: $secretDrafts,
        isLocked: inputsAreLocked
      ) { draftID in
        selectedSecretDraftID = draftID
        isChoosingSecret = true
      }
      if let plan = model.plan {
        reviewSection(plan)
      }
      if model.isWorking || model.progress != nil {
        progressSection
      }
      if let result = model.result {
        resultSection(result)
      }
      if let errorMessage = model.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if operationTask != nil {
          Button("Cancel Build", systemImage: "xmark.circle", role: .destructive) {
            operationTask?.cancel()
          }
        } else if model.plan != nil {
          Button("Edit", systemImage: "pencil") {
            startOperation { await model.discardPlan() }
          }
          Button("Build", systemImage: "hammer.fill") {
            isConfirmingBuild = true
          }
          .buttonStyle(.borderedProminent)
        } else {
          Button("Review Build", systemImage: "checklist") {
            allowsTagReplacement = false
            allowsRecreateStoppedBuilder = false
            allowsStopRunningBuilder = false
            allowsOutputReplacement = false
            startOperation { _ = await model.prepare(makeRequest()) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canPrepare)
        }
      }
    }
    .fileImporter(
      isPresented: $isChoosingContext,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        contextDirectory = urls.first
        dockerfile = nil
        model.clearResult()
      }
    }
    .fileImporter(
      isPresented: $isChoosingDockerfile,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        dockerfile = urls.first
        model.clearResult()
      }
    }
    .fileImporter(
      isPresented: $isChoosingOutputDestination,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        outputDestinationParent = urls.first
        model.clearResult()
      }
    }
    .fileImporter(
      isPresented: $isChoosingSecret,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      defer { selectedSecretDraftID = nil }
      guard
        let selectedSecretDraftID,
        case .success(let urls) = result,
        let sourceURL = urls.first,
        let index = secretDrafts.firstIndex(where: { $0.id == selectedSecretDraftID })
      else {
        return
      }
      secretDrafts[index].sourceURL = sourceURL
      model.clearResult()
    }
    .confirmationDialog(
      "Run reviewed build?",
      isPresented: $isConfirmingBuild,
      presenting: model.plan
    ) { plan in
      Button(
        buildButtonTitle(for: plan),
        role:
          plan.replacesExistingTags || plan.output.replacesExistingDestination
          || allowsStopRunningBuilder
          ? .destructive : nil
      ) {
        startOperation {
          _ = await model.execute(
            plan,
            authorization: ImageBuildAuthorization(
              allowsTagReplacement: allowsTagReplacement,
              allowsRecreateStoppedBuilder: allowsRecreateStoppedBuilder,
              allowsStopRunningBuilder: allowsStopRunningBuilder,
              allowsOutputReplacement: allowsOutputReplacement
            )
          )
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { plan in
      Text(confirmationMessage(for: plan))
    }
    .onDisappear {
      operationTask?.cancel()
      if model.plan != nil, !model.isWorking {
        Task { await model.discardPlan() }
      }
    }
  }

  private var sourceSection: some View {
    Section("Build context") {
      LabeledContent("Folder") {
        HStack {
          Text(contextDirectory?.path(percentEncoded: false) ?? "Not selected")
            .foregroundStyle(contextDirectory == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Choose…") { isChoosingContext = true }
        }
      }
      LabeledContent("Dockerfile") {
        HStack {
          Text(dockerfile?.lastPathComponent ?? "Auto: Dockerfile or Containerfile")
            .foregroundStyle(dockerfile == nil ? .secondary : .primary)
          Button("Choose…") { isChoosingDockerfile = true }
          if dockerfile != nil {
            Button("Auto") { dockerfile = nil }
          }
        }
      }
      Text(
        "Review copies regular files into a private app-owned directory. Symlinks, special files, custom syntax frontends, and Dockerfiles at or above 16 KiB are rejected."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .disabled(inputsAreLocked)
  }

  private var optionsSection: some View {
    Section("Build options") {
      Toggle("Pull newer base images", isOn: $pullLatest)
      Toggle("Ignore BuildKit cache", isOn: $noCache)
      DisclosureGroup("Arguments, labels, and builder resources") {
        LabeledContent("Build arguments") {
          TextEditor(text: $buildArguments)
            .font(.body.monospaced())
            .frame(minHeight: 64)
        }
        Text("One KEY=value entry per line.")
          .font(.caption)
          .foregroundStyle(.secondary)
        LabeledContent("Image labels") {
          TextEditor(text: $labels)
            .font(.body.monospaced())
            .frame(minHeight: 64)
        }
        Toggle("Override shared builder resources", isOn: $usesCustomBuilderResources)
        if usesCustomBuilderResources {
          Stepper("CPUs: \(builderCPUCount)", value: $builderCPUCount, in: 1...32)
          Stepper(
            "Memory: \(builderMemoryMiB) MiB",
            value: $builderMemoryMiB,
            in: 512...131_072,
            step: 512
          )
        }
      }
    }
    .disabled(inputsAreLocked)
  }

  private func reviewSection(_ plan: ImageBuildPlan) -> some View {
    Section("Reviewed plan") {
      LabeledContent("Context", value: plan.sourceContextDirectory.lastPathComponent)
      LabeledContent("Fingerprint") {
        Text(String(plan.contextFingerprint.prefix(20)))
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      LabeledContent("Dockerfile", value: plan.stagedDockerfile.lastPathComponent)
      LabeledContent("Output") {
        Label(plan.output.kind.title, systemImage: plan.output.kind.systemImage)
      }
      if let destinationURL = plan.output.destinationURL {
        LabeledContent("Destination") {
          Text(destinationURL.path(percentEncoded: false))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .privacySensitive()
        }
      }
      ForEach(plan.tags) { tag in
        VStack(alignment: .leading, spacing: 3) {
          Text(tag.reference)
          Text(
            tag.existingDigest
              ?? (plan.output.kind == .imageStore
                ? "New local tag" : "OCI archive reference")
          )
          .font(.caption.monospaced())
          .foregroundStyle(tag.replacesExistingReference ? .orange : .secondary)
        }
      }
      LabeledContent("Platform", value: plan.platforms.map(\.description).joined(separator: ", "))
      if !plan.secrets.isEmpty {
        LabeledContent("Build secrets", value: "\(plan.secrets.count)")
        ForEach(plan.secrets) { secret in
          HStack {
            Text(secret.id)
              .font(.body.monospaced())
            Spacer()
            Text("\(secret.displayPath) · \(secret.byteCount) bytes")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .privacySensitive()
        }
        Text(
          "Only IDs and file metadata are retained in this plan; values remain in pinned source files until execution."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if plan.replacesExistingTags {
        Toggle("Allow replacing reviewed existing tags", isOn: $allowsTagReplacement)
          .tint(.orange)
      }
      if plan.output.replacesExistingDestination {
        Toggle("Allow replacing the reviewed archive", isOn: $allowsOutputReplacement)
          .tint(.orange)
      }
      Toggle("Allow recreating a stopped builder and cache", isOn: $allowsRecreateStoppedBuilder)
      Toggle("Allow stopping a running shared builder", isOn: $allowsStopRunningBuilder)
        .tint(.red)
      Text(
        "A running-builder change may interrupt an external container CLI build. Identity conflicts and unknown states are never overridden by these confirmations."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var progressSection: some View {
    Section("Progress") {
      if model.isWorking {
        ProgressView()
          .controlSize(.small)
      }
      if let progress = model.progress {
        Label(progress.message, systemImage: icon(for: progress.phase))
        if !progress.logTail.isEmpty {
          ScrollView {
            Text(progress.logTail)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 100, maxHeight: 260)
        }
      }
    }
  }

  private func resultSection(_ result: ImageBuildResult) -> some View {
    Section("Last build") {
      switch result.output {
      case .imageStore(let digest, let tags):
        Label("Image ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        LabeledContent("Digest") {
          Text(digest)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        LabeledContent("Tags", value: tags.joined(separator: ", "))

      case .ociArchive(let destination, let sha256, let byteCount):
        Label("OCI archive exported", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        outputDestinationRow(destination)
        outputDigestRow(sha256)
        LabeledContent("Size", value: byteCount.formatted(.byteCount(style: .file)))

      case .rootFilesystemArchive(let destination, let sha256, let byteCount):
        Label("Root filesystem tar exported", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        outputDestinationRow(destination)
        outputDigestRow(sha256)
        LabeledContent("Size", value: byteCount.formatted(.byteCount(style: .file)))

      case .rootFilesystemDirectory(let destination, let byteCount, let entryCount):
        Label("Root filesystem folder exported", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        outputDestinationRow(destination)
        LabeledContent("Entries", value: entryCount.formatted())
        LabeledContent("File data", value: byteCount.formatted(.byteCount(style: .file)))
      }

      LabeledContent(
        "Build time",
        value: Duration.milliseconds(result.durationMilliseconds).formatted(.units())
      )
    }
  }

  private func outputDestinationRow(_ destination: URL) -> some View {
    LabeledContent("Destination") {
      Text(destination.path(percentEncoded: false))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .privacySensitive()
    }
  }

  private func outputDigestRow(_ digest: String) -> some View {
    LabeledContent("SHA-256") {
      Text(digest)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  private var canPrepare: Bool {
    let hasReference =
      outputKind.isRootFilesystem
      || !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasDestination =
      !outputKind.requiresDestination
      || (outputDestinationParent != nil
        && isValidOutputDestinationName(outputDestinationName))
    return contextDirectory != nil
      && hasReference
      && hasDestination
      && secretDrafts.allSatisfy {
        !$0.secretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.sourceURL != nil
      }
      && operationTask == nil
  }

  private var inputsAreLocked: Bool {
    model.plan != nil || model.isWorking
  }

  private func makeRequest() -> ImageBuildRequest {
    ImageBuildRequest(
      contextDirectory: contextDirectory!,
      dockerfile: dockerfile,
      secrets: secretDrafts.compactMap { draft in
        draft.sourceURL.map {
          ImageBuildSecretSelection(
            id: draft.secretID.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: $0
          )
        }
      },
      tags:
        outputKind.isRootFilesystem
        ? [] : splitLines(tag.replacingOccurrences(of: ",", with: "\n")),
      platforms: [platform.value],
      buildArguments: splitLines(buildArguments),
      labels: splitLines(labels),
      targetStage: targetStage.trimmingCharacters(in: .whitespacesAndNewlines),
      noCache: noCache,
      pullLatest: pullLatest,
      builderCPUCount: usesCustomBuilderResources ? builderCPUCount : nil,
      builderMemoryMiB: usesCustomBuilderResources ? builderMemoryMiB : nil,
      output: makeOutputSelection()
    )
  }

  private func makeOutputSelection() -> ImageBuildOutputSelection {
    guard outputKind.requiresDestination else { return .imageStore }
    let name = outputDestinationName.trimmingCharacters(in: .whitespacesAndNewlines)
    let destination = outputDestinationParent!.appending(
      path: name,
      directoryHint:
        outputKind == .rootFilesystemDirectory ? .isDirectory : .notDirectory
    )
    return ImageBuildOutputSelection(
      kind: outputKind,
      destinationURL: destination
    )
  }

  private func resetOutputDraft(_ kind: ImageBuildOutputKind) {
    allowsOutputReplacement = false
    outputDestinationName =
      switch kind {
      case .imageStore:
        ""
      case .ociArchive:
        "image.oci.tar"
      case .rootFilesystemArchive:
        "rootfs.tar"
      case .rootFilesystemDirectory:
        "rootfs"
      }
    model.clearResult()
  }

  private func isValidOutputDestinationName(_ value: String) -> Bool {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty
      && name != "."
      && name != ".."
      && !name.contains("/")
      && !name.contains("\0")
      && name.utf8.count <= 255
  }

  private func buildButtonTitle(for plan: ImageBuildPlan) -> String {
    switch plan.output.kind {
    case .imageStore:
      "Build \(plan.tags.first?.reference ?? "Image")"
    case .ociArchive:
      "Export OCI Archive"
    case .rootFilesystemArchive:
      "Export Root Filesystem Tar"
    case .rootFilesystemDirectory:
      "Export Root Filesystem Folder"
    }
  }

  private func splitLines(_ value: String) -> [String] {
    value.split(whereSeparator: \Character.isNewline).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }

  private func confirmationMessage(for plan: ImageBuildPlan) -> String {
    let platforms = plan.platforms.map(\.description).joined(separator: ", ")
    var warnings: [String]
    switch plan.output.kind {
    case .imageStore:
      warnings = [
        "Build \(platforms) from the private reviewed context and apply \(plan.tags.map(\.reference).joined(separator: ", "))."
      ]
    case .ociArchive:
      warnings = [
        "Build \(platforms) and commit an OCI image archive with logical reference \(plan.tags[0].reference) to the reviewed destination."
      ]
    case .rootFilesystemArchive:
      warnings = [
        "Build \(platforms) and commit the final stage’s files as a root filesystem tar archive."
      ]
    case .rootFilesystemDirectory:
      warnings = [
        "Build \(platforms) and commit the final stage’s files into a new reviewed folder."
      ]
    }
    if !plan.secrets.isEmpty {
      warnings.append(
        "\(plan.secrets.count) reviewed secret file(s) will be streamed once; BuildKit output will be suppressed."
      )
    }
    if plan.replacesExistingTags {
      warnings.append("Existing local tags will move only if their reviewed digests are unchanged.")
    }
    if plan.output.replacesExistingDestination {
      warnings.append(
        "The existing archive will be replaced only if its reviewed identity is unchanged."
      )
    }
    if allowsStopRunningBuilder {
      warnings.append("A differently configured running shared builder may be stopped.")
    } else if allowsRecreateStoppedBuilder {
      warnings.append("A differently configured stopped builder and its cache may be recreated.")
    }
    return warnings.joined(separator: " ")
  }

  private func icon(for phase: ImageBuildProgress.Phase) -> String {
    switch phase {
    case .stagingContext: "doc.on.doc"
    case .stagingSecrets: "key.horizontal"
    case .preparingBuilder: "shippingbox"
    case .connectingBuilder: "cable.connector"
    case .building: "hammer"
    case .exportingArtifact: "archivebox"
    case .importingImage: "square.and.arrow.down"
    case .verifyingPlatforms: "checkmark.shield"
    case .taggingImage: "tag"
    case .completed: "checkmark.circle.fill"
    }
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
}
