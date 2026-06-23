import Foundation

protocol ActiveRuntimeConnectionVerifying: AnyObject, Sendable {
  func verifyActiveRuntimeForConnection() async throws
    -> NativeRuntimeVerifiedDistribution
}

actor VerifiedDualRuntimeSetupService:
  AppleContainerRuntimeSettingUp,
  ActiveRuntimeConnectionVerifying
{
  private let releaseContractLoader: any NativeRuntimeReleaseContractLoading
  private let distributionVerifier: any NativeRuntimeDistributionVerifying
  private let graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  private let graphClassifier: NativeRuntimeLaunchGraphClassifier
  private let officialStarter: any AppleContainerInstalledRuntimeStarting
  private let probe: any AppleContainerRuntimeProbing
  private var cachedDistribution: NativeRuntimeVerifiedDistribution?

  init(
    releaseContractLoader: any NativeRuntimeReleaseContractLoading =
      BundledNativeRuntimeReleaseContractLoader(),
    distributionVerifier: any NativeRuntimeDistributionVerifying =
      NativeRuntimeDistributionVerifier(),
    graphSnapshotter: (any NativeRuntimeLaunchGraphSnapshotting)? = nil,
    officialStarter: any AppleContainerInstalledRuntimeStarting =
      AppleContainerRuntimeSetupService(),
    probe: any AppleContainerRuntimeProbing = LiveAppleContainerRuntimeProbe()
  ) {
    let contractsByOrigin =
      NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin()
    let servicesByOrigin = contractsByOrigin.mapValues(\.services)
    self.releaseContractLoader = releaseContractLoader
    self.distributionVerifier = distributionVerifier
    self.graphSnapshotter =
      graphSnapshotter
      ?? LaunchctlNativeRuntimeGraphSnapshotter(
        servicesByOrigin: servicesByOrigin
      )
    graphClassifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contractsByOrigin
    )
    self.officialStarter = officialStarter
    self.probe = probe
  }

  func verifyActiveRuntimeForConnection() async throws
    -> NativeRuntimeVerifiedDistribution
  {
    let state: NativeRuntimeLaunchGraphState
    do {
      state = try await currentState()
    } catch {
      cachedDistribution = nil
      throw error
    }
    guard case .active(let origin) = state else {
      cachedDistribution = nil
      throw NativeRuntimeConnectionError.inactive
    }
    return try await verifyDistribution(
      origin: origin,
      allowCached: true
    )
  }

  func start() async throws {
    let state: NativeRuntimeLaunchGraphState
    do {
      state = try await currentState()
    } catch {
      cachedDistribution = nil
      throw error
    }

    switch state {
    case .active(let origin):
      _ = try await verifyDistribution(
        origin: origin,
        allowCached: true
      )
      try await probeVerifiedRuntime()

    case .inactive:
      cachedDistribution = nil
      let official = officialManifest()
      _ = try await distributionVerifier.verify(official)
      try await officialStarter.startInstalledRuntime()
      guard try await currentState() == .active(.appleOfficial) else {
        throw NativeRuntimeActivationError.graphDidNotStart(.appleOfficial)
      }
      let verified = try await distributionVerifier.verify(official)
      try requireMatch(verified, manifest: official)
      cachedDistribution = verified
      try await probeVerifiedRuntime()
    }
  }

  private func verifyDistribution(
    origin: NativeRuntimeOrigin,
    allowCached: Bool
  ) async throws -> NativeRuntimeVerifiedDistribution {
    if allowCached, let cachedDistribution,
      cachedDistribution.origin == origin
    {
      return cachedDistribution
    }
    cachedDistribution = nil
    let manifest: NativeRuntimeDistributionManifest
    switch origin {
    case .appleOfficial:
      manifest = officialManifest()
    case .nativeContainers:
      manifest = try nativeManifest()
    }
    let verified = try await distributionVerifier.verify(manifest)
    try requireMatch(verified, manifest: manifest)
    cachedDistribution = verified
    return verified
  }

  private func requireMatch(
    _ verified: NativeRuntimeVerifiedDistribution,
    manifest: NativeRuntimeDistributionManifest
  ) throws {
    guard
      verified.origin == manifest.origin,
      verified.packageIdentifier == manifest.packageIdentifier,
      verified.version == manifest.packageVersion,
      verified.installRootURL.standardizedFileURL
        == manifest.installRootURL.standardizedFileURL,
      verified.builderArtifact == manifest.builderArtifact
    else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The verified runtime result does not match its production manifest."
      )
    }
  }

  private func currentState() async throws -> NativeRuntimeLaunchGraphState {
    try graphClassifier.classify(
      try await graphSnapshotter.snapshot()
    )
  }

  private func officialManifest() -> NativeRuntimeDistributionManifest {
    NativeRuntimeProductionContractFactory.officialManifest()
  }

  private func nativeManifest() throws -> NativeRuntimeDistributionManifest {
    NativeRuntimeProductionContractFactory.nativeManifest(
      signedBinaryDigests:
        try releaseContractLoader.loadSignedBinaryDigests()
    )
  }

  private func probeVerifiedRuntime() async throws {
    do {
      let observation = try await probe.probe()
      guard
        observation.version == AppleContainerRuntimeSetupService.requiredVersion
      else {
        throw AppleContainerRuntimeSetupError.incompatibleVersion(
          found: observation.version,
          required: AppleContainerRuntimeSetupService.requiredVersion
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleContainerRuntimeSetupError {
      throw error
    } catch {
      throw AppleContainerRuntimeSetupError.verificationFailed(
        error.localizedDescription
      )
    }
  }
}
