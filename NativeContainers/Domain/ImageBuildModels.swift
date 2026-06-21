import Foundation

extension ImageBuildOutputKind {
  var title: LocalizedStringResource {
    switch self {
    case .imageStore:
      "Apple Image Store"
    case .ociArchive:
      "OCI Image Archive"
    case .rootFilesystemArchive:
      "Root Filesystem Tar"
    case .rootFilesystemDirectory:
      "Root Filesystem Folder"
    }
  }

  var systemImage: String {
    switch self {
    case .imageStore:
      "shippingbox"
    case .ociArchive:
      "archivebox"
    case .rootFilesystemArchive:
      "doc.zipper"
    case .rootFilesystemDirectory:
      "folder"
    }
  }

  var requiresDestination: Bool {
    self != .imageStore
  }

  var isRootFilesystem: Bool {
    self == .rootFilesystemArchive || self == .rootFilesystemDirectory
  }
}

extension ImageBuildCachePolicy {
  var title: LocalizedStringResource {
    switch self {
    case .disabled:
      "No Cache"
    case .builderInternal:
      "Shared Builder Cache"
    case .appOwnedLocalV1:
      "NativeContainers Local Cache"
    }
  }

  var explanation: LocalizedStringResource {
    switch self {
    case .disabled:
      "Ignore existing BuildKit cache for this build."
    case .builderInternal:
      "Use BuildKit’s cache inside Apple’s shared builder. Deleting the builder deletes this cache."
    case .appOwnedLocalV1:
      "Also export and import a fixed app-owned local cache. No registry credentials or custom cache strings are used."
    }
  }
}

struct ImageBuildOutputSelection: Equatable, Sendable {
  let kind: ImageBuildOutputKind
  let destinationURL: URL?

  static let imageStore = ImageBuildOutputSelection(
    kind: .imageStore,
    destinationURL: nil
  )
}

struct ImageBuildOutputPlan: Equatable, Sendable {
  static let imageStore = ImageBuildOutputPlan(
    reviewID: nil,
    kind: .imageStore,
    destinationURL: nil,
    existingDestinationIdentity: nil
  )

  let reviewID: UUID?
  let kind: ImageBuildOutputKind
  let destinationURL: URL?
  let existingDestinationIdentity: SecureRegularFileIdentity?

  var replacesExistingDestination: Bool {
    existingDestinationIdentity != nil
  }

  var destinationDisplayName: String? {
    destinationURL?.lastPathComponent
  }
}

enum ImageBuildCompletion: Equatable, Sendable {
  case imageStore(digest: String, tags: [String])
  case ociArchive(destination: URL, sha256: String, byteCount: Int64)
  case rootFilesystemArchive(destination: URL, sha256: String, byteCount: Int64)
  case rootFilesystemDirectory(destination: URL, byteCount: Int64, entryCount: Int)

  var kind: ImageBuildOutputKind {
    switch self {
    case .imageStore:
      .imageStore
    case .ociArchive:
      .ociArchive
    case .rootFilesystemArchive:
      .rootFilesystemArchive
    case .rootFilesystemDirectory:
      .rootFilesystemDirectory
    }
  }
}

struct ImageBuildRequest: Equatable, Sendable {
  let contextDirectory: URL
  let dockerfile: URL?
  let secrets: [ImageBuildSecretSelection]
  let tags: [String]
  let platforms: [ContainerBuildPlatform]
  let buildArguments: [String]
  let labels: [String]
  let targetStage: String
  let cachePolicy: ImageBuildCachePolicy
  let pullLatest: Bool
  let builderCPUCount: Int?
  let builderMemoryMiB: Int?
  let output: ImageBuildOutputSelection

  init(
    contextDirectory: URL,
    dockerfile: URL?,
    secrets: [ImageBuildSecretSelection],
    tags: [String],
    platforms: [ContainerBuildPlatform],
    buildArguments: [String],
    labels: [String],
    targetStage: String,
    cachePolicy: ImageBuildCachePolicy = .builderInternal,
    pullLatest: Bool,
    builderCPUCount: Int?,
    builderMemoryMiB: Int?,
    output: ImageBuildOutputSelection = .imageStore
  ) {
    self.contextDirectory = contextDirectory
    self.dockerfile = dockerfile
    self.secrets = secrets
    self.tags = tags
    self.platforms = platforms
    self.buildArguments = buildArguments
    self.labels = labels
    self.targetStage = targetStage
    self.cachePolicy = cachePolicy
    self.pullLatest = pullLatest
    self.builderCPUCount = builderCPUCount
    self.builderMemoryMiB = builderMemoryMiB
    self.output = output
  }

