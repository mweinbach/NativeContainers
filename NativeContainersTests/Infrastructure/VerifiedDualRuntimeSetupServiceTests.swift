import Foundation
import Testing

@testable import NativeContainers

@Suite("Verified dual-runtime setup", .serialized)
struct VerifiedDualRuntimeSetupServiceTests {
  @Test
  func officialGraphVerifiesDistributionBeforeHealthProbe() async throws {
    let events = RuntimeSetupEventRecorder()
    let loader = RuntimeSetupReleaseContractLoaderDouble()
    let distributions = RuntimeSetupDistributionVerifierDouble(events: events)
    let starter = RuntimeSetupInstalledRuntimeStarterDouble(events: events)
    let probe = RuntimeSetupVerifiedProbeDouble(events: events)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: loader,
      distributionVerifier: distributions,
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [observations(for: .appleOfficial)],
        events: events
      ),
      officialStarter: starter,
      probe: probe
    )

    try await service.start()

    #expect(
      await events.values
        == [
          "snapshot",
          "verify:appleOfficial",
          "probe",
        ]
    )
    #expect(loader.callCount == 0)
    #expect(await starter.callCount == 0)
  }

  @Test
  func connectionVerificationDoesNotProbeOrStartOfficialRuntime() async throws {
    let events = RuntimeSetupEventRecorder()
    let starter = RuntimeSetupInstalledRuntimeStarterDouble(events: events)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [observations(for: .appleOfficial)],
        events: events
      ),
      officialStarter: starter,
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    let verified = try await service.verifyActiveRuntimeForConnection()

    #expect(verified.origin == .appleOfficial)
    #expect(await events.values == ["snapshot", "verify:appleOfficial"])
    #expect(await starter.callCount == 0)
  }

  @Test
  func inactiveConnectionVerificationFailsWithoutStartingOrProbing() async {
    let events = RuntimeSetupEventRecorder()
    let starter = RuntimeSetupInstalledRuntimeStarterDouble(events: events)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [[]],
        events: events
      ),
      officialStarter: starter,
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    await #expect(throws: NativeRuntimeConnectionError.inactive) {
      _ = try await service.verifyActiveRuntimeForConnection()
    }

    #expect(await events.values == ["snapshot"])
    #expect(await starter.callCount == 0)
  }

  @Test
  func connectionVerificationCachesDistributionForStableOrigin() async throws {
    let events = RuntimeSetupEventRecorder()
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [
          observations(for: .appleOfficial),
          observations(for: .appleOfficial),
        ],
        events: events
      ),
      officialStarter: RuntimeSetupInstalledRuntimeStarterDouble(events: events),
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    _ = try await service.verifyActiveRuntimeForConnection()
    _ = try await service.verifyActiveRuntimeForConnection()

    #expect(
      await events.values
        == [
          "snapshot",
          "verify:appleOfficial",
          "snapshot",
        ]
    )
  }

  @Test
  func nativeGraphRequiresSignedCatalogAndExactDistributionBeforeProbe() async throws {
    let events = RuntimeSetupEventRecorder()
    let loader = RuntimeSetupReleaseContractLoaderDouble()
    let distributions = RuntimeSetupDistributionVerifierDouble(events: events)
    let starter = RuntimeSetupInstalledRuntimeStarterDouble(events: events)
    let probe = RuntimeSetupVerifiedProbeDouble(events: events)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: loader,
      distributionVerifier: distributions,
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [observations(for: .nativeContainers)],
        events: events
      ),
      officialStarter: starter,
      probe: probe
    )

    try await service.start()

    #expect(
      await events.values
        == [
          "snapshot",
          "verify:nativeContainers",
          "probe",
        ]
    )
    #expect(loader.callCount == 1)
    #expect(await starter.callCount == 0)
  }

  @Test
  func nativeGraphMissingSignedCatalogFailsBeforeDistributionOrProbe() async {
    let events = RuntimeSetupEventRecorder()
    let loader = RuntimeSetupReleaseContractLoaderDouble(shouldFail: true)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: loader,
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [observations(for: .nativeContainers)],
        events: events
      ),
      officialStarter: RuntimeSetupInstalledRuntimeStarterDouble(events: events),
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    await #expect(throws: NativeRuntimeDistributionError.self) {
      try await service.start()
    }

    #expect(await events.values == ["snapshot"])
    #expect(loader.callCount == 1)
  }

  @Test
  func inactiveGraphPreflightsStartsAndReverifiesBeforeFirstProbe() async throws {
    let events = RuntimeSetupEventRecorder()
    let loader = RuntimeSetupReleaseContractLoaderDouble()
    let distributions = RuntimeSetupDistributionVerifierDouble(events: events)
    let starter = RuntimeSetupInstalledRuntimeStarterDouble(events: events)
    let probe = RuntimeSetupVerifiedProbeDouble(events: events)
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: loader,
      distributionVerifier: distributions,
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [
          [],
          observations(for: .appleOfficial),
        ],
        events: events
      ),
      officialStarter: starter,
      probe: probe
    )

    try await service.start()

    #expect(
      await events.values
        == [
          "snapshot",
          "verify:appleOfficial",
          "start-official",
          "snapshot",
          "verify:appleOfficial",
          "probe",
        ]
    )
    #expect(loader.callCount == 0)
    #expect(await starter.callCount == 1)
  }

  @Test
  func mixedGraphFailsBeforePackageVerificationOrProbe() async {
    let events = RuntimeSetupEventRecorder()
    let services = NativeRuntimeProductionContractFactory.launchServicesByOrigin()
    let official = services[.appleOfficial]!
    let native = services[.nativeContainers]!
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [
          [
            observation(official[0]),
            observation(native[1]),
          ]
        ],
        events: events
      ),
      officialStarter: RuntimeSetupInstalledRuntimeStarterDouble(events: events),
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    await #expect(throws: NativeRuntimeLaunchGraphError.mixedOwners) {
      try await service.start()
    }

    #expect(await events.values == ["snapshot"])
  }

  @Test
  func unknownOwnerFailsBeforePackageVerificationOrProbe() async {
    let events = RuntimeSetupEventRecorder()
    let services = NativeRuntimeProductionContractFactory.launchServicesByOrigin()
    let official = services[.appleOfficial]!
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [
          [
            NativeRuntimeLaunchServiceObservation(
              label: official[0].label,
              domain: official[0].domain,
              executableURL: URL(filePath: "/tmp/unreviewed-container-apiserver")
            )
          ]
        ],
        events: events
      ),
      officialStarter: RuntimeSetupInstalledRuntimeStarterDouble(events: events),
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    await #expect(throws: NativeRuntimeLaunchGraphError.self) {
      try await service.start()
    }

    #expect(await events.values == ["snapshot"])
  }

  @Test
  func inactiveGraphRefusesUnexpectedNativeStartBeforeProbe() async {
    let events = RuntimeSetupEventRecorder()
    let service = VerifiedDualRuntimeSetupService(
      releaseContractLoader: RuntimeSetupReleaseContractLoaderDouble(),
      distributionVerifier: RuntimeSetupDistributionVerifierDouble(events: events),
      graphSnapshotter: RuntimeSetupGraphSnapshotterDouble(
        snapshots: [
          [],
          observations(for: .nativeContainers),
        ],
        events: events
      ),
      officialStarter: RuntimeSetupInstalledRuntimeStarterDouble(events: events),
      probe: RuntimeSetupVerifiedProbeDouble(events: events)
    )

    await #expect(
      throws: NativeRuntimeActivationError.graphDidNotStart(.appleOfficial)
    ) {
      try await service.start()
    }

    #expect(
      await events.values
        == [
          "snapshot",
          "verify:appleOfficial",
          "start-official",
          "snapshot",
        ]
    )
  }
}

