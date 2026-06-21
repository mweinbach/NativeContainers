import Foundation

protocol ComposeBridgeConformanceReporting: Sendable {
  func report() -> ComposeBridgeConformanceReport
}

enum DockerEngineComposeOperation: String, CaseIterable, Hashable, Sendable {
  case containerCreate = "Container create"
  case containerDelete = "Container delete"
  case containerInspect = "Container inspect"
  case containerKill = "Container kill"
  case containerList = "Container list"
  case containerLogs = "Container logs"
  case containerStart = "Container start"
  case containerStop = "Container stop"
  case containerWait = "Container wait"
  case networkConnect = "Network connect"
  case networkCreate = "Network create"
  case networkDelete = "Network delete"
  case networkDisconnect = "Network disconnect"
  case networkInspect = "Network inspect"
  case networkList = "Network list"
  case volumeCreate = "Volume create"
  case volumeDelete = "Volume delete"
  case volumeInspect = "Volume inspect"
  case volumeList = "Volume list"
}

struct SocktainerComposeConformanceFixture: Equatable, Sendable {
  let id: String
  let title: String
  let requiredOperations: Set<DockerEngineComposeOperation>
  let evidence: String
  let limitations: [String]
  let unsupportedReason: String?
  let policyBlockReason: String?

  init(
    id: String,
    title: String,
    requiredOperations: Set<DockerEngineComposeOperation>,
    evidence: String,
    limitations: [String] = [],
    unsupportedReason: String? = nil,
    policyBlockReason: String? = nil
  ) {
    self.id = id
    self.title = title
    self.requiredOperations = requiredOperations
    self.evidence = evidence
    self.limitations = limitations
    self.unsupportedReason = unsupportedReason
    self.policyBlockReason = policyBlockReason
  }
}

struct SocktainerComposeConformanceManifest: Equatable, Sendable {
  let bridgeVersion: String
  let engineAPIVersion: String
  let sourceRevision: String
  let implementedOperations: Set<DockerEngineComposeOperation>
  let fixtures: [SocktainerComposeConformanceFixture]

  static let version1_0_0 = SocktainerComposeConformanceManifest(
    bridgeVersion: "1.0.0",
    engineAPIVersion: "1.51",
    sourceRevision: "876c2fc",
    implementedOperations: [
      .containerCreate, .containerDelete, .containerInspect, .containerKill,
      .containerList, .containerLogs, .containerStart, .containerStop,
      .containerWait, .networkConnect, .networkCreate, .networkDelete,
      .networkDisconnect, .networkInspect, .networkList, .volumeCreate,
      .volumeDelete, .volumeInspect, .volumeList,
    ],
    fixtures: [
      SocktainerComposeConformanceFixture(
        id: "compose-project-labels",
        title: "Canonical project identity",
        requiredOperations: [.containerCreate, .volumeCreate, .networkCreate],
        evidence:
          "Container, volume, and network create payload fixtures preserve canonical Compose labels."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-container-lifecycle",
        title: "Service container lifecycle",
        requiredOperations: [
          .containerList, .containerCreate, .containerInspect, .containerStart,
          .containerStop, .containerKill, .containerWait, .containerDelete,
        ],
        evidence:
          "Pinned Engine routes cover create, inspect, start, graceful stop, kill, wait, and delete."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-service-logs",
        title: "Service inspection and logs",
        requiredOperations: [.containerList, .containerInspect, .containerLogs],
        evidence: "Pinned Engine routes expose service inventory, inspection, and logs."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-named-volumes",
        title: "Named volumes",
        requiredOperations: [.volumeList, .volumeCreate, .volumeInspect, .volumeDelete],
        evidence: "Pinned Engine routes cover labeled named-volume lifecycle."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-project-networks",
        title: "Project networks",
        requiredOperations: [
          .networkList, .networkCreate, .networkInspect, .networkConnect,
          .networkDisconnect, .networkDelete,
        ],
        evidence: "Pinned Engine routes cover labeled project-network lifecycle.",
        limitations: [
          "Per-service network aliases are not mapped by Socktainer 1.0.0."
        ]
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-healthchecks",
        title: "Health checks",
        requiredOperations: [.containerCreate, .containerInspect],
        evidence: "Create and inspect routes exist, but the health contract is not implemented.",
        unsupportedReason:
          "Socktainer 1.0.0 does not map Compose health-check configuration or health state."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-restart-policy",
        title: "Restart policies",
        requiredOperations: [.containerCreate, .containerInspect],
        evidence: "Create and inspect routes exist, but restart-policy parity is absent.",
        unsupportedReason:
          "Socktainer 1.0.0 does not provide Compose restart-policy behavior."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-configs-secrets",
        title: "Configs and secrets",
        requiredOperations: [.containerCreate],
        evidence: "Container creation exists, but Compose config and secret objects are absent.",
        unsupportedReason:
          "Socktainer 1.0.0 has no Docker Engine config or secret resource contract."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-project-lifecycle",
        title: "Project lifecycle",
        requiredOperations: [],
        evidence:
          "NativeContainers requires a reviewed Compose model and frozen resource identities before mutation.",
        policyBlockReason:
          "Project start, stop, and down remain disabled until desired replicas, orphan handling, and volume intent come from a reviewed Compose model."
      ),
    ]
  )
}

struct SocktainerComposeConformanceService: ComposeBridgeConformanceReporting {
  private let manifest: SocktainerComposeConformanceManifest

  init(manifest: SocktainerComposeConformanceManifest = .version1_0_0) {
    self.manifest = manifest
  }

  func report() -> ComposeBridgeConformanceReport {
    ComposeBridgeConformanceReport(
      bridgeVersion: manifest.bridgeVersion,
      engineAPIVersion: manifest.engineAPIVersion,
      sourceRevision: manifest.sourceRevision,
      results: manifest.fixtures.map(evaluate)
    )
  }

  private func evaluate(
    _ fixture: SocktainerComposeConformanceFixture
  ) -> ComposeBridgeConformanceResult {
    let missing = fixture.requiredOperations
      .subtracting(manifest.implementedOperations)
      .map(\.rawValue)
      .sorted()

    let status: ComposeBridgeConformanceStatus
    let summary: String
    if let reason = fixture.policyBlockReason {
      status = .policyBlocked
      summary = reason
    } else if let reason = fixture.unsupportedReason {
      status = .unsupported
      summary = reason
    } else if !missing.isEmpty {
      status = .unsupported
      summary = "The pinned route manifest is missing: \(missing.joined(separator: ", "))."
    } else if !fixture.limitations.isEmpty {
      status = .partial
      summary = fixture.limitations.joined(separator: " ")
    } else {
      status = .supported
      summary = "Covered by the pinned Socktainer route and payload contract."
    }

    return ComposeBridgeConformanceResult(
      id: fixture.id,
      title: fixture.title,
      status: status,
      summary: summary,
      evidence: fixture.evidence,
      missingOperations: missing
    )
  }
}