  var noCache: Bool { cachePolicy == .disabled }
}

struct ImageBuildPlan: Equatable, Sendable, Identifiable {
  let id: UUID
  let sourceContextDirectory: URL
  let stagedContextDirectory: URL
  let stagedDockerfile: URL
  let dockerfileSHA256: String
  let stagedDockerignore: URL?
  let dockerignoreSHA256: String?
  let contextFingerprint: String
  let secretReviewID: UUID?
  let secrets: [ImageBuildSecretReview]
  let tags: [ContainerBuildTagExpectation]
  let platforms: [ContainerBuildPlatform]
  let buildArguments: [String]
  let labels: [String]
  let targetStage: String
  let cachePolicy: ImageBuildCachePolicy
  let pullLatest: Bool
  let builderCPUCount: Int?
  let builderMemoryMiB: Int?
  let output: ImageBuildOutputPlan
  let generatedAt: Date

  var replacesExistingTags: Bool {
    tags.contains(where: \.replacesExistingReference)
  }

  var noCache: Bool { cachePolicy == .disabled }

  var builderConfiguration: ContainerBuilderConfiguration {
    ContainerBuilderConfiguration(
      cpuCount: builderCPUCount,
      memoryMiB: builderMemoryMiB,
      allowsRecreateStoppedBuilder: false,
      allowsStopRunningBuilder: false
    )
  }
}

struct ImageBuildAuthorization: Equatable, Sendable {
  let allowsTagReplacement: Bool
  let allowsRecreateStoppedBuilder: Bool
  let allowsStopRunningBuilder: Bool
  let allowsOutputReplacement: Bool

  init(
    allowsTagReplacement: Bool,
    allowsRecreateStoppedBuilder: Bool,
    allowsStopRunningBuilder: Bool,
    allowsOutputReplacement: Bool = false
  ) {
    self.allowsTagReplacement = allowsTagReplacement
    self.allowsRecreateStoppedBuilder = allowsRecreateStoppedBuilder
    self.allowsStopRunningBuilder = allowsStopRunningBuilder
    self.allowsOutputReplacement = allowsOutputReplacement
  }

  static let none = ImageBuildAuthorization(
    allowsTagReplacement: false,
    allowsRecreateStoppedBuilder: false,
    allowsStopRunningBuilder: false,
    allowsOutputReplacement: false
  )
}

struct ImageBuildResult: Equatable, Sendable {
  let buildID: UUID
  let output: ImageBuildCompletion
  let platforms: [ContainerBuildPlatform]
  let durationMilliseconds: Int64
  let logTail: String

  var imageDigest: String? {
    guard case .imageStore(let digest, _) = output else { return nil }
    return digest
  }

  var tags: [String] {
    guard case .imageStore(_, let tags) = output else { return [] }
    return tags
  }

  init(
    buildID: UUID,
    output: ImageBuildCompletion,
    platforms: [ContainerBuildPlatform],
    durationMilliseconds: Int64,
    logTail: String
  ) {
    self.buildID = buildID
    self.output = output
    self.platforms = platforms
    self.durationMilliseconds = durationMilliseconds
    self.logTail = logTail
  }

  init(
    buildID: UUID,
    imageDigest: String,
    tags: [String],
    platforms: [ContainerBuildPlatform],
    durationMilliseconds: Int64,
    logTail: String
  ) {
    self.init(
      buildID: buildID,
      output: .imageStore(digest: imageDigest, tags: tags),
      platforms: platforms,
      durationMilliseconds: durationMilliseconds,
      logTail: logTail
    )
  }
}

struct ImageBuildProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case stagingContext
    case stagingSecrets
    case preparingBuilder
    case connectingBuilder
    case building
    case exportingArtifact
    case importingImage
    case verifyingPlatforms
    case taggingImage
    case completed
  }

  let phase: Phase
  let message: String
  let logTail: String
}

struct ImageBuildPartialCompletionError: LocalizedError, Equatable, Sendable {
  let buildID: UUID
  let imageDigest: String
  let appliedTags: [String]
  let failureMessage: String

  var errorDescription: String? {
    let tags =
      appliedTags.isEmpty
      ? "No final tags were applied." : "Applied tags: \(appliedTags.joined(separator: ", "))."
    return
      "The built image was imported as \(imageDigest), but finalization failed: \(failureMessage) \(tags) The staging reference was retained for recovery."
  }
}

