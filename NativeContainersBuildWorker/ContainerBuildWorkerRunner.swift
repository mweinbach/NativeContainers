import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import Containerization
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import NIOPosix

struct ContainerBuildWorkerRunner {
  private static let maximumDockerfileBytes = 16 * 1_024

  let writer: ContainerBuildWorkerEventWriter

  func run(
    _ request: ContainerBuildWorkerRequest,
    secrets: ContainerBuildSecretValues
  ) async throws {
    guard request.protocolVersion == ContainerBuildWorkerRequest.currentProtocolVersion else {
      throw ContainerBuildWorkerError.make(
        code: "protocol-version",
        message:
          "Unsupported build-worker protocol version \(request.protocolVersion); expected \(ContainerBuildWorkerRequest.currentProtocolVersion)."
      )
    }

    try await writer.send(.progress(.validating, message: "Validating build request"))
    let controller = ContainerBuilderController(writer: writer)

    switch request.operation {
    case .startBuilder:
      guard secrets.isEmpty else {
        throw ContainerBuildWorkerError.make(
          code: "unexpected-secrets",
          message: "Builder preparation does not accept a secret payload."
        )
      }
      let reviewedBuilder = try await controller.ensureBuilder(requested: request.builder)
      let socket = try await controller.dialReviewedBuilder(reviewedBuilder)
      try socket.close()
      try await writer.send(.builderReady(message: "Apple’s BuildKit service is ready"))
    case .build:
      guard let build = request.build else {
        throw ContainerBuildWorkerError.make(
          code: "missing-build",
          message: "A build operation requires a build specification."
        )
      }
      guard build.secretIDs == secrets.ids else {
        throw ContainerBuildWorkerError.make(
          code: "secret-payload",
          message: "The secret payload did not match the reviewed build request.",
          buildID: build.buildID
        )
      }
      let expectedSSHAgentIDs = request.builder.forwardsSSHAgent ? ["default"] : []
      guard build.sshAgentIDs == expectedSSHAgentIDs else {
        throw ContainerBuildWorkerError.make(
          code: "ssh-agent-request",
          message:
            "Build SSH forwarding must use exactly the reviewed agent ID “default” and matching builder configuration.",
          buildID: build.buildID
        )
      }
      let reviewedBuilder = try await controller.requireRunningBuilder(
        requested: request.builder
      )
      var result: ContainerBuildWorkerResult?
      try await secrets.consume { values in
        result = try await performBuild(
          build,
          secrets: values,
          reviewedBuilder: reviewedBuilder,
          controller: controller
        )
      }
      guard let result else {
        throw ContainerBuildWorkerError.make(
          code: "secret-payload",
          message: "The one-shot secret payload was not consumed.",
          buildID: build.buildID
        )
      }
      try await writer.send(.completed(result))
    }
  }

