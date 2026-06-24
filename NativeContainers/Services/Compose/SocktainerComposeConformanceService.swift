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
  case containerRename = "Container rename"
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

enum SocktainerComposeSemanticProof: String, Equatable, Sendable {
  case observedMutation
  case inspectRoundTrip
  case orderedLifecycle
  case isolatedBehavior
  case runtimeBehavior
  case recovery
}

struct SocktainerComposeSemanticScenario: Equatable, Sendable {
  let id: String
  let acceptance: String
  let proof: SocktainerComposeSemanticProof
  let requiresObservedPostcondition: Bool

  init(
    id: String,
    acceptance: String,
    proof: SocktainerComposeSemanticProof,
    requiresObservedPostcondition: Bool = true
  ) {
    self.id = id
    self.acceptance = acceptance
    self.proof = proof
    self.requiresObservedPostcondition = requiresObservedPostcondition
  }
}

enum SocktainerComposeSemanticScenarioCatalog {
  static let recreation: [SocktainerComposeSemanticScenario] = [
    scenario(
      "recreation.rename-mutation",
      "Rename changes the addressed container identity and inspect returns the new name.",
      .observedMutation
    ),
    scenario(
      "recreation.network-connect-mutation",
      "Network connect creates the requested attachment and inspect reports it.",
      .observedMutation
    ),
    scenario(
      "recreation.network-disconnect-mutation",
      "Network disconnect removes only the requested attachment and inspect confirms absence.",
      .observedMutation
    ),
    scenario(
      "recreation.inspect-round-trip",
      "Replacement configuration and attachments round-trip through container and network inspection.",
      .inspectRoundTrip
    ),
    scenario(
      "recreation.create-new-before-delete-old",
      "A validated replacement is created before the old container is deleted.",
      .orderedLifecycle
    ),
    scenario(
      "recreation.targeted-service-replacement",
      "Replacing one service leaves unrelated services and replicas unchanged.",
      .isolatedBehavior
    ),
    scenario(
      "recreation.exact-scale-down",
      "Scale-down removes exactly the excess highest replicas and no retained replica.",
      .observedMutation
    ),
    scenario(
      "recreation.temporary-replacement-recovery",
      "Interrupted temporary replacement state is detected and recoverable without losing the predecessor.",
      .recovery
    ),
  ]

  static let aliases: [SocktainerComposeSemanticScenario] = [
    scenario(
      "aliases.per-network-isolation",
      "An alias resolves only on the network to which it was assigned.",
      .isolatedBehavior
    ),
    scenario(
      "aliases.multiple-network-behavior",
      "One service can expose different exact alias sets on multiple networks.",
      .runtimeBehavior
    ),
    scenario(
      "aliases.cross-project-collision-isolation",
      "Identical aliases in separate projects remain isolated by their project networks.",
      .isolatedBehavior
    ),
    scenario(
      "aliases.default-service-alias",
      "The default service-name alias resolves on every attached Compose network.",
      .runtimeBehavior
    ),
    scenario(
      "aliases.default-container-alias",
      "The default container-name alias resolves without replacing the service alias.",
      .runtimeBehavior
    ),
    scenario(
      "aliases.custom-aliases",
      "All requested custom aliases resolve and unrequested aliases do not.",
      .runtimeBehavior
    ),
    scenario(
      "aliases.inspect-parity",
      "Network and container inspection return the same effective per-network aliases.",
      .inspectRoundTrip
    ),
  ]

