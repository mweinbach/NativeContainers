import Foundation

struct ImageBuildRequest: Equatable, Sendable {
  let contextDirectory: URL
  let dockerfile: URL?
  let tags: [String]
  let platforms: [ContainerBuildPlatform]
  let buildArguments: [String]
  let labels: [String]
  let targetStage: String
  let noCache: Bool
  let pullLatest: Bool
  let builderCPUCount: Int?
  let builderMemoryMiB: Int?
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
  let tags: [ContainerBuildTagExpectation]
  let platforms: [ContainerBuildPlatform]
  let buildArguments: [String]
  let labels: [String]
  let targetStage: String
  let noCache: Bool
  let pullLatest: Bool
  let builderCPUCount: Int?
  let builderMemoryMiB: Int?
  let generatedAt: Date

  var replacesExistingTags: Bool {
    tags.contains(where: \.replacesExistingReference)
  }

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

  static let none = ImageBuildAuthorization(
    allowsTagReplacement: false,
    allowsRecreateStoppedBuilder: false,
    allowsStopRunningBuilder: false
  )
}

struct ImageBuildResult: Equatable, Sendable {
  let buildID: UUID
  let imageDigest: String
  let tags: [String]
  let platforms: [ContainerBuildPlatform]
  let durationMilliseconds: Int64
  let logTail: String
}

struct ImageBuildProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case stagingContext
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
  case unsupported

  var errorDescription: String? {
    switch self {
    case .emptyTags:
      "Enter at least one output image tag."
    case .duplicateTags:
      "Output image tags must be unique."
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