  private func performBuild(
    _ request: ContainerBuildWorkerBuildRequest,
    secrets: [String: Data],
    reviewedBuilder: ReviewedContainerBuilder,
    controller: ContainerBuilderController
  ) async throws -> ContainerBuildWorkerResult {
    let startedAt = Date()
    let systemConfiguration = reviewedBuilder.systemConfiguration
    let inputs = try validateBuildInputs(request, systemConfiguration: systemConfiguration)
    let stagedContext = stagedContext(from: request, inputs: inputs)
    let contextStager = BuildContextStager(
      stagingRoot: inputs.context.deletingLastPathComponent()
    )
    try await contextStager.validate(stagedContext)
    let internalReference = stagingReference(for: request.buildID)
    if request.outputKind == .imageStore {
      try await revalidateTagExpectations(request, systemConfiguration: systemConfiguration)
      try await requireStagingReferenceAvailable(internalReference, buildID: request.buildID)
    }

    try await writer.send(.progress(.connectingBuilder, message: "Connecting to BuildKit"))
    let socket = try await controller.dialReviewedBuilder(reviewedBuilder)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let builder = try Builder(
      socket: socket,
      group: group,
      logger: Logger(label: "com.nativecontainers.build-worker.grpc")
    )
    _ = try await builder.info()

    let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
    let sharedExportRoot = health.appRoot.appendingPathComponent(
      ContainerBuilderController.resourceDirectoryName
    )
    let exportDirectory = sharedExportRoot.appendingPathComponent(
      request.buildID.uuidString.lowercased()
    )
    guard !FileManager.default.fileExists(atPath: exportDirectory.path(percentEncoded: false))
    else {
      throw ContainerBuildWorkerError.make(
        code: "export-conflict",
        message: "The isolated export directory for this build already exists.",
        buildID: request.buildID
      )
    }
    try FileManager.default.createDirectory(
      at: exportDirectory,
      withIntermediateDirectories: false
    )
    defer {
      try? FileManager.default.removeItem(at: exportDirectory)
    }

    let exporterConfiguration = ContainerBuildExporterConfiguration(
      outputKind: request.outputKind
    )
    let artifactKind: ContainerBuildWorkerArtifactKind
    let expectedOutput: URL
    let buildMessage: String
    switch request.outputKind {
    case .imageStore, .ociArchive:
      artifactKind = .ociArchive
      expectedOutput = exportDirectory.appendingPathComponent("out.tar")
      buildMessage = "Building OCI image"
    case .rootFilesystemArchive:
      artifactKind = .rootFilesystemArchive
      expectedOutput = exportDirectory.appendingPathComponent("out.tar")
      buildMessage = "Building root filesystem archive"
    case .rootFilesystemDirectory:
      artifactKind = .rootFilesystemDirectory
      expectedOutput = exportDirectory.appendingPathComponent("local")
      buildMessage = "Building root filesystem directory"
    }

    let buildTags: [String]
    if request.outputKind == .ociArchive {
      buildTags = request.tags.map(\.reference)
    } else {
      buildTags = [internalReference]
    }
    let platforms = try request.platforms.map { try Platform(from: $0.description) }
    let export = Builder.BuildExport(
      type: exporterConfiguration.type,
      destination: expectedOutput,
      additionalFields: exporterConfiguration.additionalFields,
      rawValue: exporterConfiguration.rawValue
    )
    let cacheStore = AppOwnedBuildCacheStore(sharedExportRoot: sharedExportRoot)
    let cacheLease = try await cacheStore.acquireLease(
      policy: request.cachePolicy,
      buildID: request.buildID
    )
    defer { cacheLease?.release() }
    let cacheConfiguration = WorkerCacheConfiguration(
      policy: request.cachePolicy,
      buildID: request.buildID,
      hasImportableCache: cacheLease?.hasImportableCache == true,
      remoteCache: request.remoteCache
    )
    let configuration = Builder.BuildConfig(
      buildID: request.buildID.uuidString.lowercased(),
      contentStore: RemoteContentStoreClient(),
      buildArgs: request.buildArguments,
      secrets: secrets,
      sshAgentIDs: request.sshAgentIDs,
      contextDir: inputs.context.path(percentEncoded: false),
      dockerfile: inputs.dockerfile,
      dockerignore: inputs.dockerignore,
      labels: request.labels,
      noCache: request.cachePolicy == .disabled,
      platforms: platforms,
      terminal: nil,
      tags: buildTags,
      target: request.targetStage,
      quiet: !secrets.isEmpty,
      exports: [export],
      cacheIn: cacheConfiguration.cacheIn,
      cacheOut: cacheConfiguration.cacheOut,
      pull: request.pullLatest,
      containerSystemConfig: systemConfiguration
    )

    try Task.checkCancellation()
    try await contextStager.validate(stagedContext)
    try await writer.send(.progress(.building, message: buildMessage))
    try await builder.build(configuration)
    try Task.checkCancellation()
    try await contextStager.validate(stagedContext)
    if request.outputKind == .imageStore {
      try await revalidateTagExpectations(request, systemConfiguration: systemConfiguration)
      try await requireStagingReferenceAvailable(internalReference, buildID: request.buildID)
    }

    try await writer.send(
      .progress(.exportingArtifact, message: "Isolating the reviewed build output")
    )
    let artifact: ContainerBuildWorkerArtifact
    let privateArtifactStore = PrivateBuildArtifactStore()
    var removePrivateArtifactOnFailure = true
    defer {
      if removePrivateArtifactOnFailure {
        try? privateArtifactStore.remove(buildID: request.buildID)
      }
    }
    do {
      switch artifactKind {
      case .ociArchive, .rootFilesystemArchive:
        let privateArtifact = try privateArtifactStore.persist(
          sourceRootDirectory: sharedExportRoot,
          sourceDirectoryName: request.buildID.uuidString.lowercased(),
          buildID: request.buildID
        )
        artifact = ContainerBuildWorkerArtifact(
          kind: artifactKind,
          path: privateArtifact.url.path(percentEncoded: false),
          sha256: privateArtifact.sha256,
          byteCount: privateArtifact.byteCount,
          entryCount: nil
        )

      case .rootFilesystemDirectory:
        let privateArtifact = try PrivateBuildDirectoryStore().persist(
          sourceRootDirectory: sharedExportRoot,
          sourceDirectoryName: request.buildID.uuidString.lowercased(),
          buildID: request.buildID
        )
        artifact = ContainerBuildWorkerArtifact(
          kind: artifactKind,
          path: privateArtifact.url.path(percentEncoded: false),
          sha256: privateArtifact.sha256,
          byteCount: privateArtifact.byteCount,
          entryCount: privateArtifact.entryCount
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ContainerBuildWorkerError.make(
        code: "artifact-isolation-failed",
        message: "Could not isolate and bind the build output outside the builder mount.",
        buildID: request.buildID
      )
    }
    let preparedCache: AppOwnedBuildCachePreparedExport?
    if let cacheLease {
      try Task.checkCancellation()
      preparedCache = try cacheLease.prepareForHostCommit()
      try await writer.send(
        .progress(
          .exportingArtifact,
          message: "Prepared app-owned cache (\(preparedCache?.snapshot.entryCount ?? 0) entries)"
        )
      )
    } else {
      preparedCache = nil
    }
    let result = ContainerBuildWorkerResult(
      buildID: request.buildID,
      artifact: artifact,
      stagingReference: request.outputKind == .imageStore ? internalReference : nil,
      platforms: request.platforms,
      durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1_000),
      cacheReceipt: preparedCache.map {
        ContainerBuildWorkerCacheReceipt(
          mode: request.cachePolicy,
          handoffToken: $0.handoffToken,
          fingerprintSHA256: $0.fingerprintSHA256,
          byteCount: $0.snapshot.byteCount,
          entryCount: $0.snapshot.entryCount
        )
      }
    )
    removePrivateArtifactOnFailure = false
    return result
  }

  private func stagedContext(
    from request: ContainerBuildWorkerBuildRequest,
    inputs: (context: URL, dockerfile: Data, dockerignore: Data?)
  ) -> StagedBuildContext {
    StagedBuildContext(
      id: request.buildID,
      contextURL: inputs.context,
      dockerfileURL: URL(filePath: request.dockerfilePath).standardizedFileURL,
      dockerfileSHA256: request.dockerfileSHA256,
      dockerignoreURL: request.dockerignorePath.map { URL(filePath: $0).standardizedFileURL },
      dockerignoreSHA256: request.dockerignoreSHA256,
      fingerprint: request.contextFingerprint
    )
  }

  private func stagingReference(for buildID: UUID) -> String {
    let identifier = buildID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return "nativecontainers.local/nativecontainers-build-\(identifier):staging"
  }

  private func requireStagingReferenceAvailable(
    _ reference: String,
    buildID: UUID
  ) async throws {
    let existing = try await ClientImage.list().first { $0.reference == reference }
    guard existing == nil else {
      throw ContainerBuildWorkerError.make(
        code: "staging-conflict",
        message:
          "The isolated staging reference for this build already exists. Use a new build identifier or remove the stale staging reference after review.",
        buildID: buildID,
        partialImageDigest: existing?.digest
      )
    }
  }

  private func validateBuildInputs(
    _ request: ContainerBuildWorkerBuildRequest,
    systemConfiguration: ContainerSystemConfig
  ) throws -> (context: URL, dockerfile: Data, dockerignore: Data?) {
    let fileManager = FileManager.default
    let context = URL(filePath: request.contextPath, directoryHint: .isDirectory)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: context.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ContainerBuildWorkerError.make(
        code: "context",
        message: "The reviewed build context is no longer an accessible directory.",
        buildID: request.buildID
      )
    }

    let dockerfileURL = URL(filePath: request.dockerfilePath)
      .standardizedFileURL.resolvingSymlinksInPath()
    try requireContained(dockerfileURL, in: context, label: "Dockerfile", buildID: request.buildID)
    let dockerfile = try Data(contentsOf: dockerfileURL, options: .mappedIfSafe)
    guard dockerfile.count < Self.maximumDockerfileBytes else {
      throw ContainerBuildWorkerError.make(
        code: "dockerfile-size",
        message:
          "Dockerfile size \(dockerfile.count) bytes must be below Apple container 1.0’s 16 KiB limit.",
        buildID: request.buildID
      )
    }
    guard Self.sha256(dockerfile) == request.dockerfileSHA256 else {
      throw ContainerBuildWorkerError.make(
        code: "dockerfile-changed",
        message: "The Dockerfile changed after review. Review the build again.",
        buildID: request.buildID
      )
    }

    let dockerignore: Data?
    if let dockerignorePath = request.dockerignorePath {
      let url = URL(filePath: dockerignorePath).standardizedFileURL.resolvingSymlinksInPath()
      try requireContained(url, in: context, label: "Docker ignore file", buildID: request.buildID)
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard Self.sha256(data) == request.dockerignoreSHA256 else {
        throw ContainerBuildWorkerError.make(
          code: "dockerignore-changed",
          message: "The Docker ignore file changed after review. Review the build again.",
          buildID: request.buildID
        )
      }
      dockerignore = data
    } else {
      dockerignore = nil
    }

    switch request.outputKind {
    case .imageStore:
      guard !request.tags.isEmpty else {
        throw ContainerBuildWorkerError.make(
          code: "tags",
          message: "At least one output image tag is required.",
          buildID: request.buildID
        )
      }
    case .ociArchive:
      guard request.tags.count == 1, request.tags[0].existingDigest == nil else {
        throw ContainerBuildWorkerError.make(
          code: "archive-reference",
          message: "An OCI archive requires exactly one reviewed logical image reference.",
          buildID: request.buildID
        )
      }
    case .rootFilesystemArchive, .rootFilesystemDirectory:
      guard request.tags.isEmpty else {
        throw ContainerBuildWorkerError.make(
          code: "unexpected-tags",
          message: "Root filesystem outputs do not accept final image tags.",
          buildID: request.buildID
        )
      }
    }
    guard !request.platforms.isEmpty else {
      throw ContainerBuildWorkerError.make(
        code: "platforms",
        message: "At least one exact build platform is required.",
        buildID: request.buildID
      )
    }
    if request.outputKind == .rootFilesystemArchive
      || request.outputKind == .rootFilesystemDirectory
    {
      guard request.platforms.count == 1 else {
        throw ContainerBuildWorkerError.make(
          code: "output-platforms",
          message: "Root filesystem outputs require exactly one platform.",
          buildID: request.buildID
        )
      }
    }
    guard Set(request.tags.map(\.reference)).count == request.tags.count else {
      throw ContainerBuildWorkerError.make(
        code: "duplicate-tags",
        message: "Output image references must be unique.",
        buildID: request.buildID
      )
    }
    for field in request.buildArguments + request.labels {
      guard let separator = field.firstIndex(of: "="), separator != field.startIndex else {
        throw ContainerBuildWorkerError.make(
          code: "key-value",
          message: "Build arguments and labels must use nonempty KEY=value entries.",
          buildID: request.buildID
        )
      }
    }
    for tag in request.tags {
      let parsed = try Reference.parse(tag.reference)
      parsed.normalize()
      guard parsed.description == tag.reference else {
        throw ContainerBuildWorkerError.make(
          code: "tag-normalization",
          message: "Image tag “\(tag.reference)” is not canonical.",
          buildID: request.buildID
        )
      }
      try requireUserManaged(tag.reference, configuration: systemConfiguration)
      if request.outputKind == .imageStore,
        tag.replacesExistingReference,
        !request.allowsTagReplacement
      {
        throw ContainerBuildWorkerError.make(
          code: "tag-replacement",
          message: "Replacing local tag “\(tag.reference)” was not authorized.",
          buildID: request.buildID
        )
      }
    }
    try validateRemoteCache(request)
    return (context, dockerfile, dockerignore)
  }

