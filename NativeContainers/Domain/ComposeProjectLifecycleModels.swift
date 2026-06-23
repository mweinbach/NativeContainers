import Foundation

enum ComposeProjectLifecycleAction: String, CaseIterable, Equatable, Identifiable, Sendable {
  case up
  case start
  case stop
  case down

  var id: String { rawValue }
}

enum ComposeProjectPullPolicy: String, CaseIterable, Equatable, Identifiable, Sendable {
  case never
  case missing

  var id: String { rawValue }
}

struct ComposeProjectReviewOptions: Equatable, Sendable {
  let action: ComposeProjectLifecycleAction
  let projectName: String
  let profiles: [String]
  let pullPolicy: ComposeProjectPullPolicy
  let removeOrphans: Bool
  let removeVolumes: Bool
  let killStuckContainers: Bool

  init(
    action: ComposeProjectLifecycleAction,
    projectName: String,
    profiles: [String] = [],
    pullPolicy: ComposeProjectPullPolicy = .never,
    removeOrphans: Bool = false,
    removeVolumes: Bool = false,
    killStuckContainers: Bool = true
  ) {
    self.action = action
    self.projectName = projectName
    self.profiles = Array(Set(profiles)).sorted(by: composeStringOrder)
    self.pullPolicy = pullPolicy
    self.removeOrphans = removeOrphans
    self.removeVolumes = removeVolumes
    self.killStuckContainers = killStuckContainers
  }
}

enum ComposeProjectInputKind: String, Equatable, Sendable {
  case config
  case secret
}

enum ComposeProjectInputSourceKind: String, Equatable, Sendable {
  case file
  case environment
  case literal
}

struct ComposeProjectInputRequirement: Equatable, Identifiable, Sendable {
  let kind: ComposeProjectInputKind
  let name: String
  let sourceKind: ComposeProjectInputSourceKind
  let environmentVariable: String?
  let displayPath: String?
  let byteCount: Int64
  let serviceNames: [String]

  var id: String { "\(kind.rawValue):\(name)" }
}

struct ComposeProjectInputRequirements: Equatable, Identifiable, Sendable {
  let id: UUID
  let source: ComposeProjectSourceSummary
  let options: ComposeProjectReviewOptions
  let inputs: [ComposeProjectInputRequirement]
  let issues: [ComposeProjectReviewIssue]

  var requiredEnvironmentVariables: [String] {
    Array(Set(inputs.compactMap(\.environmentVariable))).sorted(by: composeStringOrder)
  }
}

struct ComposeProjectReviewInputs: Equatable, Sendable {
  let requirementsID: UUID
  let environmentValues: [String: String]

  init(
    requirementsID: UUID,
    environmentValues: [String: String] = [:]
  ) {
    self.requirementsID = requirementsID
    self.environmentValues = environmentValues
  }
}

struct ComposeProjectSourceFileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
  let permissions: UInt16
  let byteCount: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64
  let sha256: String
}

struct ComposeProjectSourceSummary: Equatable, Sendable {
  let directoryName: String
  let fileName: String
  let fileIdentity: ComposeProjectSourceFileIdentity
}

struct ComposeProjectSourceLease: Equatable, Identifiable, Sendable {
  let id: UUID
  let directoryURL: URL
  let composeFileURL: URL
  let summary: ComposeProjectSourceSummary
}

struct ComposeRenderedConfiguration: Equatable, Sendable {
  let fullConfiguration: Data
  let activeConfiguration: Data
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let composeReleaseVersion: String
  let composeBinarySHA256: String
  let composeSourceRevision: String
  let environmentSHA256: String
  let serviceConfigurationHashes: [String: String]
}

enum ComposeDesiredResourceKind: String, Equatable, Sendable {
  case volume
  case network
}

struct ComposeDesiredService: Equatable, Identifiable, Sendable {
  let name: String
  let imageReference: String
  let replicaCount: Int
  let profiles: [String]
  let dependencyNames: [String]
  let configurationHash: String?
  let inputSeal: String?
  let volumeNames: [String]
  let networkNames: [String]
  let publishedPortCount: Int

