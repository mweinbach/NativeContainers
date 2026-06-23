import Foundation
import Testing

@testable import NativeContainers

@Suite("Live native runtime distribution", .serialized)
struct LiveNativeRuntimeDistributionTests {
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_RUNTIME_DISTRIBUTION"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_RUNTIME_DISTRIBUTION=1 with the official Apple 1.0 runtime active."
    )
  )
  func activeOfficialRuntimeMatchesPinnedDistributionBeforeConnection() async throws {
    let contracts =
      NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin()
    let snapshotter = LaunchctlNativeRuntimeGraphSnapshotter(
      servicesByOrigin: contracts.mapValues(\.services)
    )
    let classifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contracts
    )
    let state = try classifier.classify(
      try await snapshotter.snapshot()
    )
    guard state == .active(.appleOfficial) else {
      Issue.record(
        "The read-only gate requires the complete official Apple runtime graph to be active; observed \(state)."
      )
      return
    }

    let manifest = NativeRuntimeProductionContractFactory.officialManifest()
    let verified = try await NativeRuntimeDistributionVerifier().verify(
      manifest
    )
    #expect(verified.origin == .appleOfficial)
    #expect(verified.version == "1.0.0")
    #expect(verified.installRootURL.path == "/usr/local")
    #expect(
      Set(verified.serviceExecutablePaths.keys)
        == Set(manifest.launchServices.map(\.label))
    )

    // The production inventory and setup paths share this verifier. The state
    // guard above prevents either read-only operation from starting or switching
    // a runtime.
    let runtime = VerifiedDualRuntimeSetupService()
    let inventory = try await VerifiedRuntimeInventoryService(
      base: AppleRuntimeInventoryService(),
      runtimeVerifier: runtime
    ).loadInventory()
    #expect(inventory.system.version.contains("1.0.0"))
    try await runtime.start()
  }
}
