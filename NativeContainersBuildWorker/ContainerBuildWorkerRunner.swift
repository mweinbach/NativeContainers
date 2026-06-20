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

  func run(_ request: ContainerBuildWorkerRequest) async throws {
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
      let reviewedBuilder = try await controller.requireRunningBuilder(
        requested: request.builder
      )
      let result = try await performBuild(
        build,
        reviewedBuilder: reviewedBuilder,
        controller: controller
      )
      try await writer.send(.completed(result))
    }
  }

  private func performBuild(
    _ request: ContainerBuildWorkerBuildRequest,
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
    let stagingReference = stagingReference(for: request.buildID)
    try await revalidateTagExpectations(request, systemConfiguration: systemConfiguration)
    try await requireStagingReferenceAvailable(stagingReference, buildID: request.buildID)

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
    let exportDirectory = health.appRoot
      .appendingPathComponent(ContainerBuilderController.resourceDirectoryName)
      .appendingPathComponent(request.buildID.uuidString.lowercased())
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
    let archiveURL = exportDirectory.appendingPathComponent("out.tar")
    let platforms = try request.platforms.map { try Platform(from: $0.description) }
    let export = Builder.BuildExport(
      type: "oci",
      destination: archiveURL,
      additionalFields: [:],
      rawValue: "type=oci"
    )
    let configuration = Builder.BuildConfig(
      buildID: request.buildID.uuidString.lowercased(),
      contentStore: RemoteContentStoreClient(),
      buildArgs: request.buildArguments,
      secrets: [:],
      contextDir: inputs.context.path(percentEncoded: false),
      dockerfile: inputs.dockerfile,
      dockerignore: inputs.dockerignore,
      labels: request.labels,
      noCache: request.noCache,
      platforms: platforms,
      terminal: nil,
      tags: [stagingReference],
      target: request.targetStage,
      quiet: false,
      exports: [export],
      cacheIn: [],
      cacheOut: [],
      pull: request.pullLatest,
      containerSystemConfig: systemConfiguration
    )

    try Task.checkCancellation()
    try await contextStager.validate(stagedContext)
    try await writer.send(.progress(.building, message: "Building OCI image"))
    try await builder.build(configuration)
    try Task.checkCancellation()
    try await contextStager.validate(stagedContext)
    try await revalidateTagExpectations(request, systemConfiguration: systemConfiguration)
    try await requireStagingReferenceAvailable(stagingReference, buildID: request.buildID)

    try await writer.send(
      .progress(.exportingArtifact, message: "Verifying the isolated OCI build artifact")
    )
    do {
      _ = try SecureRegularFileValidator.validate(
        rootDirectory: health.appRoot.appendingPathComponent(
          ContainerBuilderController.resourceDirectoryName
        ),
        directoryName: request.buildID.uuidString.lowercased(),
        fileName: archiveURL.lastPathComponent
      )
    } catch let error as SecureRegularFileValidationError {
      let code: String
      switch error {
      case .missing:
        code = "missing-export"
      case .invalidComponent, .unsafeDirectory, .unsafeFile:
        code = "unsafe-export"
      }
      throw ContainerBuildWorkerError.make(
        code: code,
        message: "BuildKit did not produce a private, regular OCI archive.",
        buildID: request.buildID
      )
    }
    let privateArtifact: PrivateBuildArtifact
    do {
      privateArtifact = try PrivateBuildArtifactStore().persist(
        sourceRootDirectory: health.appRoot.appendingPathComponent(
          ContainerBuilderController.resourceDirectoryName
        ),
        sourceDirectoryName: request.buildID.uuidString.lowercased(),
        buildID: request.buildID
      )
    } catch {
      throw ContainerBuildWorkerError.make(
        code: "artifact-isolation-failed",
        message: "Could not isolate and bind the OCI archive outside the builder mount.",
        buildID: request.buildID
      )
    }
    return ContainerBuildWorkerResult(
      buildID: request.buildID,
      archivePath: privateArtifact.url.path(percentEncoded: false),
      archiveSHA256: privateArtifact.sha256,
      archiveByteCount: privateArtifact.byteCount,
      stagingReference: stagingReference,
      platforms: request.platforms,
      durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1_000)
    )
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

    guard !request.tags.isEmpty else {
      throw ContainerBuildWorkerError.make(
        code: "tags",
        message: "At least one output image tag is required.",
        buildID: request.buildID
      )
    }
    guard !request.platforms.isEmpty else {
      throw ContainerBuildWorkerError.make(
        code: "platforms",
        message: "At least one exact build platform is required.",
        buildID: request.buildID
      )
    }
    guard Set(request.tags.map(\.reference)).count == request.tags.count else {
      throw ContainerBuildWorkerError.make(
        code: "duplicate-tags",
        message: "Output image tags must be unique.",
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
      if tag.replacesExistingReference, !request.allowsTagReplacement {
        throw ContainerBuildWorkerError.make(
          code: "tag-replacement",
          message: "Replacing local tag “\(tag.reference)” was not authorized.",
          buildID: request.buildID
        )
      }
    }
    return (context, dockerfile, dockerignore)
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