  init(
    name: String,
    imageReference: String,
    replicaCount: Int,
    profiles: [String],
    dependencyNames: [String],
    configurationHash: String?,
    inputSeal: String? = nil,
    volumeNames: [String],
    networkNames: [String],
    publishedPortCount: Int
  ) {
    self.name = name
    self.imageReference = imageReference
    self.replicaCount = replicaCount
    self.profiles = profiles
    self.dependencyNames = dependencyNames
    self.configurationHash = configurationHash
    self.inputSeal = inputSeal
    self.volumeNames = volumeNames
    self.networkNames = networkNames
    self.publishedPortCount = publishedPortCount
  }

  var id: String { name }
}

struct ComposeDesiredResource: Equatable, Identifiable, Sendable {
  let kind: ComposeDesiredResourceKind
  let logicalName: String
  let runtimeName: String
  let isExternal: Bool
  let isActive: Bool

  var id: String { "\(kind.rawValue):\(logicalName)" }
}

struct ComposeDesiredState: Equatable, Sendable {
  let projectName: String
  let declaredServiceNames: [String]
  let serviceDependencies: [String: [String]]
  let activeServices: [ComposeDesiredService]
  let volumes: [ComposeDesiredResource]
  let networks: [ComposeDesiredResource]

  var activeServiceNames: [String] { activeServices.map(\.name) }

  var activeResources: [ComposeDesiredResource] {
    (volumes + networks).filter(\.isActive)
  }
}

struct ComposeDesiredStateReview: Equatable, Sendable {
  let desiredState: ComposeDesiredState
  let issues: [ComposeProjectReviewIssue]
}

enum ComposeProjectReviewIssueSeverity: Int, Equatable, Sendable {
  case warning
  case blocker
}

enum ComposeProjectReviewIssueCode: String, Equatable, Sendable {
  case unsupportedFeature
  case missingImage
  case invalidModel
  case externalResourceMissing
  case resourceIdentityConflict
  case crossProjectConsumer
  case observedProjectDrift
  case executionPolicy
  case inputPolicy
}

struct ComposeProjectReviewIssue: Equatable, Identifiable, Sendable {
  let severity: ComposeProjectReviewIssueSeverity
  let code: ComposeProjectReviewIssueCode
  let subject: String
  let message: String

  var id: String {
    "\(severity.rawValue):\(code.rawValue):\(subject):\(message)"
  }
}

struct ComposeProjectContainerIdentity: Equatable, Sendable {
  let id: String
  let imageReference: String
  let imageDigest: String?
  let platform: String
  let createdAt: Date
  let cpuCount: Int
  let memoryBytes: UInt64
  let ports: [ContainerPort]
  let labels: [String: String]

  init(_ container: ContainerRecord, imageDigest: String? = nil) {
    id = container.id
    imageReference = container.imageReference
    self.imageDigest = imageDigest ?? container.imageDigest
    platform = container.platform
    createdAt = container.createdAt
    cpuCount = container.cpuCount
    memoryBytes = container.memoryBytes
    ports = container.ports
    labels = container.labels
  }

  func matches(_ container: ContainerRecord) -> Bool {
    id == container.id
      && imageReference == container.imageReference
      && (imageDigest == nil || imageDigest == container.imageDigest)
      && platform == container.platform
      && createdAt == container.createdAt
      && cpuCount == container.cpuCount
      && memoryBytes == container.memoryBytes
      && ports == container.ports
      && labels == container.labels
  }
}

struct ComposeProjectVolumeIdentity: Equatable, Sendable {
  let id: String
  let configuration: VolumeConfigurationIdentity

  init(_ volume: VolumeRecord) {
    id = volume.id
    configuration = volume.configurationIdentity
  }

  func matches(_ volume: VolumeRecord) -> Bool {
    id == volume.id && configuration == volume.configurationIdentity
  }
}

struct ComposeProjectNetworkIdentity: Equatable, Sendable {
  let id: String
  let configuration: NetworkConfigurationIdentity

  init(_ network: NetworkRecord) {
    id = network.id
    configuration = network.configurationIdentity
  }

  func matches(_ network: NetworkRecord) -> Bool {
    id == network.id && configuration == network.configurationIdentity
  }
}

struct ComposeProjectInventoryIdentity: Equatable, Sendable {
  let containers: [ComposeProjectContainerIdentity]
  let volumes: [ComposeProjectVolumeIdentity]
  let networks: [ComposeProjectNetworkIdentity]