  private func validateRemoteCache(
    _ request: ContainerBuildWorkerBuildRequest
  ) throws {
    guard let profile = request.remoteCache else { return }
    guard request.cachePolicy != .disabled else {
      throw ContainerBuildWorkerError.make(
        code: "remote-cache-disabled",
        message: "A registry cache cannot be used when build caching is disabled.",
        buildID: request.buildID
      )
    }

    let parsed: Reference
    do {
      parsed = try Reference.parse(profile.reference)
    } catch {
      throw ContainerBuildWorkerError.make(
        code: "remote-cache-reference",
        message: "The reviewed registry cache reference is invalid.",
        buildID: request.buildID
      )
    }
    parsed.normalize()
    guard
      let domain = parsed.domain,
      !domain.isEmpty,
      domain == domain.lowercased(),
      hasValidRemoteCachePort(domain),
      parsed.tag != nil,
      parsed.digest == nil,
      parsed.description == profile.reference
    else {
      throw ContainerBuildWorkerError.make(
        code: "remote-cache-reference",
        message: "The reviewed registry cache reference is not canonical.",
        buildID: request.buildID
      )
    }
    guard !request.tags.contains(where: { $0.reference == profile.reference }) else {
      throw ContainerBuildWorkerError.make(
        code: "remote-cache-output-conflict",
        message: "The registry cache must be separate from every output image reference.",
        buildID: request.buildID
      )
    }
  }

