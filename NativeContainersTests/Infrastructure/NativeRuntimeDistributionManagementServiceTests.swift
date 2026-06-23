import Foundation
import Testing

@testable import NativeContainers

@Suite("Runtime distribution management", .serialized)
struct NativeRuntimeDistributionManagementServiceTests {
  @Test
  func cloneFlowStopsAppleMigratesThenStartsNative() async throws {
    let events = RuntimeManagementEventLog()
    let snapshots = RuntimeManagementSnapshotDouble([
      runtimeObservations(.appleOfficial),
      [],
      [],
      runtimeObservations(.nativeContainers),
      runtimeObservations(.nativeContainers),
    ])
    let controller = RuntimeManagementGraphControllerDouble(events: events)
    let migrator = RuntimeManagementMigratorDouble(
      events: events,
      migrationResult: .migrated(fingerprint: fingerprint("1")),
      completion: .completed(fingerprint: fingerprint("1"))
    )
    let service = makeManagementService(
      snapshots: snapshots,
      controller: controller,
      migrator: migrator
    )

    let status =
      try await service.cloneAppleDataAndActivateNativeRuntime()

    #expect(status.graph == .active(.nativeContainers))
    #expect(
      await events.values.filter {
        $0 == "stop:appleOfficial"
          || $0 == "migrate"
          || $0 == "start:nativeContainers"
      } == [
        "stop:appleOfficial",
        "migrate",
        "start:nativeContainers",
      ]
    )
  }

  @Test
  func cloneFlowRestartsVerifiedAppleRuntimeWhenNativeStartFails() async {
    let events = RuntimeManagementEventLog()
    let snapshots = RuntimeManagementSnapshotDouble([
      runtimeObservations(.appleOfficial),
      [],
      [],
      [],
      runtimeObservations(.appleOfficial),
    ])
    let controller = RuntimeManagementGraphControllerDouble(
      events: events,
      failingOperation: "start:nativeContainers"
    )
    let migrator = RuntimeManagementMigratorDouble(
      events: events,
      migrationResult: .migrated(fingerprint: fingerprint("2")),
      completion: .completed(fingerprint: fingerprint("2"))
    )
    let verifier = RuntimeManagementDistributionVerifierDouble(events: events)
    let service = makeManagementService(
      verifier: verifier,
      snapshots: snapshots,
      controller: controller,
      migrator: migrator
    )

    await #expect(
      throws: NativeRuntimeDistributionManagementError.self
    ) {
      _ = try await service.cloneAppleDataAndActivateNativeRuntime()
    }

    #expect(
      await events.values.filter {
        $0.hasPrefix("start:") || $0.hasPrefix("stop:") || $0 == "migrate"
      } == [
        "stop:appleOfficial",
        "migrate",
        "start:nativeContainers",
        "stop:nativeContainers",
        "start:appleOfficial",
      ]
    )
    #expect(
      await verifier.verifiedOrigins.suffix(2)
        == [.appleOfficial, .appleOfficial]
    )
  }

  @Test
  func unknownOrMixedGraphRefusesBeforeAnyMutation() async {
    let events = RuntimeManagementEventLog()
    let mixed = [
      runtimeObservations(.appleOfficial)[0],
      runtimeObservations(.nativeContainers)[0],
    ]
    let snapshots = RuntimeManagementSnapshotDouble([mixed])
    let controller = RuntimeManagementGraphControllerDouble(events: events)
    let migrator = RuntimeManagementMigratorDouble(
      events: events,
      migrationResult: .migrated(fingerprint: fingerprint("3")),
      completion: .notCompleted
    )
    let service = makeManagementService(
      snapshots: snapshots,
      controller: controller,
      migrator: migrator
    )

    await #expect(throws: NativeRuntimeLaunchGraphError.self) {
      _ = try await service.cloneAppleDataAndActivateNativeRuntime()
    }

    #expect(await events.values.isEmpty)
  }

  @Test
  func completedMigrationIsIdempotentAndStillActivatesNative() async throws {
    let events = RuntimeManagementEventLog()
    let completedFingerprint = fingerprint("4")
    let snapshots = RuntimeManagementSnapshotDouble([
      runtimeObservations(.appleOfficial),
      [],
      [],
      runtimeObservations(.nativeContainers),
      runtimeObservations(.nativeContainers),
    ])
    let controller = RuntimeManagementGraphControllerDouble(events: events)
    let migrator = RuntimeManagementMigratorDouble(
      events: events,
      migrationResult: .alreadyCompleted(
        fingerprint: completedFingerprint
      ),
      completion: .completed(fingerprint: completedFingerprint)
    )
    let service = makeManagementService(
      snapshots: snapshots,
      controller: controller,
      migrator: migrator
    )

    let status =
      try await service.cloneAppleDataAndActivateNativeRuntime()

    #expect(status.graph == .active(.nativeContainers))
    #expect(
      status.migration
        == .completed(fingerprint: completedFingerprint)
    )
    #expect(await migrator.migrationCallCount == 1)
  }

  @Test
  func placeholderReleaseContractBlocksNativeButLeavesAppleUsable() async throws {
    let events = RuntimeManagementEventLog()
    let snapshots = RuntimeManagementSnapshotDouble([
      [],
      [],
      runtimeObservations(.appleOfficial),
      runtimeObservations(.appleOfficial),
    ])
    let controller = RuntimeManagementGraphControllerDouble(events: events)
    let migrator = RuntimeManagementMigratorDouble(
      events: events,
      migrationResult: .migrated(fingerprint: fingerprint("5")),
      completion: .notCompleted
    )
    let service = makeManagementService(
      releaseContractLoader: FailingRuntimeReleaseContractLoader(),
      snapshots: snapshots,
      controller: controller,
      migrator: migrator
    )

    await #expect(
      throws: NativeRuntimeDistributionManagementError.self
    ) {
      _ = try await service.activateNativeRuntime()
    }
    let status = try await service.activateAppleRuntime()

    #expect(status.graph == .active(.appleOfficial))
    #expect(status.appleOfficial.isVerified)
    #expect(!status.nativeContainers.isVerified)
    #expect(await controller.operations == ["start:appleOfficial"])
  }

  @Test
  func productionControlCommandsCannotInstallOrElevate() {
    let commands = NativeRuntimeProductionContractFactory.controlCommands()

    #expect(Set(commands.keys) == Set(NativeRuntimeOrigin.allCases))
    for command in commands.values {
      let executable = command.executableURL.path.lowercased()
      let arguments = (command.startArguments + command.stopArguments)
        .joined(separator: " ")
        .lowercased()
      #expect(command.executableURL.lastPathComponent == "container")
      #expect(command.startArguments == ["system", "start"])
      #expect(command.stopArguments == ["system", "stop"])
      #expect(!executable.contains("installer"))
      #expect(!executable.contains("sudo"))
      #expect(!arguments.contains("install"))
      #expect(!arguments.contains("sudo"))
      #expect(!arguments.contains("delete"))
      #expect(!arguments.contains("remove"))
    }
  }

  @MainActor
  @Test
  func appModelExposesTheInjectedRuntimeManagementFacade() async {
    let facade = RuntimeManagementFacadeDouble()
    let appModel = AppModel(runtimeDistributionService: facade)
    let model = appModel.makeNativeRuntimeDistributionModel()

    await model.refresh()

    #expect(await facade.statusCallCount == 1)
    #expect(model.status?.graph == .inactive)
  }
}

