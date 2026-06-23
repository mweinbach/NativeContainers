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
    #expect(try result("compose-network-aliases", in: report).status == .upstreamBlocked)
    #expect(try result("compose-healthchecks", in: report).status == .upstreamBlocked)
    #expect(try result("compose-configs", in: report).status == .upstreamBlocked)
    #expect(try result("compose-secrets", in: report).status == .upstreamBlocked)
    let recreation = try result("compose-recreation", in: report)
    #expect(recreation.status == .upstreamBlocked)
    #expect(
      recreation.missingOperations == [
        "Container rename", "Network connect", "Network disconnect",
      ]
    )
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
      fixtures: pinned.fixtures
    )

    let report = SocktainerComposeConformanceService(manifest: manifest).report()
    let volumes = try result("compose-named-volumes", in: report)

    #expect(volumes.status == .upstreamBlocked)
    #expect(volumes.missingOperations == ["Volume create"])
    #expect(volumes.summary.contains("Volume create"))
  }

  @Test
  func knownSemanticGapCannotBecomeSupportedFromRoutePresenceAlone() throws {
    let report = SocktainerComposeConformanceService().report()
    let health = try result("compose-healthchecks", in: report)

    #expect(health.missingOperations.isEmpty)
    #expect(health.status == .upstreamBlocked)
    #expect(health.summary.contains("health-check"))
  }

  private func result(
    _ id: String,
    in report: ComposeBridgeConformanceReport
  ) throws -> ComposeBridgeConformanceResult {
    try #require(report.results.first(where: { $0.id == id }))
  }
}
