import Testing

@testable import NativeContainers

@Suite("Socktainer Compose conformance")
struct SocktainerComposeConformanceServiceTests {
  @Test
  func pinnedManifestPublishesDeterministicCapabilityBoundary() throws {
    let report = SocktainerComposeConformanceService().report()

    #expect(report.bridgeVersion == "1.0.0")
    #expect(report.engineAPIVersion == "1.51")
    #expect(report.sourceRevision == "876c2fc")
    #expect(report.results.map(\.id).count == Set(report.results.map(\.id)).count)
    #expect(report.supportedCount == 4)
    #expect(report.gapCount == 8)
    #expect(report.projectLifecycleIsEligible)

    #expect(try result("compose-project-labels", in: report).status == .supported)
    #expect(try result("compose-container-lifecycle", in: report).status == .supported)
    let networks = try result("compose-project-networks", in: report)
    #expect(networks.status == .upstreamBlocked)
    #expect(networks.missingOperations == ["Network connect", "Network disconnect"])
    let aliases = try result("compose-network-aliases", in: report)
    #expect(aliases.status == .upstreamBlocked)
    #expect(aliases.missingScenarioIDs == expectedAliasScenarioIDs)
    let health = try result("compose-healthchecks", in: report)
    #expect(health.status == .upstreamBlocked)
    #expect(health.missingScenarioIDs == expectedHealthScenarioIDs)
    let restart = try result("compose-restart-policy", in: report)
    #expect(restart.status == .upstreamBlocked)
    #expect(restart.missingScenarioIDs == expectedRestartScenarioIDs)
    let configs = try result("compose-configs", in: report)
    #expect(configs.status == .upstreamBlocked)
    #expect(configs.evidence.contains("host mounts require a directory"))
    #expect(configs.evidence.contains("root filesystem is unavailable"))
    let secrets = try result("compose-secrets", in: report)
    #expect(secrets.status == .upstreamBlocked)
    #expect(secrets.evidence.contains("host-file bind mounts"))
    #expect(secrets.evidence.contains("pre-start archive copy"))
    let recreation = try result("compose-recreation", in: report)
    #expect(recreation.status == .upstreamBlocked)
    #expect(
      recreation.missingOperations == [
        "Container rename", "Network connect", "Network disconnect",
      ]
    )
    #expect(recreation.missingScenarioIDs == expectedRecreationScenarioIDs)
    #expect(try result("compose-project-lifecycle", in: report).status == .partial)
  }

  @Test
  func missingRouteDegradesAnOtherwiseSupportedFixture() throws {
    let pinned = SocktainerComposeConformanceManifest.version100
    let manifest = SocktainerComposeConformanceManifest(
      bridgeVersion: pinned.bridgeVersion,
      engineAPIVersion: pinned.engineAPIVersion,
      sourceRevision: pinned.sourceRevision,
      implementedOperations: pinned.implementedOperations.subtracting([.volumeCreate]),
      passedScenarioIDs: pinned.passedScenarioIDs,
      fixtures: pinned.fixtures
    )

    let report = SocktainerComposeConformanceService(manifest: manifest).report()
    let volumes = try result("compose-named-volumes", in: report)

    #expect(volumes.status == .upstreamBlocked)
    #expect(volumes.missingOperations == ["Volume create"])
    #expect(volumes.summary.contains("Volume create"))
  }

  @Test
  func nativeContainersForkPassesEveryComposeContract() {
    let report = SocktainerComposeConformanceService(
      manifest: .nativeContainersFork
    ).report()

    #expect(report.bridgeVersion == "1.0.0-nc.1")
    #expect(report.sourceRevision == "5bdafa7")
    #expect(report.supportedCount == 12)
    #expect(report.gapCount == 0)
    #expect(report.projectLifecycleIsEligible)
    #expect(report.results.allSatisfy { $0.status == .supported })
    #expect(report.results.allSatisfy { $0.missingOperations.isEmpty })
    #expect(report.results.allSatisfy { $0.missingScenarioIDs.isEmpty })
  }

  @Test
  func knownSemanticGapCannotBecomeSupportedFromRoutePresenceAlone() throws {
    let report = SocktainerComposeConformanceService().report()
    let health = try result("compose-healthchecks", in: report)

    #expect(health.missingOperations.isEmpty)
    #expect(health.missingScenarioIDs == expectedHealthScenarioIDs)
    #expect(health.status == .upstreamBlocked)
    #expect(health.summary.contains("health-check"))
  }

  @Test
  func semanticScenarioCatalogIsExactUniqueAndRequiresObservablePostconditions() {
    let scenarios = SocktainerComposeSemanticScenarioCatalog.all
    let allAcceptancesArePresent = scenarios.allSatisfy { !$0.acceptance.isEmpty }
    let allScenariosRequirePostconditions = scenarios.allSatisfy(
      \.requiresObservedPostcondition
    )

    #expect(scenarios.count == 41)
    #expect(Set(scenarios.map(\.id)).count == scenarios.count)
    #expect(allAcceptancesArePresent)
    #expect(allScenariosRequirePostconditions)
    #expect(
      SocktainerComposeSemanticScenarioCatalog.recreation.map(\.id).sorted()
        == expectedRecreationScenarioIDs
    )
    #expect(
      SocktainerComposeSemanticScenarioCatalog.aliases.map(\.id).sorted()
        == expectedAliasScenarioIDs
    )
    #expect(
      SocktainerComposeSemanticScenarioCatalog.health.map(\.id).sorted()
        == expectedHealthScenarioIDs
    )
    #expect(
      SocktainerComposeSemanticScenarioCatalog.restartPolicies.map(\.id).sorted()
        == expectedRestartScenarioIDs
    )
  }

  @Test
  func successfulRoutesWithoutObservedRecreationScenariosRemainBlocked() throws {
    let pinned = SocktainerComposeConformanceManifest.version100
    let recreation = try #require(
      pinned.fixtures.first(where: { $0.id == "compose-recreation" })
    )
    let semanticOnlyFixture = SocktainerComposeConformanceFixture(
      id: recreation.id,
      title: recreation.title,
      requiredOperations: recreation.requiredOperations,
      requiredScenarios: recreation.requiredScenarios,
      evidence: recreation.evidence
    )
    let manifest = SocktainerComposeConformanceManifest(
      bridgeVersion: "future-signed-candidate",
      engineAPIVersion: pinned.engineAPIVersion,
      sourceRevision: "candidate-revision",
      implementedOperations: Set(DockerEngineComposeOperation.allCases),
      passedScenarioIDs: [],
      fixtures: [semanticOnlyFixture]
    )

    let result = try #require(
      SocktainerComposeConformanceService(manifest: manifest).report().results.first
    )
    let recreationRequiresPostconditions = recreation.requiredScenarios.allSatisfy(
      \.requiresObservedPostcondition
    )
    #expect(result.missingOperations.isEmpty)
    #expect(result.missingScenarioIDs == expectedRecreationScenarioIDs)
    #expect(result.status == .upstreamBlocked)
    #expect(result.summary.contains("unpassed semantic scenarios"))
    #expect(result.evidence.contains("HTTP success without those state changes fails"))
    #expect(recreationRequiresPostconditions)
  }

  private var expectedRecreationScenarioIDs: [String] {
    [
      "recreation.create-new-before-delete-old",
      "recreation.exact-scale-down",
      "recreation.inspect-round-trip",
      "recreation.network-connect-mutation",
      "recreation.network-disconnect-mutation",
      "recreation.rename-mutation",
      "recreation.targeted-service-replacement",
      "recreation.temporary-replacement-recovery",
    ]
  }

  private var expectedAliasScenarioIDs: [String] {
    [
      "aliases.cross-project-collision-isolation",
      "aliases.custom-aliases",
      "aliases.default-container-alias",
      "aliases.default-service-alias",
      "aliases.inspect-parity",
      "aliases.multiple-network-behavior",
      "aliases.per-network-isolation",
    ]
  }

  private var expectedHealthScenarioIDs: [String] {
    [
      "health.bounded-output-logs",
      "health.cmd",
      "health.cmd-shell",
      "health.container-user",
      "health.depends-on-service-healthy",
      "health.environment",
      "health.events",
      "health.interval",
      "health.none",
      "health.persistence",
      "health.retries",
      "health.start-interval",
      "health.start-period",
      "health.timeout",
      "health.wait-semantics",
      "health.working-directory",
    ]
  }

  private var expectedRestartScenarioIDs: [String] {
    [
      "restart.always",
      "restart.backoff",
      "restart.bridge-restart-recovery",
      "restart.events",
      "restart.inspect-parity",
      "restart.manual-stop",
      "restart.no",
      "restart.on-failure",
      "restart.on-failure-limit",
      "restart.unless-stopped",
    ]
  }

  private func result(
    _ id: String,
    in report: ComposeBridgeConformanceReport
  ) throws -> ComposeBridgeConformanceResult {
    try #require(report.results.first(where: { $0.id == id }))
  }
}
