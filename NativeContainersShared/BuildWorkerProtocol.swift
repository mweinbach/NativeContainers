import Foundation

enum ContainerBuildWorkerOperation: String, Codable, Equatable, Sendable {
  case startBuilder
  case build
}

struct ContainerBuildWorkerRequest: Codable, Equatable, Sendable {
  static let currentProtocolVersion = 4

  let protocolVersion: Int
  let operation: ContainerBuildWorkerOperation
  let builder: ContainerBuilderConfiguration
  let build: ContainerBuildWorkerBuildRequest?

  init(
    protocolVersion: Int = currentProtocolVersion,
    operation: ContainerBuildWorkerOperation,
    builder: ContainerBuilderConfiguration = .default,
    build: ContainerBuildWorkerBuildRequest? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.operation = operation
    self.builder = builder
    self.build = build
  }
}

struct ContainerBuilderConfiguration: Codable, Equatable, Sendable {
  let cpuCount: Int?
  let memoryMiB: Int?
  let allowsRecreateStoppedBuilder: Bool
  let allowsStopRunningBuilder: Bool

  static let `default` = ContainerBuilderConfiguration(
    cpuCount: nil,
    memoryMiB: nil,
    allowsRecreateStoppedBuilder: false,
    allowsStopRunningBuilder: false
  )
}

enum ImageBuildOutputKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case imageStore
  case ociArchive
  case rootFilesystemArchive
  case rootFilesystemDirectory
}

struct ContainerBuildExporterConfiguration: Equatable, Sendable {
  let type: String
  let additionalFields: [String: String]

  init(outputKind: ImageBuildOutputKind) {
    switch outputKind {
    case .imageStore, .ociArchive:
      type = "oci"
      additionalFields = [:]
    case .rootFilesystemArchive:
      type = "tar"
      additionalFields = [:]
    case .rootFilesystemDirectory:
      type = "local"
      additionalFields = ["platform-split": "false"]
    }
  }

  var rawValue: String {
    (["type=\(type)"]
      + additionalFields.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
      .joined(separator: ",")
  }
}

struct ContainerBuildWorkerBuildRequest: Codable, Equatable, Sendable {
  let buildID: UUID
  let outputKind: ImageBuildOutputKind
  let contextPath: String
  let dockerfilePath: String
  let dockerfileSHA256: String
  let contextFingerprint: String
  let dockerignorePath: String?
  let dockerignoreSHA256: String?
  let tags: [ContainerBuildTagExpectation]
  let platforms: [ContainerBuildPlatform]
  let buildArguments: [String]
  let labels: [String]
  let targetStage: String
  let noCache: Bool
  let pullLatest: Bool
  let secretIDs: [String]
  let allowsTagReplacement: Bool

  init(
    buildID: UUID,
    outputKind: ImageBuildOutputKind = .imageStore,
    contextPath: String,
    dockerfilePath: String,
    dockerfileSHA256: String,
    contextFingerprint: String,
    dockerignorePath: String?,
    dockerignoreSHA256: String?,
    tags: [ContainerBuildTagExpectation],
    platforms: [ContainerBuildPlatform],
    buildArguments: [String],
    labels: [String],
    targetStage: String,
    noCache: Bool,
    pullLatest: Bool,
    secretIDs: [String],
    allowsTagReplacement: Bool
  ) {
    self.buildID = buildID
    self.outputKind = outputKind
    self.contextPath = contextPath
    self.dockerfilePath = dockerfilePath
    self.dockerfileSHA256 = dockerfileSHA256
    self.contextFingerprint = contextFingerprint
    self.dockerignorePath = dockerignorePath
    self.dockerignoreSHA256 = dockerignoreSHA256
    self.tags = tags
    self.platforms = platforms
    self.buildArguments = buildArguments
    self.labels = labels
    self.targetStage = targetStage
    self.noCache = noCache
    self.pullLatest = pullLatest
    self.secretIDs = secretIDs
    self.allowsTagReplacement = allowsTagReplacement
  }
}

enum ContainerBuildPathBoundary {
  static func contains(_ child: URL, within parent: URL) -> Bool {
    let parentComponents = parent.standardizedFileURL.pathComponents
    let childComponents = child.standardizedFileURL.pathComponents

    return childComponents.count > parentComponents.count
      && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
  }
}

struct ContainerBuildTagExpectation: Codable, Equatable, Sendable, Identifiable {
  let reference: String
  let existingDigest: String?

  var id: String { reference }
  var replacesExistingReference: Bool { existingDigest != nil }
}

struct ContainerBuildPlatform: Codable, Equatable, Hashable, Sendable, Identifiable {
  let os: String
  let architecture: String
  let variant: String?

  var id: String { description }

