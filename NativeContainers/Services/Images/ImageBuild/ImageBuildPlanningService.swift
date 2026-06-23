import ContainerAPIClient
import ContainerizationOCI
import Foundation

protocol ImageBuildRuntimeCapabilityVerifying: Sendable {
  func verifyBuildSSHSupport() async throws
}

struct NativeContainersImageBuildRuntimeCapabilityVerifier:
  ImageBuildRuntimeCapabilityVerifying
{
  static let requiredRuntimeVersion = "1.0.0-nc.2"

  private let activeRuntimeVerifier: any ActiveNativeRuntimeVerifying

  init(
    activeRuntimeVerifier: any ActiveNativeRuntimeVerifying =
      ProductionActiveNativeRuntimeVerifier()
  ) {
    self.activeRuntimeVerifier = activeRuntimeVerifier
  }

  func verifyBuildSSHSupport() async throws {
    do {
      let verified = try await activeRuntimeVerifier.verifyActiveNativeRuntime()
      guard
        verified.origin == .nativeContainers,
        verified.version == Self.requiredRuntimeVersion,
        verified.builderArtifact == .pinned
      else {
        throw ImageBuildError.buildSSHRequiresNativeContainersRuntime(
          required: Self.requiredRuntimeVersion
        )
      }
    } catch {
      throw ImageBuildError.buildSSHRequiresNativeContainersRuntime(
        required: Self.requiredRuntimeVersion
      )
    }
  }
}

protocol ImageBuildRequestValidating: Sendable {
  func validate(_ request: ImageBuildRequest) throws
}

struct ImageBuildRequestValidator: ImageBuildRequestValidating {
  func validate(_ request: ImageBuildRequest) throws {
    if request.cachePolicy == .disabled, request.remoteCache != nil {
      throw ImageBuildError.remoteCacheRequiresCaching
    }
    if let remoteCache = request.remoteCache {
      _ = try ImageBuildRemoteCacheReview.prepare(
        remoteCache,
        outputReferences: []
      )
    }
    if !request.secrets.isEmpty {
      _ = try ImageBuildSecretPolicy.validate(
        request.secrets,
        contextDirectory: request.contextDirectory
      )
    }
    switch request.output.kind {
    case .imageStore:
      guard !request.tags.isEmpty else { throw ImageBuildError.emptyTags }
    case .ociArchive:
      guard request.tags.count == 1 else { throw ImageBuildError.archiveReferenceCount }
    case .rootFilesystemArchive, .rootFilesystemDirectory:
      guard request.tags.isEmpty else { throw ImageBuildError.unexpectedTags }
      guard request.platforms.count == 1 else {
        throw ImageBuildError.rootFilesystemSinglePlatform
      }
    }
    guard !request.platforms.isEmpty else { throw ImageBuildError.emptyPlatforms }
    guard Set(request.platforms).count == request.platforms.count else {
      throw ImageBuildError.duplicatePlatforms
    }
    let supported = Set([ContainerBuildPlatform.current, .amd64])
    if let unsupported = request.platforms.first(where: { !supported.contains($0) }) {
      throw ImageBuildError.unsupportedPlatform(unsupported.description)
    }
    for value in request.buildArguments + request.labels {
      guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
        throw ImageBuildError.invalidKeyValue(value)
      }
    }
    if let cpu = request.builderCPUCount, !(1...32).contains(cpu) {
      throw ImageBuildError.invalidBuilderCPUCount
    }
    if let memory = request.builderMemoryMiB, !(512...131_072).contains(memory) {
      throw ImageBuildError.invalidBuilderMemory
    }
  }
}

protocol ImageBuildPlanning: Sendable {
  func prepare(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan
}

struct AppleImageBuildPlanningService: ImageBuildPlanning {
  private let validator: any ImageBuildRequestValidating
  private let contextStager: any BuildContextStaging
  private let secretManager: any ImageBuildSecretManaging
  private let sshAgentService: any ContainerSSHAgentForwardingManaging
  private let runtimeCapabilityVerifier: any ImageBuildRuntimeCapabilityVerifying
  private let imageStore: any ImageBuildStoring
  private let outputManager: any ImageBuildOutputManaging

  init(
    validator: any ImageBuildRequestValidating = ImageBuildRequestValidator(),
    contextStager: any BuildContextStaging,
    secretManager: any ImageBuildSecretManaging,
    sshAgentService: any ContainerSSHAgentForwardingManaging =
      AppleContainerSSHAgentService(),
    runtimeCapabilityVerifier: any ImageBuildRuntimeCapabilityVerifying =
      NativeContainersImageBuildRuntimeCapabilityVerifier(),
    imageStore: any ImageBuildStoring,
    outputManager: any ImageBuildOutputManaging
  ) {
    self.validator = validator
    self.contextStager = contextStager
    self.secretManager = secretManager
    self.sshAgentService = sshAgentService
    self.runtimeCapabilityVerifier = runtimeCapabilityVerifier
    self.imageStore = imageStore
    self.outputManager = outputManager
  }