  static let health: [SocktainerComposeSemanticScenario] = [
    scenario("health.cmd", "CMD probes execute as direct argv.", .runtimeBehavior),
    scenario(
      "health.cmd-shell",
      "CMD-SHELL probes execute with the container shell contract.",
      .runtimeBehavior
    ),
    scenario("health.none", "NONE disables an inherited health check.", .runtimeBehavior),
    scenario(
      "health.container-user",
      "The probe executes as the configured container user.",
      .runtimeBehavior
    ),
    scenario(
      "health.environment",
      "The probe receives the effective configured container environment.",
      .runtimeBehavior
    ),
    scenario(
      "health.working-directory",
      "The probe executes in the configured container working directory.",
      .runtimeBehavior
    ),
    scenario("health.interval", "Probe cadence honors interval.", .runtimeBehavior),
    scenario(
      "health.timeout", "A probe exceeding timeout is terminated and fails.", .runtimeBehavior),
    scenario(
      "health.retries",
      "Health changes only after the configured consecutive retry threshold.",
      .runtimeBehavior
    ),
    scenario(
      "health.start-period",
      "Failures during start-period receive Docker-compatible treatment.",
      .runtimeBehavior
    ),
    scenario(
      "health.start-interval",
      "Probe cadence during start-period honors start-interval.",
      .runtimeBehavior
    ),
    scenario(
      "health.bounded-output-logs",
      "Probe output history is bounded while retaining the required recent result data.",
      .runtimeBehavior
    ),
    scenario(
      "health.events",
      "Health transitions emit the corresponding ordered events.",
      .runtimeBehavior
    ),
    scenario(
      "health.wait-semantics",
      "Wait behavior observes the terminal health-dependent condition exactly.",
      .runtimeBehavior
    ),
    scenario(
      "health.persistence",
      "Configured health state and history survive the required bridge/runtime restart boundary.",
      .recovery
    ),
    scenario(
      "health.depends-on-service-healthy",
      "depends_on service_healthy delays the dependent until the dependency becomes healthy.",
      .orderedLifecycle
    ),
  ]

  static let restartPolicies: [SocktainerComposeSemanticScenario] = [
    scenario("restart.no", "The no policy never restarts an exited container.", .runtimeBehavior),
    scenario(
      "restart.always",
      "The always policy restarts after successful and failed exits.",
      .runtimeBehavior
    ),
    scenario(
      "restart.on-failure",
      "The on-failure policy restarts only after nonzero exits.",
      .runtimeBehavior
    ),
    scenario(
      "restart.on-failure-limit",
      "on-failure with a limit performs no more than the configured restart count.",
      .runtimeBehavior
    ),
    scenario(
      "restart.unless-stopped",
      "unless-stopped restarts failures but preserves an explicit manual stop.",
      .runtimeBehavior
    ),
    scenario(
      "restart.backoff",
      "Repeated failures apply bounded Docker-compatible restart backoff.",
      .runtimeBehavior
    ),
    scenario(
      "restart.manual-stop",
      "A manual stop suppresses restart according to the selected policy.",
      .runtimeBehavior
    ),
    scenario(
      "restart.bridge-restart-recovery",
      "Policy state and eligible restart behavior recover after a bridge restart.",
      .recovery
    ),
    scenario(
      "restart.events",
      "Each policy-driven restart emits ordered die/start/restart event evidence.",
      .runtimeBehavior
    ),
    scenario(
      "restart.inspect-parity",
      "Inspection reports the configured policy, retry limit, and observed restart count.",
      .inspectRoundTrip
    ),
  ]

  static let all: [SocktainerComposeSemanticScenario] =
    recreation + aliases + health + restartPolicies

  private static func scenario(
    _ id: String,
    _ acceptance: String,
    _ proof: SocktainerComposeSemanticProof
  ) -> SocktainerComposeSemanticScenario {
    SocktainerComposeSemanticScenario(
      id: id,
      acceptance: acceptance,
      proof: proof,
      requiresObservedPostcondition: true
    )
  }
}

struct SocktainerComposeConformanceFixture: Equatable, Sendable {
  let id: String
  let title: String
  let requiredOperations: Set<DockerEngineComposeOperation>
  let requiredScenarios: [SocktainerComposeSemanticScenario]
  let evidence: String
  let limitations: [String]
  let upstreamBlockReason: String?
  let policyBlockReason: String?

  init(
    id: String,
    title: String,
    requiredOperations: Set<DockerEngineComposeOperation>,
    requiredScenarios: [SocktainerComposeSemanticScenario] = [],
    evidence: String,
    limitations: [String] = [],
    upstreamBlockReason: String? = nil,
    policyBlockReason: String? = nil
  ) {
    self.id = id
    self.title = title
    self.requiredOperations = requiredOperations
    self.requiredScenarios = requiredScenarios
    self.evidence = evidence
    self.limitations = limitations
    self.upstreamBlockReason = upstreamBlockReason
    self.policyBlockReason = policyBlockReason
  }
}

