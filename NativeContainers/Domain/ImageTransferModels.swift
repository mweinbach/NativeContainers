import Foundation

enum ImagePlatformRequest: String, CaseIterable, Equatable, Sendable, Identifiable {
  case current
  case arm64
  case amd64
  case all

  var id: Self { self }

  var title: String {
    switch self {
    case .current: "Current Mac"
    case .arm64: "Linux arm64/v8"
    case .amd64: "Linux amd64"
    case .all: "All platforms"
    }
  }
}

struct OCIPlatformValue: Equatable, Hashable, Sendable {
  let os: String
  let architecture: String
  let variant: String?

  var description: String {
    if let variant { return "\(os)/\(architecture)/\(variant)" }
    return "\(os)/\(architecture)"
  }
}

enum ImagePlatformScope: Equatable, Hashable, Sendable {
  case all
  case specific(OCIPlatformValue)

  var description: String {
    switch self {
    case .all: "All platforms"
    case .specific(let platform): platform.description
    }
  }
}

struct ImagePullPlan: Equatable, Sendable {
  let normalizedReference: String
  let registryHost: String
  let existingDigest: String?
  let platform: ImagePlatformScope
  let requestedTransport: RegistryTransport
  let resolvedTransport: RegistryTransport
  let unpackAfterPull: Bool
  let maxConcurrentDownloads: Int
  let generatedAt: Date

  var requiresInsecureConfirmation: Bool { resolvedTransport.isInsecure }
  var replacesExistingReference: Bool { existingDigest != nil }
  var requiresAllPlatformConfirmation: Bool { platform == .all }
}

struct ImagePullAuthorization: Equatable, Sendable {
  let allowsInsecureTransport: Bool
  let allowsExistingReferenceReplacement: Bool
  let allowsAllPlatforms: Bool

  static let none = ImagePullAuthorization(
    allowsInsecureTransport: false,
    allowsExistingReferenceReplacement: false,
    allowsAllPlatforms: false
  )
}

struct ImagePullResult: Equatable, Sendable {
  let reference: String
  let digest: String
  let replacedDigest: String?
  let unpackOutcome: ImageUnpackOutcome?

  var unpacked: Bool {
    unpackOutcome?.isComplete == true
  }
}

enum ImagePlatformUnpackState: Equatable, Sendable {
  case alreadyPresent
  case created
  case failed(String)
}

struct ImagePlatformUnpackOutcome: Equatable, Sendable, Identifiable {
  let platform: OCIPlatformValue
  let state: ImagePlatformUnpackState

  var id: OCIPlatformValue { platform }
}

struct ImageUnpackOutcome: Equatable, Sendable {
  let platforms: [ImagePlatformUnpackOutcome]

  var isComplete: Bool {
    !platforms.isEmpty
      && platforms.allSatisfy { outcome in
        if case .failed = outcome.state { return false }
        return true
      }
  }
}

struct ImagePullPartialCompletionError: LocalizedError, Equatable, Sendable {
  enum Stage: String, Equatable, Sendable {
    case validatingPlatform = "platform validation"
    case unpacking
  }

  let result: ImagePullResult
  let stage: Stage
  let failureMessage: String
  let wasCancelled: Bool

  var errorDescription: String? {
    let action = wasCancelled ? "was cancelled" : "failed"
    return
      "The image download completed and “\(result.reference)” now points to \(result.digest), but \(stage.rawValue) \(action): \(failureMessage) The downloaded image remains in Apple’s image store."
  }
}

struct ImagePushPlan: Equatable, Sendable {
  let reference: String
  let displayReference: String
  let sourceDigest: String
  let registryHost: String
  let platform: ImagePlatformScope
  let requestedTransport: RegistryTransport
  let resolvedTransport: RegistryTransport
  let generatedAt: Date

  var requiresInsecureConfirmation: Bool { resolvedTransport.isInsecure }
}

struct ImagePushAuthorization: Equatable, Sendable {
  let allowsInsecureTransport: Bool
  let confirmsRemoteTagReplacement: Bool

  static let none = ImagePushAuthorization(
    allowsInsecureTransport: false,
    confirmsRemoteTagReplacement: false
  )
}

enum ImageTransferExecutionSafety {
  static func validatePull(
    plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    resolvedRegistryHost: String,
    resolvedTransport: RegistryTransport,
    currentDigest: String?,
    isInfrastructureImage: Bool
  ) throws {
    guard !isInfrastructureImage else {
      throw ImageManagementError.infrastructureImage(plan.normalizedReference)
    }
    guard
      resolvedRegistryHost == plan.registryHost,
      resolvedTransport == plan.resolvedTransport
    else {
      throw ImageManagementError.stalePlan("registry transport")
    }
    if plan.requiresInsecureConfirmation, !authorization.allowsInsecureTransport {
      throw ImageManagementError.insecureTransportRequiresConfirmation(plan.registryHost)
    }
    if plan.replacesExistingReference, !authorization.allowsExistingReferenceReplacement {
      throw ImageManagementError.pullWouldReplace(plan.normalizedReference)
    }
    if plan.requiresAllPlatformConfirmation, !authorization.allowsAllPlatforms {
      throw ImageManagementError.allPlatformPullRequiresConfirmation
    }
    guard currentDigest == plan.existingDigest else {
      throw ImageManagementError.stalePlan("pull operation")
    }
  }

  static func validatePush(
    plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    resolvedRegistryHost: String,
    resolvedTransport: RegistryTransport,
    currentDigest: String,
    isInfrastructureImage: Bool
  ) throws {
    guard !isInfrastructureImage else {
      throw ImageManagementError.infrastructureImage(plan.reference)
    }
    guard authorization.confirmsRemoteTagReplacement else {
      throw ImageManagementError.remoteTagReplacementRequiresConfirmation(plan.reference)
    }
    if plan.requiresInsecureConfirmation, !authorization.allowsInsecureTransport {
      throw ImageManagementError.insecureTransportRequiresConfirmation(plan.registryHost)
    }
    guard
      resolvedRegistryHost == plan.registryHost,
      resolvedTransport == plan.resolvedTransport
    else {
      throw ImageManagementError.stalePlan("registry transport")
    }
    guard currentDigest == plan.sourceDigest else {
      throw ImageManagementError.stalePlan("push operation")
    }
  }

  static func validatePlatform(
    _ requested: OCIPlatformValue,
    available: [OCIPlatformValue],
    reference: String
  ) throws {
    guard available.contains(requested) else {
      throw ImageManagementError.platformUnavailable(
        platform: requested.description,
        reference: reference
      )
    }
  }
}
