import Foundation

enum ContainerBuilderRuntimeState: String, Codable, Equatable, Sendable {
  case absent
  case running
  case stopped
  case stopping
  case unknown
}

struct ContainerBuilderMountIdentity: Codable, Equatable, Sendable {
  let type: String
  let source: String
  let destination: String
  let options: [String]

  init(type: String, source: String, destination: String, options: [String]) {
    self.type = type
    self.source = Self.removingTrailingSeparators(from: source)
    self.destination = destination
    self.options = options
  }

  private static func removingTrailingSeparators(from path: String) -> String {
    var result = path
    while result.count > 1, result.last == "/" {
      result.removeLast()
    }
    return result
  }
}

struct ContainerBuilderNetworkIdentity: Codable, Equatable, Sendable {
  let networkID: String
  let hostname: String
}

struct ContainerBuilderIdentitySnapshot: Codable, Equatable, Sendable {
  let roleLabel: String?
  let pluginLabel: String?
  let executable: String
  let arguments: [String]
  let userID: UInt32
  let groupID: UInt32
  let terminal: Bool
  let workingDirectory: String
  let addedCapabilities: [String]
  let mounts: [ContainerBuilderMountIdentity]
  let networks: [ContainerBuilderNetworkIdentity]
}

struct ContainerBuilderPinnedArguments: Codable, Equatable, Sendable {
  let rosettaEnabled: [String]
  let rosettaDisabled: [String]

  var allowedSets: [[String]] {
    rosettaEnabled == rosettaDisabled
      ? [rosettaEnabled]
      : [rosettaEnabled, rosettaDisabled]
  }

  func arguments(forRosettaEnabled enabled: Bool) -> [String] {
    enabled ? rosettaEnabled : rosettaDisabled
  }
}

struct ContainerBuilderIdentityRequirements: Codable, Equatable, Sendable {
  let roleLabel: String
  let pluginLabel: String
  let executable: String
  let pinnedArguments: ContainerBuilderPinnedArguments
  let userID: UInt32
  let groupID: UInt32
  let terminal: Bool
  let workingDirectory: String
  let addedCapabilities: [String]
  let mounts: [ContainerBuilderMountIdentity]
  let networks: [ContainerBuilderNetworkIdentity]
}

struct ContainerBuilderDNSConfiguration: Codable, Equatable, Sendable {
  let nameservers: [String]
  let domain: String?
  let searchDomains: [String]
  let options: [String]
}

struct ContainerBuilderDesiredConfiguration: Codable, Equatable, Sendable {
  let image: String
  let imageDescriptorDigest: String
  let cpuCount: Int
  let memoryBytes: UInt64
  let rosettaEnabled: Bool
  let managedColorEnvironment: [String]
  let dns: ContainerBuilderDNSConfiguration?
}

struct ContainerBuilderSafetySnapshot: Codable, Equatable, Sendable {
  let state: ContainerBuilderRuntimeState
  let identity: ContainerBuilderIdentitySnapshot?
  let configuration: ContainerBuilderDesiredConfiguration?

  static let absent = ContainerBuilderSafetySnapshot(
    state: .absent,
    identity: nil,
    configuration: nil
  )
}

struct ContainerBuilderReviewedSnapshot: Codable, Equatable, Sendable {
  let creationDate: Date
  let safety: ContainerBuilderSafetySnapshot
}

enum ContainerBuilderDialGateError: Error, Equatable, Sendable {
  case changedBeforeDial
  case changedAfterDial
}

enum ContainerBuilderDialGate {
  static func connect<Connection: Sendable>(
    expected: ContainerBuilderReviewedSnapshot,
    current: @escaping @Sendable () async throws -> ContainerBuilderReviewedSnapshot?,
    dial: @escaping @Sendable () async throws -> Connection,
    close: @escaping @Sendable (Connection) async -> Void
  ) async throws -> Connection {
    guard try await current() == expected else {
      throw ContainerBuilderDialGateError.changedBeforeDial
    }

    let connection = try await dial()
    do {
      guard try await current() == expected else {
        throw ContainerBuilderDialGateError.changedAfterDial
      }
      return connection
    } catch {
      await close(connection)
      throw error
    }
  }
}

struct ContainerBuilderSafetyAuthorization: Codable, Equatable, Sendable {
  let allowsRecreateStoppedBuilder: Bool
  let allowsStopRunningBuilder: Bool

  static let none = ContainerBuilderSafetyAuthorization(
    allowsRecreateStoppedBuilder: false,
    allowsStopRunningBuilder: false
  )
}

enum ContainerBuilderSafetyAction: String, Codable, Equatable, Sendable {
  case create
  case reuse
  case start
  case stopDeleteCreate
  case deleteCreate
}

