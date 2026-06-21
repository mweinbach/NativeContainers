import Foundation

struct ComposeProjectActionStepID: Equatable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  static func composeUp() -> Self {
    Self(rawValue: "compose-up-0001")
  }

  static func container(_ ordinal: Int) -> Self {
    Self(rawValue: "container-\(String(format: "%04d", ordinal))")
  }

  static func network(_ ordinal: Int) -> Self {
    Self(rawValue: "network-\(String(format: "%04d", ordinal))")
  }

  static func volume(_ ordinal: Int) -> Self {
    Self(rawValue: "volume-\(String(format: "%04d", ordinal))")
  }
}

enum ComposeProjectContainerOperation: String, Equatable, Sendable {
  case create
  case converge
  case start
  case stop
  case removeDeclared
  case removeOrphan
}

struct ComposeProjectContainerAction: Equatable, Identifiable, Sendable {
  let stepID: ComposeProjectActionStepID
  let operation: ComposeProjectContainerOperation
  let serviceName: String
  let replicaNumber: Int?
  let expectedIdentity: ComposeProjectContainerIdentity?

  var id: String {
    [
      operation.rawValue,
      serviceName,
      replicaNumber.map(String.init) ?? "-",
      expectedIdentity?.id ?? "-",
    ].joined(separator: ":")
  }

  var existingContainerID: String? { expectedIdentity?.id }
  var createsContainer: Bool { operation == .create }
  var removesContainer: Bool {
    operation == .removeDeclared || operation == .removeOrphan
  }
}

enum ComposeProjectResourceOperation: String, Equatable, Sendable {
  case createManaged
  case reuseManaged
  case useExternal
  case removeManaged
}

struct ComposeProjectVolumeAction: Equatable, Identifiable, Sendable {
  let stepID: ComposeProjectActionStepID
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectVolumeIdentity?

  var id: String { "\(operation.rawValue):\(logicalName):\(runtimeName)" }
}

struct ComposeProjectNetworkAction: Equatable, Identifiable, Sendable {
  let stepID: ComposeProjectActionStepID
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectNetworkIdentity?

  var id: String { "\(operation.rawValue):\(logicalName):\(runtimeName)" }
}

enum ComposeProjectPreservedResource: Equatable, Identifiable, Sendable {
  case container(ComposeProjectContainerIdentity)
  case volume(ComposeProjectVolumeIdentity)
  case network(ComposeProjectNetworkIdentity)
  case external(kind: ComposeDesiredResourceKind, name: String)
  case absent(kind: ComposeDesiredResourceKind, name: String)

  var id: String {
    switch self {
    case .container(let identity):
      "container:\(identity.id)"
    case .volume(let identity):
      "volume:\(identity.id)"
    case .network(let identity):
      "network:\(identity.id)"
    case .external(let kind, let name):
      "external:\(kind.rawValue):\(name)"
    case .absent(let kind, let name):
      "absent:\(kind.rawValue):\(name)"
    }
  }

  var displayName: String {
    switch self {
    case .container(let identity):
      identity.id
    case .volume(let identity):
      identity.configuration.name
    case .network(let identity):
      identity.configuration.name
    case .external(_, let name):
      name
    case .absent(_, let name):
      name
    }
  }
}

extension ComposeProjectPlan {
  var affectedContainerIDs: [String] {
    containerActions.compactMap(\.existingContainerID).sorted(by: composeStringOrder)
  }

  var affectedVolumeNames: [String] {
    volumeActions.map(\.runtimeName).sorted(by: composeStringOrder)
  }

  var affectedNetworkNames: [String] {
    networkActions.map(\.runtimeName).sorted(by: composeStringOrder)
  }

  var orphanContainerIDs: [String] {
    orphanContainers.map(\.id).sorted(by: composeStringOrder)
  }

  var preservedResourceNames: [String] {
    preservedResources.map(\.displayName).sorted(by: composeStringOrder)
  }

  var executionStepTokens: [String] {
    if options.action == .up {
      var tokens =
        networkActions.filter { $0.operation == .createManaged }.map(\.stepID.rawValue)
        + volumeActions.filter { $0.operation == .createManaged }.map(\.stepID.rawValue)
        + containerActions.filter { $0.operation == .converge }.map(\.stepID.rawValue)
      if containerActions.contains(where: { $0.operation == .create }) {
        tokens.append(ComposeProjectActionStepID.composeUp().rawValue)
      }
      return tokens
    }
    return containerActions.map(\.stepID.rawValue)
      + networkActions.map(\.stepID.rawValue)
      + volumeActions.map(\.stepID.rawValue)
  }
}