  var description: String {
    if let variant { return "\(os)/\(architecture)/\(variant)" }
    return "\(os)/\(architecture)"
  }

  static let current = ContainerBuildPlatform(
    os: "linux",
    architecture: "arm64",
    variant: "v8"
  )
  static let amd64 = ContainerBuildPlatform(
    os: "linux",
    architecture: "amd64",
    variant: nil
  )
}

enum ContainerBuildWorkerEventKind: String, Codable, Equatable, Sendable {
  case hello
  case progress
  case builderReady
  case completed
  case failed
}

enum ContainerBuildWorkerPhase: String, Codable, Equatable, Sendable {
  case validating
  case preparingBuilder
  case connectingBuilder
  case building
  case exportingArtifact
  case importingImage
  case taggingImage
  case completed
}

struct ContainerBuildWorkerEvent: Codable, Equatable, Sendable {
  let kind: ContainerBuildWorkerEventKind
  let protocolVersion: Int?
  let phase: ContainerBuildWorkerPhase?
  let message: String
  let result: ContainerBuildWorkerResult?
  let failure: ContainerBuildWorkerFailure?

  static func hello(
    protocolVersion: Int = ContainerBuildWorkerRequest.currentProtocolVersion
  ) -> ContainerBuildWorkerEvent {
    ContainerBuildWorkerEvent(
      kind: .hello,
      protocolVersion: protocolVersion,
      phase: nil,
      message: "Native build worker protocol \(protocolVersion)",
      result: nil,
      failure: nil
    )
  }

  static func progress(
    _ phase: ContainerBuildWorkerPhase,
    message: String
  ) -> ContainerBuildWorkerEvent {
    ContainerBuildWorkerEvent(
      kind: .progress,
      protocolVersion: nil,
      phase: phase,
      message: message,
      result: nil,
      failure: nil
    )
  }

  static func builderReady(message: String) -> ContainerBuildWorkerEvent {
    ContainerBuildWorkerEvent(
      kind: .builderReady,
      protocolVersion: nil,
      phase: .preparingBuilder,
      message: message,
      result: nil,
      failure: nil
    )
  }

  static func completed(_ result: ContainerBuildWorkerResult) -> ContainerBuildWorkerEvent {
    ContainerBuildWorkerEvent(
      kind: .completed,
      protocolVersion: nil,
      phase: .completed,
      message: "Image build completed",
      result: result,
      failure: nil
    )
  }

  static func failed(_ failure: ContainerBuildWorkerFailure) -> ContainerBuildWorkerEvent {
    ContainerBuildWorkerEvent(
      kind: .failed,
      protocolVersion: nil,
      phase: nil,
      message: failure.message,
      result: nil,
      failure: failure
    )
  }
}

enum ContainerBuildWorkerArtifactKind: String, Codable, Equatable, Sendable {
  case ociArchive
  case rootFilesystemArchive
  case rootFilesystemDirectory
}

struct ContainerBuildWorkerArtifact: Codable, Equatable, Sendable {
  let kind: ContainerBuildWorkerArtifactKind
  let path: String
  let sha256: String
  let byteCount: Int64
  let entryCount: Int?
}

struct ContainerBuildWorkerResult: Codable, Equatable, Sendable {
  let buildID: UUID
  let artifact: ContainerBuildWorkerArtifact
  let stagingReference: String?
  let platforms: [ContainerBuildPlatform]
  let durationMilliseconds: Int64

  var archivePath: String { artifact.path }
  var archiveSHA256: String { artifact.sha256 }
  var archiveByteCount: Int64 { artifact.byteCount }

  init(
    buildID: UUID,
    artifact: ContainerBuildWorkerArtifact,
    stagingReference: String?,
    platforms: [ContainerBuildPlatform],
    durationMilliseconds: Int64
  ) {
    self.buildID = buildID
    self.artifact = artifact
    self.stagingReference = stagingReference
    self.platforms = platforms
    self.durationMilliseconds = durationMilliseconds
  }

  init(
    buildID: UUID,
    archivePath: String,
    archiveSHA256: String,
    archiveByteCount: Int64,
    stagingReference: String,
    platforms: [ContainerBuildPlatform],
    durationMilliseconds: Int64
  ) {
    self.init(
      buildID: buildID,
      artifact: ContainerBuildWorkerArtifact(
        kind: .ociArchive,
        path: archivePath,
        sha256: archiveSHA256,
        byteCount: archiveByteCount,
        entryCount: nil
      ),
      stagingReference: stagingReference,
      platforms: platforms,
      durationMilliseconds: durationMilliseconds
    )
  }
}

struct ContainerBuildWorkerFailure: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let buildID: UUID?
  let partialImageDigest: String?
}