private func makeManagementService(
  releaseContractLoader: any NativeRuntimeReleaseContractLoading =
    RuntimeReleaseContractLoaderDouble(),
  verifier: RuntimeManagementDistributionVerifierDouble =
    RuntimeManagementDistributionVerifierDouble(),
  snapshots: RuntimeManagementSnapshotDouble,
  controller: RuntimeManagementGraphControllerDouble,
  migrator: RuntimeManagementMigratorDouble
) -> NativeRuntimeDistributionManagementService {
  let contracts =
    NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin(
      userID: 501
    )
  return NativeRuntimeDistributionManagementService(
    releaseContractLoader: releaseContractLoader,
    distributionVerifier: verifier,
    graphSnapshotter: snapshots,
    graphController: controller,
    migrator: migrator,
    migrationLayout:
      NativeRuntimeProductionContractFactory.migrationLayout(
        homeDirectoryURL: URL(
          filePath: "/Users/runtime-management-test",
          directoryHint: .isDirectory
        )
      ),
    contractsByOrigin: contracts
  )
}

private func runtimeObservations(
  _ origin: NativeRuntimeOrigin
) -> [NativeRuntimeLaunchServiceObservation] {
  let contracts =
    NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin(
      userID: 501
    )
  return contracts[
    origin,
    default: NativeRuntimeLaunchGraphContract(
      services: [],
      requiredServices: []
    )
  ].services.map {
    NativeRuntimeLaunchServiceObservation(
      label: $0.label,
      domain: $0.domain,
      executableURL: $0.executableURL
    )
  }
}