enum ContainerBuilderFailedCreateCleanupAction: Equatable, Sendable {
  case deleteStopped
  case leaveIntact
}

enum ContainerBuilderSafetyReasonCode: String, Codable, Equatable, Sendable {
  case absentCreate = "builder-absent-create"
  case exactRunningReuse = "builder-exact-running-reuse"
  case exactStoppedStart = "builder-exact-stopped-start"
  case stoppingDenied = "builder-stopping-denied"
  case unknownDenied = "builder-unknown-denied"
  case identityConflictDenied = "builder-identity-conflict-denied"
  case runningDriftDenied = "builder-running-drift-denied"
  case runningDriftRecreate = "builder-running-drift-recreate"
  case stoppedDriftDenied = "builder-stopped-drift-denied"
  case stoppedDriftRecreate = "builder-stopped-drift-recreate"
}

enum ContainerBuilderSafetyErrorCode: String, Codable, Equatable, Sendable {
  case conflict = "builder-conflict"
  case stopping = "builder-stopping"
  case unknownState = "builder-unknown-state"
  case runningDrift = "builder-running-drift"
  case stoppedDrift = "builder-stopped-drift"
}

enum ContainerBuilderIdentityMismatch: String, Codable, Equatable, Sendable {
  case observationUnavailable = "identity-observation-unavailable"
  case roleLabel = "identity-role-label"
  case pluginLabel = "identity-plugin-label"
  case executable = "identity-executable"
  case arguments = "identity-arguments"
  case rootUser = "identity-root-user"
  case terminal = "identity-terminal"
  case workingDirectory = "identity-working-directory"
  case addedCapabilities = "identity-added-capabilities"
  case mounts = "identity-mounts"
  case networks = "identity-networks"
}

enum ContainerBuilderConfigurationMismatch: String, Codable, Equatable, Sendable {
  case observationUnavailable = "configuration-observation-unavailable"
  case image = "configuration-image"
  case imageDescriptorDigest = "configuration-image-descriptor-digest"
  case cpuCount = "configuration-cpu-count"
  case memoryBytes = "configuration-memory-bytes"
  case rosetta = "configuration-rosetta"
  case arguments = "configuration-arguments"
  case managedColorEnvironment = "configuration-managed-color-environment"
  case dns = "configuration-dns"
}

struct ContainerBuilderSafetyDecision: Codable, Equatable, Sendable {
  let action: ContainerBuilderSafetyAction?
  let reasonCode: ContainerBuilderSafetyReasonCode
  let errorCode: ContainerBuilderSafetyErrorCode?
  let identityMismatches: [ContainerBuilderIdentityMismatch]
  let configurationMismatches: [ContainerBuilderConfigurationMismatch]

  var isAllowed: Bool { action != nil && errorCode == nil }

  fileprivate static func allow(
    _ action: ContainerBuilderSafetyAction,
    reasonCode: ContainerBuilderSafetyReasonCode,
    configurationMismatches: [ContainerBuilderConfigurationMismatch] = []
  ) -> ContainerBuilderSafetyDecision {
    ContainerBuilderSafetyDecision(
      action: action,
      reasonCode: reasonCode,
      errorCode: nil,
      identityMismatches: [],
      configurationMismatches: configurationMismatches
    )
  }

  fileprivate static func deny(
    reasonCode: ContainerBuilderSafetyReasonCode,
    errorCode: ContainerBuilderSafetyErrorCode,
    identityMismatches: [ContainerBuilderIdentityMismatch] = [],
    configurationMismatches: [ContainerBuilderConfigurationMismatch] = []
  ) -> ContainerBuilderSafetyDecision {
    ContainerBuilderSafetyDecision(
      action: nil,
      reasonCode: reasonCode,
      errorCode: errorCode,
      identityMismatches: identityMismatches,
      configurationMismatches: configurationMismatches
    )
  }
}

enum ContainerBuilderSafetyPolicy {
  static func failedCreateCleanupAction(
    for state: ContainerBuilderRuntimeState
  ) -> ContainerBuilderFailedCreateCleanupAction {
    state == .stopped ? .deleteStopped : .leaveIntact
  }

