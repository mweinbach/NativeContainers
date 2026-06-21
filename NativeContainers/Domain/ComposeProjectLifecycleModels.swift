import Foundation

enum ComposeProjectLifecycleAction: String, CaseIterable, Equatable, Identifiable, Sendable {
  case up
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

  init(
    action: ComposeProjectLifecycleAction,
    projectName: String,
    profiles: [String] = [],
    pullPolicy: ComposeProjectPullPolicy = .never,
    removeOrphans: Bool = false,
    removeVolumes: Bool = false
  ) {
    self.action = action
    self.projectName = projectName
    self.profiles = Array(Set(profiles)).sorted(by: composeStringOrder)
    self.pullPolicy = pullPolicy
    self.removeOrphans = removeOrphans
    self.removeVolumes = removeVolumes
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

enum ComposeDesiredResourceKind: String, Equatable, Sendable {
  case volume
  case network
}

struct ComposeDesiredService: Equatable, Identifiable, Sendable {
  let name: String
  let imageReference: String
  let replicaCount: Int
  let profiles: [String]
  let volumeNames: [String]
  let networkNames: [String]
  let publishedPortCount: Int

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
  let activeServices: [ComposeDesiredService]
  let volumes: [ComposeDesiredResource]
  let networks: [ComposeDesiredResource]

  var activeServiceNames: [String] { activeServices.map(\.name) }

  var activeResources: [ComposeDesiredResource] {
    (volumes + networks).filter(\.isActive)
  }
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
  let createdAt: Date
  let labels: [String: String]

  init(_ container: ContainerRecord) {
    id = container.id
    imageReference = container.imageReference
    createdAt = container.createdAt
    labels = container.labels
  }

  func matches(_ container: ContainerRecord) -> Bool {
    self == Self(container)
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
  let fullConfiguration: Data
  let fullConfigurationSHA256: String
  let activeConfigurationSHA256: String
  let observedIdentity: ComposeProjectInventoryIdentity
  let issues: [ComposeProjectReviewIssue]
  let affectedContainerIDs: [String]
  let affectedVolumeNames: [String]
  let affectedNetworkNames: [String]
  let orphanContainerIDs: [String]
  let preservedResourceNames: [String]

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
  case reviewBlocked(Int)
  case stalePlan
  case observedStateChanged
  case runtimeNotReady(String)
  case commandFailed(action: ComposeProjectLifecycleAction, exitCode: Int32, output: String)
  case postconditionNotMet(String)
  case workspaceUnsafe(String)
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
