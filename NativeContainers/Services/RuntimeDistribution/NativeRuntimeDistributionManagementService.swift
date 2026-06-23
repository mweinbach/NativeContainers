import Foundation

enum NativeRuntimeManagedGraphStatus: Equatable, Sendable {
  case inactive
  case active(NativeRuntimeOrigin)
  case unsafe(String)

  var activeOrigin: NativeRuntimeOrigin? {
    guard case .active(let origin) = self else { return nil }
    return origin
  }

  var isSafe: Bool {
    if case .unsafe = self { return false }
    return true
  }
}

enum NativeRuntimeDistributionAvailability: Equatable, Sendable {
  case verified(version: String)
  case unavailable(String)

  var isVerified: Bool {
    if case .verified = self { return true }
    return false
  }
}

enum NativeRuntimeMigrationCompletionState: Equatable, Sendable {
  case notCompleted
  case completed(fingerprint: String)
  case unavailable(String)
}

struct NativeRuntimeDistributionStatus: Equatable, Sendable {
  let graph: NativeRuntimeManagedGraphStatus
  let appleOfficial: NativeRuntimeDistributionAvailability
  let nativeContainers: NativeRuntimeDistributionAvailability
  let migration: NativeRuntimeMigrationCompletionState
}

enum NativeRuntimeDistributionManagementError:
  LocalizedError,
  Equatable,
  Sendable
{
  case nativeReleaseUnavailable(String)
  case verifiedDistributionMismatch(NativeRuntimeOrigin)
  case cloneRequiresActiveOfficialRuntime
  case cloneAndActivationFailed(String)
  case rollbackFailed(operation: String, rollback: String)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .nativeReleaseUnavailable(let detail):
      "NativeContainers runtime actions are unavailable because this app does not contain a valid signed runtime release contract. \(detail)"
    case .verifiedDistributionMismatch(let origin):
      "The verified \(origin.rawValue) distribution did not match its exact production contract."
    case .cloneRequiresActiveOfficialRuntime:
      "The one-time data clone requires the verified Apple runtime to be active before it can be stopped safely."
    case .cloneAndActivationFailed(let detail):
      "The NativeContainers data clone or activation failed. The verified Apple runtime was restored. \(detail)"
    case .rollbackFailed(let operation, let rollback):
      "The NativeContainers runtime operation failed (\(operation)) and the Apple runtime could not be restored safely (\(rollback))."
    case .unavailable:
      "Runtime distribution management is unavailable."
    }
  }
}

protocol NativeRuntimeDistributionManaging: Sendable {
  func status() async -> NativeRuntimeDistributionStatus
  func activateAppleRuntime() async throws -> NativeRuntimeDistributionStatus
  func activateNativeRuntime() async throws -> NativeRuntimeDistributionStatus
  func cloneAppleDataAndActivateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
}

protocol NativeRuntimeMigrating: Sendable {
  func completionState(
    _ layout: NativeRuntimeMigrationLayout
  ) async throws -> NativeRuntimeMigrationCompletionState

  func migrate(
    _ layout: NativeRuntimeMigrationLayout
  ) async throws -> NativeRuntimeMigrationResult
}

extension NativeRuntimeMigrationService: NativeRuntimeMigrating {}