  static let empty = ComposeProjectInventoryIdentity(
    containers: [],
    volumes: [],
    networks: []
  )
}

struct ComposeProjectPlan: Equatable, Identifiable, Sendable {
  let id: UUID
  let generatedAt: Date
  let options: ComposeProjectReviewOptions
  let source: ComposeProjectSourceSummary
  let desiredState: ComposeDesiredState
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let composeReleaseVersion: String
  let composeBinarySHA256: String
  let composeSourceRevision: String
  let environmentSHA256: String
  let serviceConfigurationHashes: [String: String]
  let executionServiceConfigurationHashes: [String: String]
  let observedIdentity: ComposeProjectInventoryIdentity
  let issues: [ComposeProjectReviewIssue]
  let containerActions: [ComposeProjectContainerAction]
  let volumeActions: [ComposeProjectVolumeAction]
  let networkActions: [ComposeProjectNetworkAction]
  let orphanContainers: [ComposeProjectContainerIdentity]
  let preservedResources: [ComposeProjectPreservedResource]

  init(
    id: UUID,
    generatedAt: Date,
    options: ComposeProjectReviewOptions,
    source: ComposeProjectSourceSummary,
    desiredState: ComposeDesiredState,
    fullConfigurationSHA256: String,
    activeConfigurationSHA256: String,
    composeReleaseVersion: String,
    composeBinarySHA256: String,
    composeSourceRevision: String,
    environmentSHA256: String,
    serviceConfigurationHashes: [String: String],
    executionServiceConfigurationHashes: [String: String]? = nil,
    observedIdentity: ComposeProjectInventoryIdentity,
    issues: [ComposeProjectReviewIssue],
    containerActions: [ComposeProjectContainerAction],
    volumeActions: [ComposeProjectVolumeAction],
    networkActions: [ComposeProjectNetworkAction],
    orphanContainers: [ComposeProjectContainerIdentity],
    preservedResources: [ComposeProjectPreservedResource]
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.options = options
    self.source = source
    self.desiredState = desiredState
    self.fullConfigurationSHA256 = fullConfigurationSHA256
    self.activeConfigurationSHA256 = activeConfigurationSHA256
    self.composeReleaseVersion = composeReleaseVersion
    self.composeBinarySHA256 = composeBinarySHA256
    self.composeSourceRevision = composeSourceRevision
    self.environmentSHA256 = environmentSHA256
    self.serviceConfigurationHashes = serviceConfigurationHashes
    self.executionServiceConfigurationHashes =
      executionServiceConfigurationHashes ?? serviceConfigurationHashes
    self.observedIdentity = observedIdentity
    self.issues = issues
    self.containerActions = containerActions
    self.volumeActions = volumeActions
    self.networkActions = networkActions
    self.orphanContainers = orphanContainers
    self.preservedResources = preservedResources
  }

  var blockers: [ComposeProjectReviewIssue] {
    issues.filter { $0.severity == .blocker }
  }

  var warnings: [ComposeProjectReviewIssue] {
    issues.filter { $0.severity == .warning }
  }

  var canExecute: Bool { blockers.isEmpty }
}

struct ComposeProjectExecutionResult: Equatable, Sendable {
  let action: ComposeProjectLifecycleAction
  let projectName: String
  let observedState: ComposeObservedState?
  let remainingContainerCount: Int
  let remainingVolumeCount: Int
  let remainingNetworkCount: Int
}