private func fingerprint(_ character: Character) -> String {
  String(repeating: String(character), count: 64)
}

private struct RuntimeReleaseContractLoaderDouble:
  NativeRuntimeReleaseContractLoading
{
  func loadSignedBinaryDigests() throws
    -> NativeRuntimeSignedBinaryDigestCatalog
  {
    try NativeRuntimeSignedBinaryDigestCatalog(
      container: fingerprint("a"),
      containerAPIServer: fingerprint("b"),
      containerRuntimeLinux: fingerprint("c"),
      containerNetworkVMNet: fingerprint("d"),
      containerCoreImages: fingerprint("e"),
      machineAPIServer: fingerprint("f")
    )
  }
}

private struct FailingRuntimeReleaseContractLoader:
  NativeRuntimeReleaseContractLoading
{
  func loadSignedBinaryDigests() throws
    -> NativeRuntimeSignedBinaryDigestCatalog
  {
    throw NativeRuntimeDistributionError.invalidManifest(
      "release packaging must replace the placeholder"
    )
  }
}

private actor RuntimeManagementEventLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor RuntimeManagementDistributionVerifierDouble:
  NativeRuntimeDistributionVerifying
{
  private let events: RuntimeManagementEventLog?
  private(set) var verifiedOrigins: [NativeRuntimeOrigin] = []

  init(events: RuntimeManagementEventLog? = nil) {
    self.events = events
  }

  func verify(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution {
    verifiedOrigins.append(manifest.origin)
    await events?.append("verify:\(manifest.origin.rawValue)")
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

private actor RuntimeManagementSnapshotDouble:
  NativeRuntimeLaunchGraphSnapshotting
{
  private var values: [[NativeRuntimeLaunchServiceObservation]]

  init(_ values: [[NativeRuntimeLaunchServiceObservation]]) {
    self.values = values
  }

  func snapshot() async throws -> [NativeRuntimeLaunchServiceObservation] {
    guard !values.isEmpty else {
      throw NativeRuntimeLaunchGraphError.inspectionFailed(
        "No runtime graph snapshot remains."
      )
    }
    return values.removeFirst()
  }
}

private actor RuntimeManagementGraphControllerDouble:
  NativeRuntimeGraphControlling
{
  private let events: RuntimeManagementEventLog
  private let failingOperation: String?
  private(set) var operations: [String] = []

  init(
    events: RuntimeManagementEventLog,
    failingOperation: String? = nil
  ) {
    self.events = events
    self.failingOperation = failingOperation
  }

  func start(_ origin: NativeRuntimeOrigin) async throws {
    try await record("start:\(origin.rawValue)")
  }

  func stop(_ origin: NativeRuntimeOrigin) async throws {
    try await record("stop:\(origin.rawValue)")
  }

  private func record(_ operation: String) async throws {
    operations.append(operation)
    await events.append(operation)
    if operation == failingOperation {
      throw RuntimeManagementTestError.configuredFailure
    }
  }
}

private actor RuntimeManagementMigratorDouble: NativeRuntimeMigrating {
  private let events: RuntimeManagementEventLog
  private let migrationResult: NativeRuntimeMigrationResult
  private let completion: NativeRuntimeMigrationCompletionState
  private(set) var migrationCallCount = 0

  init(
    events: RuntimeManagementEventLog,
    migrationResult: NativeRuntimeMigrationResult,
    completion: NativeRuntimeMigrationCompletionState
  ) {
    self.events = events
    self.migrationResult = migrationResult
    self.completion = completion
  }

  func completionState(
    _ layout: NativeRuntimeMigrationLayout
  ) async throws -> NativeRuntimeMigrationCompletionState {
    completion
  }

  func migrate(
    _ layout: NativeRuntimeMigrationLayout
  ) async throws -> NativeRuntimeMigrationResult {
    migrationCallCount += 1
    await events.append("migrate")
    return migrationResult
  }
}

private actor RuntimeManagementFacadeDouble:
  NativeRuntimeDistributionManaging
{
  private(set) var statusCallCount = 0

  func status() async -> NativeRuntimeDistributionStatus {
    statusCallCount += 1
    return NativeRuntimeDistributionStatus(
      graph: .inactive,
      appleOfficial: .verified(version: "test"),
      nativeContainers: .unavailable("test"),
      migration: .notCompleted
    )
  }

  func activateAppleRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    await status()
  }

  func activateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    await status()
  }

  func cloneAppleDataAndActivateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    await status()
  }
}

private enum RuntimeManagementTestError: Error {
  case configuredFailure
}
