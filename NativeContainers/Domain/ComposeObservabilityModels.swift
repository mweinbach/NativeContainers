import Foundation

enum ComposeLabelKey {
  static let prefix = "com.docker.compose."
  static let project = "com.docker.compose.project"
  static let service = "com.docker.compose.service"
  static let volume = "com.docker.compose.volume"
  static let network = "com.docker.compose.network"
  static let containerNumber = "com.docker.compose.container-number"
  static let oneOff = "com.docker.compose.oneoff"
  static let configHash = "com.docker.compose.config-hash"
  static let version = "com.docker.compose.version"
  static let workingDirectory = "com.docker.compose.project.working_dir"
  static let configFiles = "com.docker.compose.project.config_files"
  static let nativePrefix = "com.nativecontainers.compose."
  static let inputSeal = "com.nativecontainers.compose.input-seal"
  static let reviewedConfigHash = "com.nativecontainers.compose.reviewed-config-hash"
}

struct ComposeContainerInstance: Equatable, Sendable, Identifiable {
  let container: ContainerRecord
  let replicaNumberLabel: ObservedOptionalLabel<Int>
  let oneOffLabel: ObservedOptionalLabel<Bool>

  var id: String { container.id }
  var replicaNumber: Int? { replicaNumberLabel.value }
  var isOneOff: Bool { oneOffLabel.value ?? false }
}

enum ObservedOptionalLabel<Value: Equatable & Sendable>: Equatable, Sendable {
  case absent
  case valid(Value)
  case invalid(rawValue: String)

  var value: Value? {
    guard case .valid(let value) = self else { return nil }
    return value
  }
}

struct ComposeServiceRecord: Equatable, Sendable, Identifiable {
  let name: String
  let instances: [ComposeContainerInstance]

  var id: String { name }
  var containerCount: Int { instances.count }
  var runningContainerCount: Int {
    instances.count(where: { $0.container.state.isRunning })
  }
  var imageReferences: [String] {
    Array(Set(instances.map(\.container.imageReference))).sorted(by: composeStringOrder)
  }
}

struct ComposeVolumeObservation: Equatable, Sendable, Identifiable {
  let logicalName: String
  let volume: VolumeRecord

  var id: String { volume.id }
}

struct ComposeNetworkObservation: Equatable, Sendable, Identifiable {
  let logicalName: String
  let network: NetworkRecord

  var id: String { network.id }
}

struct ComposeProjectMetadata: Equatable, Sendable {
  let workingDirectories: [String]
  let configFileValues: [String]
  let composeVersions: [String]

  static let empty = ComposeProjectMetadata(
    workingDirectories: [],
    configFileValues: [],
    composeVersions: []
  )

  var hasConflictingSourceMetadata: Bool {
    workingDirectories.count > 1 || configFileValues.count > 1
  }
}

enum ComposeObservedState: String, Equatable, Sendable {
  case noContainers
  case allRunning
  case partiallyRunning
  case noneRunning
  case transitioning
  case unknown
}

enum ComposeTopologyResourceKind: Int, Equatable, Sendable {
  case container
  case volume
  case network
}

enum ComposeTopologyNoticeKind: String, Equatable, Sendable {
  case invalidProjectName
  case invalidLogicalName
  case invalidOptionalLabel
  case missingResourceLabel
  case anonymousVolume
  case builtinNetwork
  case consumerProjectMismatch
}

struct ComposeTopologyNotice: Equatable, Sendable, Identifiable {
  let kind: ComposeTopologyNoticeKind
  let resourceKind: ComposeTopologyResourceKind
  let resourceID: String
  let projectLabel: String
  let expectedLabelKey: String?
  let observedValue: String?
  let relatedProjectNames: [String]

  init(
    kind: ComposeTopologyNoticeKind,
    resourceKind: ComposeTopologyResourceKind,
    resourceID: String,
    projectLabel: String,
    expectedLabelKey: String?,
    observedValue: String? = nil,
    relatedProjectNames: [String] = []
  ) {
    self.kind = kind
    self.resourceKind = resourceKind
    self.resourceID = resourceID
    self.projectLabel = projectLabel
    self.expectedLabelKey = expectedLabelKey
    self.observedValue = observedValue
    self.relatedProjectNames = relatedProjectNames
  }

  var id: String {
    "\(resourceKind.rawValue):\(resourceID):\(kind.rawValue):\(expectedLabelKey ?? ""):\(observedValue ?? ""):\(relatedProjectNames.joined(separator: ","))"
  }
}

struct ComposeContainerAssociation: Equatable, Sendable {
  let projectName: String
  let serviceName: String
  let replicaNumber: ObservedOptionalLabel<Int>
  let oneOff: ObservedOptionalLabel<Bool>
}

struct ComposeResourceAssociation: Equatable, Sendable {
  let projectName: String
  let logicalName: String
}

struct ComposeProjectRecord: Equatable, Sendable, Identifiable {
  let name: String
  let services: [ComposeServiceRecord]
  let unclassifiedContainers: [ComposeContainerInstance]
  let volumes: [ComposeVolumeObservation]
  let networks: [ComposeNetworkObservation]
  let metadata: ComposeProjectMetadata

  var id: String { name }

  var containers: [ComposeContainerInstance] {
    services.flatMap(\.instances)
  }

  var containerCount: Int { containers.count }
  var runningContainerCount: Int {
    containers.count(where: { $0.container.state.isRunning })
  }
  var oneOffContainerCount: Int {
    containers.count(where: \.isOneOff)
  }
  var serviceCount: Int { services.count }

  var observedState: ComposeObservedState {
    let states = containers.map(\.container.state)
    guard !states.isEmpty else { return .noContainers }
    if states.contains(.stopping) { return .transitioning }

    let runningCount = states.count(where: \.isRunning)
    if runningCount == states.count { return .allRunning }
    if runningCount > 0 { return .partiallyRunning }
    if states.allSatisfy({ $0 == .stopped }) { return .noneRunning }
    return .unknown
  }
}

struct ComposeTopologySnapshot: Equatable, Sendable {
  let projects: [ComposeProjectRecord]
  let notices: [ComposeTopologyNotice]
  let containerAssociationsByID: [String: ComposeContainerAssociation]
  let volumeAssociationsByID: [String: ComposeResourceAssociation]
  let networkAssociationsByID: [String: ComposeResourceAssociation]

  static let empty = ComposeTopologySnapshot(
    projects: [],
    notices: [],
    containerAssociationsByID: [:],
    volumeAssociationsByID: [:],
    networkAssociationsByID: [:]
  )

  var projectNameByContainerID: [String: String] {
    containerAssociationsByID.mapValues(\.projectName)
  }

  var serviceNameByContainerID: [String: String] {
    containerAssociationsByID.mapValues(\.serviceName)
  }

  var projectNameByVolumeID: [String: String] {
    volumeAssociationsByID.mapValues(\.projectName)
  }

  var projectNameByNetworkID: [String: String] {
    networkAssociationsByID.mapValues(\.projectName)
  }

  func project(named name: String) -> ComposeProjectRecord? {
    projects.first(where: { $0.name == name })
  }

  func project(containingContainerID id: String) -> ComposeProjectRecord? {
    containerAssociationsByID[id].map(\.projectName).flatMap(project(named:))
  }

  func project(containingVolumeID id: String) -> ComposeProjectRecord? {
    volumeAssociationsByID[id].map(\.projectName).flatMap(project(named:))
  }

  func project(containingNetworkID id: String) -> ComposeProjectRecord? {
    networkAssociationsByID[id].map(\.projectName).flatMap(project(named:))
  }
}

func composeStringOrder(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