struct SocktainerComposeConformanceManifest: Equatable, Sendable {
  let bridgeVersion: String
  let engineAPIVersion: String
  let sourceRevision: String
  let implementedOperations: Set<DockerEngineComposeOperation>
  let passedScenarioIDs: Set<String>
  let fixtures: [SocktainerComposeConformanceFixture]

  static let version100 = SocktainerComposeConformanceManifest(
    bridgeVersion: "1.0.0",
    engineAPIVersion: "1.51",
    sourceRevision: "876c2fc",
    implementedOperations: [
      .containerCreate, .containerDelete, .containerInspect, .containerKill,
      .containerList, .containerLogs, .containerStart, .containerStop,
      .containerWait, .networkCreate, .networkDelete, .networkInspect,
      .networkList, .volumeCreate, .volumeDelete, .volumeInspect, .volumeList,
    ],
    passedScenarioIDs: [],
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
        evidence:
          "Pinned create/list/inspect/delete routes cover labeled project networks, but Socktainer 1.0.0 returns NotImplemented for connect and disconnect."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-network-aliases",
        title: "Network aliases",
        requiredOperations: [.containerCreate, .containerInspect],
        requiredScenarios: SocktainerComposeSemanticScenarioCatalog.aliases,
        evidence: "The bridge can create and inspect containers, but it drops alias intent.",
        upstreamBlockReason:
          "Socktainer 1.0.0 does not map per-service Compose network aliases."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-healthchecks",
        title: "Health checks",
        requiredOperations: [.containerCreate, .containerInspect],
        requiredScenarios: SocktainerComposeSemanticScenarioCatalog.health,
        evidence: "Create and inspect routes exist, but the health contract is not implemented.",
        upstreamBlockReason:
          "Socktainer 1.0.0 does not map Compose health-check configuration or health state."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-restart-policy",
        title: "Restart policies",
        requiredOperations: [.containerCreate, .containerInspect],
        requiredScenarios: SocktainerComposeSemanticScenarioCatalog.restartPolicies,
        evidence: "Create and inspect routes exist, but restart-policy parity is absent.",
        upstreamBlockReason:
          "Socktainer 1.0.0 does not provide Compose restart-policy behavior."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-configs",
        title: "Configs",
        requiredOperations: [.containerCreate],
        evidence:
          "The NativeContainers review vault and final overlay are implemented. Against signed Socktainer 1.0.0, file-backed configs fail container creation because Apple host mounts require a directory; literal and environment configs reach archive injection but the pre-start archive route reports that the container root filesystem is unavailable.",
        upstreamBlockReason:
          "Signed Socktainer 1.0.0 cannot reproduce Docker Compose local config mount and pre-start injection semantics."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-secrets",
        title: "Secrets",
        requiredOperations: [.containerCreate],
        evidence:
          "The NativeContainers review vault and redacted execution path are implemented. Against signed Socktainer 1.0.0, file-backed secrets require unsupported host-file bind mounts and environment secrets fail the pre-start archive copy because no root filesystem is exposed yet.",
        upstreamBlockReason:
          "Signed Socktainer 1.0.0 cannot reproduce Docker Compose local secret mount and pre-start injection semantics."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-recreation",
        title: "Container recreation",
        requiredOperations: [.containerRename, .networkConnect, .networkDisconnect],
        requiredScenarios: SocktainerComposeSemanticScenarioCatalog.recreation,
        evidence:
          "Compose replacement needs observed rename and network mutations plus ordered replacement, isolation, scale-down, inspection, and recovery postconditions. HTTP success without those state changes fails conformance.",
        upstreamBlockReason:
          "Signed Socktainer 1.0.0 lacks the required replacement routes and has passed none of the exact recreation scenarios."
      ),
      SocktainerComposeConformanceFixture(
        id: "compose-project-lifecycle",
        title: "Project lifecycle",
        requiredOperations: [],
        evidence:
          "NativeContainers renders a stable full/active model, stores opaque reviewed plans, revalidates source/binary/environment/inventory at commit time, and journals exact-ID mutations.",
        limitations: [
          "Execution covers fresh and contiguous-prefix create-missing Up through a frozen external-resource overlay, exact-ID Start/Stop, separately typed declared/orphan Down, and reviewed named-volume/network deletion. Scale-down and replacement are outside this executable subset."
        ]
      ),
    ]
  )

  static let nativeContainersFork: SocktainerComposeConformanceManifest = {
    let verifiedEvidence: [String: String] = [
      "compose-project-networks":
        "Live network connect and disconnect mutations round-trip through both container and network inspection.",
      "compose-network-aliases":
        "Live multi-network probes proved per-network default and custom alias isolation plus inspect parity.",
      "compose-healthchecks":
        "Live probes proved Docker health commands, context, cadence, bounded logs, events, persistence, wait semantics, and service_healthy ordering.",
      "compose-restart-policy":
        "Live probes proved all four restart policies, retry limits, bounded backoff, manual stops, bridge recovery, events, and inspect parity.",
      "compose-configs":
        "File, literal-content, and reviewed-environment configs are injected into a private EXT4 rootfs override with bounded attributes and exact bytes.",
      "compose-secrets":
        "File and reviewed-environment secrets are injected into a private EXT4 rootfs override without persisting values or direct secret hashes.",
      "compose-recreation":
        "Live replacement and scale tests proved new native identity, exact targeted replacement, rename/connect/disconnect mutations, inspection, and highest-replica scale-down.",
      "compose-project-lifecycle":
        "Reviewed Up now plans create, converge, replacement, and exact scale-down actions and verifies the final identity-sealed replica set.",
    ]
    let fixtures = version100.fixtures.map { fixture in
      SocktainerComposeConformanceFixture(
        id: fixture.id,
        title: fixture.title,
        requiredOperations: fixture.requiredOperations,
        requiredScenarios: fixture.requiredScenarios,
        evidence: verifiedEvidence[fixture.id] ?? fixture.evidence
      )
    }
    return SocktainerComposeConformanceManifest(
      bridgeVersion: "1.0.0-nc.1",
      engineAPIVersion: "1.51",
      sourceRevision: "5bdafa7",
      implementedOperations: Set(DockerEngineComposeOperation.allCases),
      passedScenarioIDs: Set(SocktainerComposeSemanticScenarioCatalog.all.map(\.id)),
      fixtures: fixtures
    )
  }()
}

