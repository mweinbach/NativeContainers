import Foundation

enum ComposeLabelKey {
  static let project = "com.docker.compose.project"
  static let service = "com.docker.compose.service"
  static let volume = "com.docker.compose.volume"
  static let network = "com.docker.compose.network"
  static let containerNumber = "com.docker.compose.container-number"
  static let oneOff = "com.docker.compose.oneoff"
  static let version = "com.docker.compose.version"
  static let workingDirectory = "com.docker.compose.project.working_dir"
  static let configFiles = "com.docker.compose.project.config_files"
}

struct ComposeContainerInstance: Equatable, Sendable, Identifiable {
  let container: ContainerRecord
  let replicaNumber: Int?
  let isOneOff: Bool

  var id: String { container.id }
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
  case missingResourceLabel
  case builtinNetwork
}

struct ComposeTopologyNotice: Equatable, Sendable, Identifiable {
  let kind: ComposeTopologyNoticeKind
  let resourceKind: ComposeTopologyResourceKind
  let resourceID: String
  let projectLabel: String
  let expectedLabelKey: String?

  var id: String {
    "\(resourceKind.rawValue):\(resourceID):\(kind.rawValue):\(expectedLabelKey ?? "")"
  }
}

struct ComposeProjectRecord: Equatable, Sendable, Identifiable {
  let name: String
  let services: [ComposeServiceRecord]
  let unclassifiedContainers: [ComposeContainerInstance]
  let volumes: [VolumeRecord]
  let networks: [NetworkRecord]
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
  let projectNameByContainerID: [String: String]
  let serviceNameByContainerID: [String: String]
  let projectNameByVolumeID: [String: String]
  let projectNameByNetworkID: [String: String]

  static let empty = ComposeTopologySnapshot(
    projects: [],
    notices: [],
    projectNameByContainerID: [:],
    serviceNameByContainerID: [:],
    projectNameByVolumeID: [:],
    projectNameByNetworkID: [:]
  )

  func project(named name: String) -> ComposeProjectRecord? {
    projects.first(where: { $0.name == name })
  }

  func project(containingContainerID id: String) -> ComposeProjectRecord? {
    projectNameByContainerID[id].flatMap(project(named:))
  }

  func project(containingVolumeID id: String) -> ComposeProjectRecord? {
    projectNameByVolumeID[id].flatMap(project(named:))
  }

  func project(containingNetworkID id: String) -> ComposeProjectRecord? {
    projectNameByNetworkID[id].flatMap(project(named:))
  }
}

func composeStringOrder(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
