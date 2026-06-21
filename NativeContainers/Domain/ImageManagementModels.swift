import Foundation

struct ImageVariantInspection: Equatable, Sendable, Identifiable {
  let platform: String
  let os: String
  let architecture: String
  let variant: String?
  let manifestDigest: String
  let sizeBytes: Int64
  let createdAt: Date?
  let author: String?
  let user: String?
  let workingDirectory: String?
  let entrypoint: [String]
  let command: [String]
  let environment: [String]
  let labels: [String: String]
  let layerCount: Int

  var id: String { "\(platform)@\(manifestDigest)" }
}

struct ImageInspection: Equatable, Sendable {
  let reference: String
  let displayReference: String
  let digest: String
  let mediaType: String
  let indexSizeBytes: Int64
  let createdAt: Date?
  let variants: [ImageVariantInspection]
  let aliases: [String]
  let usedByContainerIDs: [String]
  let warnings: [String]
}

struct ImageTagPlan: Equatable, Sendable {
  let sourceReference: String
  let sourceDigest: String
  let targetReference: String
  let displayTargetReference: String
  let replacedDigest: String?

  var replacesDifferentImage: Bool {
    replacedDigest.map { $0 != sourceDigest } ?? false
  }
}

struct ImageDeletionPlan: Equatable, Sendable {
  let reference: String
  let digest: String
  let aliases: [String]
  let usedByContainerIDs: [String]
  let isInfrastructureImage: Bool

  var canDelete: Bool {
    !isInfrastructureImage && usedByContainerIDs.isEmpty
  }
}

enum ImagePruneMode: String, CaseIterable, Equatable, Sendable, Identifiable {
  case dangling
  case allUnused

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dangling: "Dangling"
    case .allUnused: "All unused"
    }
  }

  var explanation: String {
    switch self {
    case .dangling:
      "Remove untagged images that are not used by a container."
    case .allUnused:
      "Remove every image reference that is not used by a container."
    }
  }
}

struct ImagePruneCandidate: Equatable, Sendable, Identifiable {
  let reference: String
  let digest: String
  let indexSizeBytes: Int64

  var id: String { reference }
}

struct ImagePrunePlan: Equatable, Sendable {
  let mode: ImagePruneMode
  let generatedAt: Date
  let candidates: [ImagePruneCandidate]
  let estimatedReclaimableBytes: UInt64?
}

struct ImageOperationFailure: Equatable, Sendable, Identifiable {
  let reference: String
  let message: String

  var id: String { reference }
}

struct ImageCleanupResult: Equatable, Sendable {
  let removedReferences: [String]
  let failedReferences: [ImageOperationFailure]
  let removedBlobDigests: [String]
  let reclaimedBytes: UInt64

  var completedWithoutFailures: Bool { failedReferences.isEmpty }
}

struct ImageCleanupPartialCompletionError: LocalizedError, Sendable {
  let result: ImageCleanupResult

  var errorDescription: String? {
    let removed = result.removedReferences.count
    let remaining = result.failedReferences.count
    return
      "Image cleanup was cancelled after removing \(removed) reference(s); \(remaining) reviewed reference(s) remain."
  }
}

enum ImageManagementError: LocalizedError, Equatable, Sendable {
  case unsupported
  case missingReference
  case missingTargetReference
  case infrastructureImage(String)
  case imageInUse(reference: String, containerIDs: [String])
  case tagWouldReplace(reference: String)
  case stalePlan(String)
  case insecureTransportRequiresConfirmation(String)
  case pullWouldReplace(String)
  case allPlatformPullRequiresConfirmation
  case remoteTagReplacementRequiresConfirmation(String)
  case platformUnavailable(platform: String, reference: String)
  case noRunnablePlatforms(String)
  case invalidConcurrentDownloads
  case missingRegistryHost(String)

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "Image management is unavailable from this container service."
    case .missingReference:
      "Choose an image first."
    case .missingTargetReference:
      "Enter a target image reference."
    case .infrastructureImage(let reference):
      "“\(reference)” is managed by Apple’s container runtime and cannot be modified here."
    case .imageInUse(let reference, let containerIDs):
      "“\(reference)” is used by: \(containerIDs.joined(separator: ", "))."
    case .tagWouldReplace(let reference):
      "The tag “\(reference)” already points to a different image."
    case .stalePlan(let operation):
      "The image changed after the \(operation) was reviewed. Review it again before continuing."
    case .insecureTransportRequiresConfirmation(let hostname):
      "Confirm plain-text HTTP before transferring image data with \(hostname)."
    case .pullWouldReplace(let reference):
      "Confirm updating the existing local image reference “\(reference)”."
    case .allPlatformPullRequiresConfirmation:
      "Confirm pulling every platform because downloading and optional unpacking can consume substantial disk space."
    case .remoteTagReplacementRequiresConfirmation(let reference):
      "Confirm pushing “\(reference)”; the remote mutable tag may be replaced."
    case .platformUnavailable(let platform, let reference):
      "“\(reference)” does not contain the exact \(platform) platform."
    case .noRunnablePlatforms(let reference):
      "“\(reference)” does not contain a runnable image platform."
    case .invalidConcurrentDownloads:
      "Concurrent image downloads must be between 1 and 16."
    case .missingRegistryHost(let reference):
      "“\(reference)” does not contain a registry hostname. Tag it with a fully qualified reference first."
    }
  }
}