struct NativeRuntimeDistributionManagementService:
  NativeRuntimeDistributionManaging,
  Sendable
{
  private let releaseContractLoader: any NativeRuntimeReleaseContractLoading
  private let distributionVerifier: any NativeRuntimeDistributionVerifying
  private let graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  private let graphClassifier: NativeRuntimeLaunchGraphClassifier
  private let graphController: any NativeRuntimeGraphControlling
  private let migrator: any NativeRuntimeMigrating
  private let migrationLayout: NativeRuntimeMigrationLayout
  private let mutationCoordinator: RuntimeMutationCoordinator

  init(
    releaseContractLoader: any NativeRuntimeReleaseContractLoading,
    distributionVerifier: any NativeRuntimeDistributionVerifying,
    graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting,
    graphController: any NativeRuntimeGraphControlling,
    migrator: any NativeRuntimeMigrating,
    migrationLayout: NativeRuntimeMigrationLayout,
    contractsByOrigin: [NativeRuntimeOrigin: NativeRuntimeLaunchGraphContract],
    mutationCoordinator: RuntimeMutationCoordinator = RuntimeMutationCoordinator()
  ) {
    self.releaseContractLoader = releaseContractLoader
    self.distributionVerifier = distributionVerifier
    self.graphSnapshotter = graphSnapshotter
    graphClassifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contractsByOrigin
    )
    self.graphController = graphController
    self.migrator = migrator
    self.migrationLayout = migrationLayout
    self.mutationCoordinator = mutationCoordinator
  }

  func status() async -> NativeRuntimeDistributionStatus {
    do {
      return try await mutationCoordinator.perform { [self] in
        await statusUnlocked()
      }
    } catch {
      let reason = error.localizedDescription
      return NativeRuntimeDistributionStatus(
        graph: .unsafe(reason),
        appleOfficial: .unavailable(reason),
        nativeContainers: .unavailable(reason),
        migration: .unavailable(reason)
      )
    }
  }

  func activateAppleRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    try await mutationCoordinator.perform { [self] in
      let official = NativeRuntimeProductionContractFactory.officialManifest()
      _ = try await verifyExact(official)
      let initial = try await currentState()

      var manifests = [official]
      if initial == .active(.nativeContainers) {
        let native = try nativeManifest()
        _ = try await verifyExact(native)
        manifests.append(native)
      }

      let coordinator = NativeRuntimeActivationCoordinator(
        manifests: manifests,
        distributionVerifier: distributionVerifier,
        graphSnapshotter: graphSnapshotter,
        graphController: graphController
      )
      try await coordinator.activate(.appleOfficial)
      _ = try await verifyExact(official)
      return await statusUnlocked()
    }
  }

  func activateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    try await mutationCoordinator.perform { [self] in
      let manifests = try await verifiedProductionManifests()
      let coordinator = NativeRuntimeActivationCoordinator(
        manifests: manifests,
        distributionVerifier: distributionVerifier,
        graphSnapshotter: graphSnapshotter,
        graphController: graphController
      )
      try await coordinator.activate(.nativeContainers)
      guard let native = manifests.first(where: { $0.origin == .nativeContainers }) else {
        throw NativeRuntimeDistributionManagementError.nativeReleaseUnavailable(
          "The exact NativeContainers manifest could not be constructed."
        )
      }
      _ = try await verifyExact(native)
      return await statusUnlocked()
    }
  }

  func cloneAppleDataAndActivateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    try await mutationCoordinator.perform { [self] in
      let manifests = try await verifiedProductionManifests()
      guard
        let official = manifests.first(where: { $0.origin == .appleOfficial }),
        let native = manifests.first(where: { $0.origin == .nativeContainers })
      else {
        throw NativeRuntimeDistributionManagementError.nativeReleaseUnavailable(
          "The exact runtime manifests could not be constructed."
        )
      }
      guard try await currentState() == .active(.appleOfficial) else {
        throw NativeRuntimeDistributionManagementError
          .cloneRequiresActiveOfficialRuntime
      }

      var attemptedNativeStart = false
      do {
        try await graphController.stop(.appleOfficial)
        guard try await currentState() == .inactive else {
          throw NativeRuntimeActivationError.graphDidNotStop(.appleOfficial)
        }

        _ = try await migrator.migrate(migrationLayout)
        guard try await currentState() == .inactive else {
          throw NativeRuntimeMigrationError.runtimeActive
        }

        attemptedNativeStart = true
        try await graphController.start(.nativeContainers)
        guard try await currentState() == .active(.nativeContainers) else {
          throw NativeRuntimeActivationError.graphDidNotStart(.nativeContainers)
        }
        _ = try await verifyExact(native)
        return await statusUnlocked()
      } catch {
        let operationDetail = error.localizedDescription
        do {
          try await restoreOfficialRuntime(
            official: official,
            native: native,
            stopNativeFirst: attemptedNativeStart
          )
        } catch {
          throw NativeRuntimeDistributionManagementError.rollbackFailed(
            operation: operationDetail,
            rollback: error.localizedDescription
          )
        }
        if error is CancellationError {
          throw CancellationError()
        }
        throw
          NativeRuntimeDistributionManagementError
          .cloneAndActivationFailed(operationDetail)
      }
    }
  }

  private func verifiedProductionManifests() async throws
    -> [NativeRuntimeDistributionManifest]
  {
    let official = NativeRuntimeProductionContractFactory.officialManifest()
    let native = try nativeManifest()
    _ = try await verifyExact(official)
    _ = try await verifyExact(native)
    return [official, native]
  }

  private func nativeManifest() throws -> NativeRuntimeDistributionManifest {
    do {
      return NativeRuntimeProductionContractFactory.nativeManifest(
        signedBinaryDigests:
          try releaseContractLoader.loadSignedBinaryDigests()
      )
    } catch {
      throw NativeRuntimeDistributionManagementError.nativeReleaseUnavailable(
        error.localizedDescription
      )
    }
  }

  private func verifyExact(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution {
    let verified = try await distributionVerifier.verify(manifest)
    guard
      verified.origin == manifest.origin,
      verified.packageIdentifier == manifest.packageIdentifier,
      verified.version == manifest.packageVersion,
      verified.installRootURL.standardizedFileURL
        == manifest.installRootURL.standardizedFileURL,
      verified.builderArtifact == manifest.builderArtifact
    else {
      throw
        NativeRuntimeDistributionManagementError
        .verifiedDistributionMismatch(manifest.origin)
    }
    return verified
  }

  private func currentState() async throws -> NativeRuntimeLaunchGraphState {
    try graphClassifier.classify(
      try await graphSnapshotter.snapshot()
    )
  }

  private func restoreOfficialRuntime(
    official: NativeRuntimeDistributionManifest,
    native: NativeRuntimeDistributionManifest,
    stopNativeFirst: Bool
  ) async throws {
    if stopNativeFirst {
      try await graphController.stop(.nativeContainers)
      guard try await currentState() == .inactive else {
        throw
          NativeRuntimeActivationError
          .graphDidNotStop(.nativeContainers)
      }
    } else {
      switch try await currentState() {
      case .active(.appleOfficial):
        _ = try await verifyExact(official)
        return

      case .active(.nativeContainers):
        _ = try await verifyExact(native)
        try await graphController.stop(.nativeContainers)
        guard try await currentState() == .inactive else {
          throw
            NativeRuntimeActivationError
            .graphDidNotStop(.nativeContainers)
        }

      case .inactive:
        break
      }
    }

    _ = try await verifyExact(official)
    try await graphController.start(.appleOfficial)
    guard try await currentState() == .active(.appleOfficial) else {
      throw
        NativeRuntimeActivationError
        .graphDidNotStart(.appleOfficial)
    }
    _ = try await verifyExact(official)
  }

  private func statusUnlocked() async -> NativeRuntimeDistributionStatus {
    let graph: NativeRuntimeManagedGraphStatus
    do {
      switch try await currentState() {
      case .inactive:
        graph = .inactive
      case .active(let origin):
        graph = .active(origin)
      }
    } catch {
      graph = .unsafe(error.localizedDescription)
    }

    let official = NativeRuntimeProductionContractFactory.officialManifest()
    let officialAvailability = await availability(for: official)

    let nativeAvailability: NativeRuntimeDistributionAvailability
    do {
      nativeAvailability = await availability(for: try nativeManifest())
    } catch {
      nativeAvailability = .unavailable(error.localizedDescription)
    }

    let migration: NativeRuntimeMigrationCompletionState
    do {
      migration = try await migrator.completionState(migrationLayout)
    } catch {
      migration = .unavailable(error.localizedDescription)
    }

    return NativeRuntimeDistributionStatus(
      graph: graph,
      appleOfficial: officialAvailability,
      nativeContainers: nativeAvailability,
      migration: migration
    )
  }

  private func availability(
    for manifest: NativeRuntimeDistributionManifest
  ) async -> NativeRuntimeDistributionAvailability {
    do {
      let verified = try await verifyExact(manifest)
      return .verified(version: verified.version)
    } catch {
      return .unavailable(error.localizedDescription)
    }
  }
}

struct UnavailableNativeRuntimeDistributionManagementService:
  NativeRuntimeDistributionManaging
{
  func status() async -> NativeRuntimeDistributionStatus {
    NativeRuntimeDistributionStatus(
      graph: .unsafe(
        NativeRuntimeDistributionManagementError.unavailable.localizedDescription
      ),
      appleOfficial: .unavailable(
        NativeRuntimeDistributionManagementError.unavailable.localizedDescription
      ),
      nativeContainers: .unavailable(
        NativeRuntimeDistributionManagementError.unavailable.localizedDescription
      ),
      migration: .unavailable(
        NativeRuntimeDistributionManagementError.unavailable.localizedDescription
      )
    )
  }

  func activateAppleRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    throw NativeRuntimeDistributionManagementError.unavailable
  }

  func activateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    throw NativeRuntimeDistributionManagementError.unavailable
  }

  func cloneAppleDataAndActivateNativeRuntime() async throws
    -> NativeRuntimeDistributionStatus
  {
    throw NativeRuntimeDistributionManagementError.unavailable
  }
}