struct SocktainerComposeConformanceService: ComposeBridgeConformanceReporting {
  private let manifest: SocktainerComposeConformanceManifest

  init(manifest: SocktainerComposeConformanceManifest = .version100) {
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
    let requiredScenarioIDs = fixture.requiredScenarios.map(\.id).sorted()
    let missingScenarioIDs = Set(requiredScenarioIDs)
      .subtracting(manifest.passedScenarioIDs)
      .sorted()

    let status: ComposeBridgeConformanceStatus
    let summary: String
    if let reason = fixture.policyBlockReason {
      status = .policyBlocked
      summary = reason
    } else if let reason = fixture.upstreamBlockReason {
      status = .upstreamBlocked
      summary = reason
    } else if !missing.isEmpty || !missingScenarioIDs.isEmpty {
      status = .upstreamBlocked
      let routeSummary =
        missing.isEmpty
        ? nil
        : "missing routes: \(missing.joined(separator: ", "))"
      let scenarioSummary =
        missingScenarioIDs.isEmpty
        ? nil
        : "unpassed semantic scenarios: \(missingScenarioIDs.joined(separator: ", "))"
      summary =
        "The pinned conformance manifest has \([routeSummary, scenarioSummary].compactMap { $0 }.joined(separator: "; "))."
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
      missingOperations: missing,
      requiredScenarioIDs: requiredScenarioIDs,
      missingScenarioIDs: missingScenarioIDs
    )
  }
}