  func prepare(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    try validator.validate(request)
    if let sshAgent = request.sshAgent {
      try await runtimeCapabilityVerifier.verifyBuildSSHSupport()
      _ = try sshAgentService.environment(for: sshAgent)
    }
    let secretReviewID = request.secrets.isEmpty ? nil : UUID()
    var stagedContext: StagedBuildContext?
    var outputPlan: ImageBuildOutputPlan?

    do {
      let preparedOutput = try await outputManager.prepare(request.output)
      outputPlan = preparedOutput
      let tags = try await reviewedTags(for: request)
      let remoteCache = try request.remoteCache.map {
        try ImageBuildRemoteCacheReview.prepare(
          $0,
          outputReferences: tags.map(\.reference)
        )
      }

      let secretPreparation: ImageBuildSecretPreparation
      if let secretReviewID {
        await progress(
          ImageBuildProgress(
            phase: .stagingSecrets,
            message: "Pinning private secret sources for review",
            logTail: ""
          )
        )
        secretPreparation = try await secretManager.prepare(
          reviewID: secretReviewID,
          selections: request.secrets,
          contextDirectory: request.contextDirectory
        )
      } else {
        secretPreparation = ImageBuildSecretPreparation(
          reviews: [],
          excludedContextFiles: []
        )
      }

      try Task.checkCancellation()
      await progress(
        ImageBuildProgress(
          phase: .stagingContext,
          message: "Copying the build context into a private review boundary",
          logTail: ""
        )
      )
      let dockerfile = resolvedDockerfile(
        requested: request.dockerfile,
        context: request.contextDirectory
      )
      let staged = try await contextStager.stage(
        sourceDirectory: request.contextDirectory,
        dockerfile: dockerfile,
        dockerignore: dockerignoreSelection(dockerfile: dockerfile),
        excludingFileIdentities: secretPreparation.excludedContextFiles
      )
      stagedContext = staged
      if let secretReviewID {
        try await secretManager.revalidate(reviewID: secretReviewID)
      }
      try Task.checkCancellation()

      return ImageBuildPlan(
        id: staged.id,
        sourceContextDirectory: request.contextDirectory.standardizedFileURL,
        stagedContextDirectory: staged.contextURL,
        stagedDockerfile: staged.dockerfileURL,
        dockerfileSHA256: staged.dockerfileSHA256,
        stagedDockerignore: staged.dockerignoreURL,
        dockerignoreSHA256: staged.dockerignoreSHA256,
        contextFingerprint: staged.fingerprint,
        secretReviewID: secretReviewID,
        secrets: secretPreparation.reviews,
        tags: tags,
        platforms: request.platforms,
        buildArguments: request.buildArguments,
        labels: request.labels,
        targetStage: request.targetStage,
        cachePolicy: request.cachePolicy,
        remoteCache: remoteCache,
        pullLatest: request.pullLatest,
        builderCPUCount: request.builderCPUCount,
        builderMemoryMiB: request.builderMemoryMiB,
        sshAgent: request.sshAgent,
        output: preparedOutput,
        generatedAt: Date()
      )
    } catch {
      if let secretReviewID {
        await secretManager.discard(reviewID: secretReviewID)
      }
      if let stagedContext {
        try? await contextStager.discard(stagedContext)
      }
      if let outputPlan {
        await outputManager.discard(outputPlan)
      }
      throw error
    }
  }

  private func reviewedTags(
    for request: ImageBuildRequest
  ) async throws -> [ContainerBuildTagExpectation] {
    switch request.output.kind {
    case .imageStore:
      try await imageStore.resolveTagExpectations(request.tags)
    case .ociArchive:
      try await imageStore.resolveTagExpectations(request.tags).map {
        ContainerBuildTagExpectation(reference: $0.reference, existingDigest: nil)
      }
    case .rootFilesystemArchive, .rootFilesystemDirectory:
      []
    }
  }

  private func resolvedDockerfile(requested: URL?, context: URL) -> URL {
    if let requested { return requested }
    let dockerfile = context.appending(path: "Dockerfile", directoryHint: .notDirectory)
    if FileManager.default.fileExists(atPath: dockerfile.path(percentEncoded: false)) {
      return dockerfile
    }
    return context.appending(path: "Containerfile", directoryHint: .notDirectory)
  }

  private func dockerignoreSelection(
    dockerfile: URL
  ) -> BuildContextDockerignoreSelection {
    let sibling = dockerfile.appendingPathExtension("dockerignore")
    if FileManager.default.fileExists(atPath: sibling.path(percentEncoded: false)) {
      return .dockerfileSibling
    }
    return .conventional
  }
}

enum ImageBuildRemoteCacheReview {
  static func prepare(
    _ selection: ImageBuildRemoteCacheSelection,
    outputReferences: [String]
  ) throws -> ContainerBuildRemoteCacheProfile {
    let requested = selection.reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requested.isEmpty else {
      throw ImageBuildError.invalidRemoteCacheReference(selection.reference)
    }

    let parsed: Reference
    do {
      parsed = try Reference.parse(requested)
    } catch {
      throw ImageBuildError.invalidRemoteCacheReference(selection.reference)
    }
    guard
      let domain = parsed.domain,
      !domain.isEmpty,
      domain == domain.lowercased(),
      hasValidPort(domain),
      parsed.digest == nil
    else {
      throw ImageBuildError.invalidRemoteCacheReference(selection.reference)
    }
    parsed.normalize()
    let canonical = parsed.description
    guard
      parsed.tag != nil,
      !outputReferences.contains(canonical)
    else {
      if outputReferences.contains(canonical) {
        throw ImageBuildError.remoteCacheMatchesOutput(canonical)
      }
      throw ImageBuildError.invalidRemoteCacheReference(selection.reference)
    }

    return ContainerBuildRemoteCacheProfile(
      reference: canonical,
      access: selection.access,
      exportMode: selection.exportMode
    )
  }

  private static func hasValidPort(_ domain: String) -> Bool {
    let hasExplicitPort =
      domain.hasPrefix("[")
      ? domain.contains("]:")
      : domain.contains(":")
    guard hasExplicitPort else { return true }
    guard
      let components = URLComponents(string: "https://\(domain)"),
      components.host != nil,
      let port = components.port
    else { return false }
    return (1...65_535).contains(port)
  }
}