struct ImageBuildImportedImageRecord: Equatable, Sendable {
  let reference: String
  let digest: String
}

struct ImageBuildImportPartialCompletionError: LocalizedError, Equatable, Sendable {
  let buildID: UUID
  let importedImages: [ImageBuildImportedImageRecord]
  let failureMessage: String

  var errorDescription: String? {
    let imported = importedImages.map { "\($0.reference)@\($0.digest)" }.joined(separator: ", ")
    return
      "Apple’s image store imported \(imported), but artifact validation failed: \(failureMessage) Inventory was refreshed; inspect these retained references before retrying."
  }
}

enum ImageBuildError: LocalizedError, Equatable, Sendable {
  case emptyTags
  case duplicateTags
  case archiveReferenceCount
  case unexpectedTags
  case rootFilesystemSinglePlatform
  case emptyPlatforms
  case duplicatePlatforms
  case unsupportedPlatform(String)
  case invalidKeyValue(String)
  case invalidBuilderCPUCount
  case invalidBuilderMemory
  case tagReplacementRequiresConfirmation([String])
  case infrastructureTag(String)
  case stalePlan(String)
  case workerArtifactMismatch
  case unsafeArchiveMembers([String])
  case ambiguousArchive(Int)
  case missingArtifact(String)
  case unsafeArtifact(String)
  case stagingReferenceChanged(String)
  case secretBuildFailed
  case unsupported

  var errorDescription: String? {
    switch self {
    case .emptyTags:
      "Enter at least one output image tag."
    case .duplicateTags:
      "Output image references must be unique."
    case .archiveReferenceCount:
      "Enter exactly one logical image reference for the OCI archive."
    case .unexpectedTags:
      "Root filesystem outputs do not accept final image tags."
    case .rootFilesystemSinglePlatform:
      "Root filesystem archive and directory outputs require exactly one platform."
    case .emptyPlatforms:
      "Choose at least one exact output platform."
    case .duplicatePlatforms:
      "Each output platform may be selected only once."
    case .unsupportedPlatform(let platform):
      "The pinned native builder does not support the requested \(platform) platform."
    case .invalidKeyValue(let value):
      "“\(value)” must use a nonempty KEY=value form."
    case .invalidBuilderCPUCount:
      "Builder CPU count must be between 1 and 32."
    case .invalidBuilderMemory:
      "Builder memory must be between 512 MiB and 128 GiB."
    case .tagReplacementRequiresConfirmation(let tags):
      "Confirm replacing the existing local tags: \(tags.joined(separator: ", "))."
    case .infrastructureTag(let tag):
      "“\(tag)” is managed by Apple’s container runtime and cannot be used as a build output."
    case .stalePlan(let subject):
      "The \(subject) changed after review. Prepare and review the build again."
    case .workerArtifactMismatch:
      "The build worker returned an artifact that did not match the reviewed build."
    case .unsafeArchiveMembers(let members):
      "Apple’s image loader rejected unsafe archive members: \(members.joined(separator: ", "))."
    case .ambiguousArchive(let count):
      "The build artifact contained \(count) images; exactly one was expected."
    case .missingArtifact(let path):
      "The build worker did not leave its reviewed OCI artifact at \(path)."
    case .unsafeArtifact(let path):
      "The build worker’s OCI artifact at \(path) was not a private, regular file."
    case .stagingReferenceChanged(let reference):
      "The isolated staging reference “\(reference)” changed outside this build."
    case .secretBuildFailed:
      "The secret-enabled image build failed. Build output was suppressed to protect secret values."
    case .unsupported:
      "Native image builds are unavailable from this service."
    }
  }
}

enum ImageBuildExecutionSafety {
  static func validate(
    plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    currentDigests: [String: String],
    infrastructureTags: Set<String>
  ) throws {
    let replacements = plan.tags.filter(\.replacesExistingReference).map(\.reference)
    if !replacements.isEmpty, !authorization.allowsTagReplacement {
      throw ImageBuildError.tagReplacementRequiresConfirmation(replacements)
    }
    for tag in plan.tags {
      guard !infrastructureTags.contains(tag.reference) else {
        throw ImageBuildError.infrastructureTag(tag.reference)
      }
      guard currentDigests[tag.reference] == tag.existingDigest else {
        throw ImageBuildError.stalePlan("local tag “\(tag.reference)”")
      }
    }
  }
}