enum ComposeProjectLifecycleError: LocalizedError, Equatable, Sendable {
  case invalidProjectName(String)
  case invalidProfileName(String)
  case sourceDirectoryUnsafe(String)
  case composeFileMissing
  case composeFileAmbiguous([String])
  case composeFileUnsafe(String)
  case composeFileTooLarge(Int64)
  case sourceChanged
  case configCommandFailed(exitCode: Int32, output: String)
  case configOutputTruncated
  case configOutputInvalid(String)
  case configChangedDuringReview
  case inputRequirementsUnavailable
  case inputRequirementsMismatch
  case missingInputValue(String)
  case unexpectedInputValue(String)
  case inputSourceUnsafe(String)
  case inputSourceTooLarge(String)
  case reviewBlocked(Int)
  case stalePlan
  case observedStateChanged
  case runtimeNotReady(String)
  case commandFailed(action: ComposeProjectLifecycleAction, exitCode: Int32, output: String)
  case postconditionNotMet(String)
  case workspaceUnsafe(String)
  case journalRecoveryRequired(UUID)
  case partialCompletion(String)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidProjectName(let name):
      "The Compose project name is invalid: \(name)."
    case .invalidProfileName(let name):
      "The Compose profile name is invalid: \(name)."
    case .sourceDirectoryUnsafe(let reason):
      "The Compose project directory is unsafe: \(reason)"
    case .composeFileMissing:
      "No conventional Compose file was found in the selected directory."
    case .composeFileAmbiguous(let files):
      "The selected directory contains multiple Compose files: \(files.joined(separator: ", "))."
    case .composeFileUnsafe(let reason):
      "The Compose file is unsafe: \(reason)"
    case .composeFileTooLarge(let byteCount):
      "The Compose file exceeds the 1 MiB review limit (\(byteCount) bytes)."
    case .sourceChanged:
      "The Compose project source changed during review. Review it again."
    case .configCommandFailed(let exitCode, let output):
      "Docker Compose config exited with status \(exitCode).\(output.isEmpty ? "" : " " + output)"
    case .configOutputTruncated:
      "Docker Compose config exceeded the bounded review output limit."
    case .configOutputInvalid(let reason):
      "Docker Compose returned an invalid canonical model: \(reason)"
    case .configChangedDuringReview:
      "Docker Compose produced different canonical models during one review."
    case .inputRequirementsUnavailable:
      "The Compose input requirements are no longer available. Discover them again."
    case .inputRequirementsMismatch:
      "The Compose input requirements no longer match this project. Discover them again."
    case .missingInputValue(let name):
      "A reviewed value is required for Compose environment input \(name)."
    case .unexpectedInputValue(let name):
      "Compose environment input \(name) was not requested by the reviewed project."
    case .inputSourceUnsafe(let name):
      "Compose input \(name) is not a safe, owner-controlled regular file inside the project."
    case .inputSourceTooLarge(let name):
      "Compose input \(name) exceeds its bounded review limit."
    case .reviewBlocked(let count):
      "The Compose review has \(count) blocking compatibility issue\(count == 1 ? "" : "s")."
    case .stalePlan:
      "The Compose review is stale. Review the project again."
    case .observedStateChanged:
      "The observed Compose resources changed after review. Review the project again."
    case .runtimeNotReady(let reason):
      "Docker compatibility is not ready: \(reason)"
    case .commandFailed(let action, let exitCode, let output):
      "Compose \(action.rawValue) exited with status \(exitCode).\(output.isEmpty ? "" : " " + output)"
    case .postconditionNotMet(let reason):
      "Compose finished, but Apple inventory did not confirm the reviewed result. \(reason)"
    case .workspaceUnsafe(let reason):
      "The private Compose execution workspace is unsafe: \(reason)"
    case .journalRecoveryRequired(let operationID):
      "Compose operation \(operationID.uuidString) requires reconciliation before another project mutation."
    case .partialCompletion(let reason):
      "The Compose operation may be partially complete. \(reason)"
    case .unavailable(let reason):
      "Compose project lifecycle is unavailable: \(reason)"
    }
  }
}

func isValidComposeProjectName(_ value: String) -> Bool {
  guard let first = value.utf8.first, isComposeLowercaseLetter(first) || isComposeDigit(first)
  else {
    return false
  }
  return value.utf8.allSatisfy {
    isComposeLowercaseLetter($0) || isComposeDigit($0) || $0 == 45 || $0 == 95
  }
}

func isValidComposeProfileName(_ value: String) -> Bool {
  guard value.utf8.count >= 2, let first = value.utf8.first else { return false }
  guard isComposeASCIIAlphanumeric(first) else { return false }
  return value.utf8.allSatisfy {
    isComposeASCIIAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
  }
}

private func isComposeLowercaseLetter(_ value: UInt8) -> Bool {
  value >= 97 && value <= 122
}

private func isComposeDigit(_ value: UInt8) -> Bool {
  value >= 48 && value <= 57
}

private func isComposeASCIIAlphanumeric(_ value: UInt8) -> Bool {
  isComposeLowercaseLetter(value) || (value >= 65 && value <= 90) || isComposeDigit(value)
}