  private func hasValidRemoteCachePort(_ domain: String) -> Bool {
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

  private func revalidateTagExpectations(
    _ request: ContainerBuildWorkerBuildRequest,
    systemConfiguration: ContainerSystemConfig
  ) async throws {
    let current = try await ClientImage.list()
    for tag in request.tags {
      try requireUserManaged(tag.reference, configuration: systemConfiguration)
      let digest = current.first { $0.reference == tag.reference }?.digest
      guard digest == tag.existingDigest else {
        throw ContainerBuildWorkerError.make(
          code: "stale-tag",
          message: "The local tag “\(tag.reference)” changed after review.",
          buildID: request.buildID
        )
      }
    }
  }

  private func requireUserManaged(
    _ reference: String,
    configuration: ContainerSystemConfig
  ) throws {
    let normalized = try ClientImage.normalizeReference(
      reference,
      containerSystemConfig: configuration
    )
    for managed in [configuration.build.image, configuration.vminit.image] {
      let normalizedManaged = try ClientImage.normalizeReference(
        managed,
        containerSystemConfig: configuration
      )
      guard normalized != normalizedManaged else {
        throw ContainerBuildWorkerError.make(
          code: "infrastructure-tag",
          message: "Image tag “\(reference)” is managed by Apple’s container runtime."
        )
      }
    }
  }

  private func requireContained(
    _ child: URL,
    in parent: URL,
    label: String,
    buildID: UUID
  ) throws {
    guard ContainerBuildPathBoundary.contains(child, within: parent) else {
      throw ContainerBuildWorkerError.make(
        code: "path-escape",
        message: "\(label) must resolve inside the reviewed build context.",
        buildID: buildID
      )
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct WorkerCacheConfiguration {
  private static let guestExportRoot = "/var/lib/container-builder-shim/exports"

  let cacheIn: [String]
  let cacheOut: [String]

  init(
    policy: ImageBuildCachePolicy,
    buildID: UUID,
    hasImportableCache: Bool,
    remoteCache: ContainerBuildRemoteCacheProfile?
  ) {
    var cacheIn: [String] = []
    var cacheOut: [String] = []
    switch policy {
    case .disabled, .builderInternal:
      break
    case .appOwnedLocalV1:
      let namespace =
        "\(Self.guestExportRoot)/\(AppOwnedBuildCacheStore.namespaceDirectoryName)"
      if hasImportableCache {
        cacheIn.append(
          "type=local,src=\(namespace)/\(AppOwnedBuildCacheStore.currentDirectoryName)"
        )
      }
      cacheOut.append(
        "type=local,dest=\(namespace)/\(AppOwnedBuildCacheStore.stagingDirectoryName)/\(buildID.uuidString.lowercased()),mode=max"
      )
    }
    if let remoteCache {
      cacheIn.append("type=registry,ref=\(remoteCache.reference)")
      if remoteCache.access.exportsCache {
        cacheOut.append(
          "type=registry,ref=\(remoteCache.reference),mode=\(remoteCache.exportMode.rawValue)"
        )
      }
    }
    self.cacheIn = cacheIn
    self.cacheOut = cacheOut
  }
}