private actor RuntimeSetupEventRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor RuntimeSetupGraphSnapshotterDouble:
  NativeRuntimeLaunchGraphSnapshotting
{
  private var snapshots: [[NativeRuntimeLaunchServiceObservation]]
  private let events: RuntimeSetupEventRecorder

  init(
    snapshots: [[NativeRuntimeLaunchServiceObservation]],
    events: RuntimeSetupEventRecorder
  ) {
    self.snapshots = snapshots
    self.events = events
  }

  func snapshot() async throws -> [NativeRuntimeLaunchServiceObservation] {
    await events.append("snapshot")
    guard !snapshots.isEmpty else {
      throw NativeRuntimeLaunchGraphError.inspectionFailed(
        "No test snapshot remains."
      )
    }
    return snapshots.removeFirst()
  }
}

private actor RuntimeSetupDistributionVerifierDouble:
  NativeRuntimeDistributionVerifying
{
  private let events: RuntimeSetupEventRecorder

  init(events: RuntimeSetupEventRecorder) {
    self.events = events
  }

  func verify(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution {
    await events.append("verify:\(manifest.origin.rawValue)")
    return NativeRuntimeVerifiedDistribution(
      origin: manifest.origin,
      packageIdentifier: manifest.packageIdentifier,
      version: manifest.packageVersion,
      installRootURL: manifest.installRootURL,
      builderArtifact: manifest.builderArtifact,
      serviceExecutablePaths: Dictionary(
        uniqueKeysWithValues: manifest.launchServices.map {
          ($0.label, $0.executableURL)
        }
      )
    )
  }
}

private actor RuntimeSetupInstalledRuntimeStarterDouble:
  AppleContainerInstalledRuntimeStarting
{
  private let events: RuntimeSetupEventRecorder
  private(set) var callCount = 0

  init(events: RuntimeSetupEventRecorder) {
    self.events = events
  }

  func startInstalledRuntime() async throws {
    callCount += 1
    await events.append("start-official")
  }
}

private struct RuntimeSetupVerifiedProbeDouble: AppleContainerRuntimeProbing {
  let events: RuntimeSetupEventRecorder

  func probe() async throws -> AppleContainerRuntimeObservation {
    await events.append("probe")
    return AppleContainerRuntimeObservation(
      version: AppleContainerRuntimeSetupService.requiredVersion
    )
  }
}

private final class RuntimeSetupReleaseContractLoaderDouble:
  NativeRuntimeReleaseContractLoading,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let shouldFail: Bool
  private var storedCallCount = 0

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  var callCount: Int {
    lock.withLock { storedCallCount }
  }

  func loadSignedBinaryDigests() throws
    -> NativeRuntimeSignedBinaryDigestCatalog
  {
    lock.withLock {
      storedCallCount += 1
    }
    if shouldFail {
      throw NativeRuntimeDistributionError.invalidManifest(
        "injected missing release contract"
      )
    }
    return try NativeRuntimeSignedBinaryDigestCatalog(
      container: String(repeating: "a", count: 64),
      containerAPIServer: String(repeating: "b", count: 64),
      containerRuntimeLinux: String(repeating: "c", count: 64),
      containerNetworkVMNet: String(repeating: "d", count: 64),
      containerCoreImages: String(repeating: "e", count: 64),
      machineAPIServer: String(repeating: "f", count: 64)
    )
  }
}

private func observations(
  for origin: NativeRuntimeOrigin
) -> [NativeRuntimeLaunchServiceObservation] {
  NativeRuntimeProductionContractFactory.launchServicesByOrigin()[origin]!
    .map(observation)
}

private func observation(
  _ service: NativeRuntimeLaunchServiceContract
) -> NativeRuntimeLaunchServiceObservation {
  NativeRuntimeLaunchServiceObservation(
    label: service.label,
    domain: service.domain,
    executableURL: service.executableURL
  )
}
