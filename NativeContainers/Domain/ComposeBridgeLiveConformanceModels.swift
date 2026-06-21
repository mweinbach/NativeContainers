import Foundation

struct SocktainerComposeLiveFixtureConfiguration: Sendable {
  let projectName: String
  let workspaceURL: URL
  let composeExecutableURL: URL
  let dockerContextName: String
  let environment: [String: String]
  let observationAttempts: Int
  let pollInterval: Duration

  init(
    projectName: String,
    workspaceURL: URL,
    composeExecutableURL: URL,
    dockerContextName: String = DockerContextService.contextName,
    environment: [String: String],
    observationAttempts: Int = 40,
    pollInterval: Duration = .milliseconds(250)
  ) throws {
    guard
      projectName.range(
        of: #"^ncwire-[a-f0-9]{8}$"#,
        options: .regularExpression
      ) != nil
    else {
      throw SocktainerComposeLiveFixtureError.invalidProjectName(projectName)
    }
    guard observationAttempts > 0 else {
      throw SocktainerComposeLiveFixtureError.invalidObservationAttempts
    }

    self.projectName = projectName
    self.workspaceURL = workspaceURL
    self.composeExecutableURL = composeExecutableURL
    self.dockerContextName = dockerContextName
    self.environment = environment
    self.observationAttempts = observationAttempts
    self.pollInterval = pollInterval
  }

  var containerName: String { "\(projectName)-probe" }
  var volumeName: String { "\(projectName)-data" }
  var networkName: String { "\(projectName)-network" }
}

struct SocktainerComposeLiveFixtureResult: Equatable, Sendable {
  let projectName: String
  let observedState: ComposeObservedState
  let containerID: String
  let volumeID: String
  let networkID: String
  let usedFallbackCleanup: Bool
}

enum SocktainerComposeLiveFixtureError: LocalizedError, Equatable, Sendable {
  case invalidProjectName(String)
  case invalidObservationAttempts
  case unsafeWorkspace(String)
  case commandExecutionFailed(operation: String, reason: String)
  case commandFailed(operation: String, exitCode: Int32, output: String)
  case projectNotObserved(String)
  case unsafeCleanupResource(String)
  case cleanupResourceChanged(String)
  case cleanupResourcesRemain([String])
  case operationFailed(String)
  case cleanupFailed(String)
  case operationAndCleanupFailed(operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .invalidProjectName(let name):
      "The live Compose fixture project name is invalid: \(name)."
    case .invalidObservationAttempts:
      "The live Compose fixture requires at least one observation attempt."
    case .unsafeWorkspace(let reason):
      "The live Compose fixture workspace is unsafe: \(reason)."
    case .commandExecutionFailed(let operation, let reason):
      "\(operation) could not be executed: \(reason)"
    case .commandFailed(let operation, let exitCode, let output):
      "\(operation) exited with status \(exitCode).\(output.isEmpty ? "" : " " + output)"
    case .projectNotObserved(let reason):
      "The canonical Compose project was not observed through Apple inventory. \(reason)"
    case .unsafeCleanupResource(let resource):
      "Refusing to clean up \(resource) because its canonical fixture labels do not match."
    case .cleanupResourceChanged(let resource):
      "Refusing to clean up \(resource) because its identity changed after review."
    case .cleanupResourcesRemain(let resources):
      "Live Compose fixture resources remain after cleanup: \(resources.joined(separator: ", "))."
    case .operationFailed(let reason):
      "The live Compose fixture failed after cleanup completed. \(reason)"
    case .cleanupFailed(let reason):
      "The live Compose fixture cleanup failed. \(reason)"
    case .operationAndCleanupFailed(let operation, let cleanup):
      "The live Compose fixture failed, and cleanup also failed. Operation: \(operation) Cleanup: \(cleanup)"
    }
  }
}

struct SocktainerComposeFixtureContainerIdentity: Equatable, Sendable {
  let id: String
  let createdAt: Date
  let labels: [String: String]

  init(_ container: ContainerRecord) {
    id = container.id
    createdAt = container.createdAt
    labels = container.labels
  }

  func matches(_ container: ContainerRecord) -> Bool {
    self == Self(container)
  }
}

struct SocktainerComposeFixtureVolumeIdentity: Equatable, Sendable {
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

struct SocktainerComposeFixtureNetworkIdentity: Equatable, Sendable {
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

struct SocktainerComposeFixtureCleanupPlan: Equatable, Sendable {
  let container: SocktainerComposeFixtureContainerIdentity?
  let volume: SocktainerComposeFixtureVolumeIdentity?
  let network: SocktainerComposeFixtureNetworkIdentity?
}