  static func evaluate(
    snapshot: ContainerBuilderSafetySnapshot,
    identity requirements: ContainerBuilderIdentityRequirements,
    desiredConfiguration desired: ContainerBuilderDesiredConfiguration,
    authorization: ContainerBuilderSafetyAuthorization = .none
  ) -> ContainerBuilderSafetyDecision {
    switch snapshot.state {
    case .absent:
      return .allow(.create, reasonCode: .absentCreate)
    case .stopping:
      return .deny(reasonCode: .stoppingDenied, errorCode: .stopping)
    case .unknown:
      return .deny(reasonCode: .unknownDenied, errorCode: .unknownState)
    case .running, .stopped:
      break
    }

    let identityMismatches = identityMismatches(
      snapshot.identity,
      requirements: requirements
    )
    guard identityMismatches.isEmpty else {
      return .deny(
        reasonCode: .identityConflictDenied,
        errorCode: .conflict,
        identityMismatches: identityMismatches
      )
    }

    let configurationMismatches = configurationMismatches(
      snapshot.configuration,
      observedIdentity: snapshot.identity,
      requirements: requirements,
      desired: desired
    )
    if configurationMismatches.isEmpty {
      switch snapshot.state {
      case .running:
        return .allow(.reuse, reasonCode: .exactRunningReuse)
      case .stopped:
        return .allow(.start, reasonCode: .exactStoppedStart)
      case .absent, .stopping, .unknown:
        preconditionFailure("Runtime state was handled before identity evaluation")
      }
    }

    switch snapshot.state {
    case .running where authorization.allowsStopRunningBuilder:
      return .allow(
        .stopDeleteCreate,
        reasonCode: .runningDriftRecreate,
        configurationMismatches: configurationMismatches
      )
    case .running:
      return .deny(
        reasonCode: .runningDriftDenied,
        errorCode: .runningDrift,
        configurationMismatches: configurationMismatches
      )
    case .stopped where authorization.allowsRecreateStoppedBuilder:
      return .allow(
        .deleteCreate,
        reasonCode: .stoppedDriftRecreate,
        configurationMismatches: configurationMismatches
      )
    case .stopped:
      return .deny(
        reasonCode: .stoppedDriftDenied,
        errorCode: .stoppedDrift,
        configurationMismatches: configurationMismatches
      )
    case .absent, .stopping, .unknown:
      preconditionFailure("Runtime state was handled before configuration evaluation")
    }
  }

  static func identityMismatches(
    _ observed: ContainerBuilderIdentitySnapshot?,
    requirements: ContainerBuilderIdentityRequirements
  ) -> [ContainerBuilderIdentityMismatch] {
    guard let observed else { return [.observationUnavailable] }

    var mismatches: [ContainerBuilderIdentityMismatch] = []
    if observed.roleLabel != requirements.roleLabel { mismatches.append(.roleLabel) }
    if observed.pluginLabel != requirements.pluginLabel { mismatches.append(.pluginLabel) }
    if observed.executable != requirements.executable { mismatches.append(.executable) }
    if !requirements.pinnedArguments.allowedSets.contains(observed.arguments) {
      mismatches.append(.arguments)
    }
    if observed.userID != requirements.userID || observed.groupID != requirements.groupID {
      mismatches.append(.rootUser)
    }
    if observed.terminal != requirements.terminal { mismatches.append(.terminal) }
    if observed.workingDirectory != requirements.workingDirectory {
      mismatches.append(.workingDirectory)
    }
    if observed.addedCapabilities != requirements.addedCapabilities {
      mismatches.append(.addedCapabilities)
    }
    if observed.mounts != requirements.mounts { mismatches.append(.mounts) }
    if observed.networks != requirements.networks { mismatches.append(.networks) }
    return mismatches
  }

  private static func configurationMismatches(
    _ observed: ContainerBuilderDesiredConfiguration?,
    observedIdentity: ContainerBuilderIdentitySnapshot?,
    requirements: ContainerBuilderIdentityRequirements,
    desired: ContainerBuilderDesiredConfiguration
  ) -> [ContainerBuilderConfigurationMismatch] {
    guard let observed else { return [.observationUnavailable] }

    var mismatches: [ContainerBuilderConfigurationMismatch] = []
    if observed.image != desired.image { mismatches.append(.image) }
    if observed.imageDescriptorDigest != desired.imageDescriptorDigest {
      mismatches.append(.imageDescriptorDigest)
    }
    if observed.cpuCount != desired.cpuCount { mismatches.append(.cpuCount) }
    if observed.memoryBytes != desired.memoryBytes { mismatches.append(.memoryBytes) }
    if observed.rosettaEnabled != desired.rosettaEnabled { mismatches.append(.rosetta) }
    if observedIdentity?.arguments
      != requirements.pinnedArguments.arguments(forRosettaEnabled: desired.rosettaEnabled)
    {
      mismatches.append(.arguments)
    }
    if observed.managedColorEnvironment != desired.managedColorEnvironment {
      mismatches.append(.managedColorEnvironment)
    }
    if observed.dns != desired.dns { mismatches.append(.dns) }
    return mismatches
  }
}
