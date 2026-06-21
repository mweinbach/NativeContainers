import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation

struct AppleImageTransferService: Sendable {
  private let policy: AppleImagePolicy

  init(policy: AppleImagePolicy) {
    self.policy = policy
  }

  func preparePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    let reference = try policy.validatedReference(reference)
    guard (1...16).contains(maxConcurrentDownloads) else {
      throw ImageManagementError.invalidConcurrentDownloads
    }
    let configuration = try await policy.loadSystemConfiguration()
    let normalizedReference = try ClientImage.normalizeReference(
      reference,
      containerSystemConfig: configuration
    )
    try policy.ensureUserManaged(reference: normalizedReference, configuration: configuration)
    let resolvedPlatform = try policy.resolvePlatform(platform)
    let registry = try policy.resolveRegistryTransport(
      reference: normalizedReference,
      requestedTransport: transport,
      configuration: configuration
    )
    let existingDigest = try await ClientImage.list().first {
      $0.reference == normalizedReference
    }?.digest
    return ImagePullPlan(
      normalizedReference: normalizedReference,
      registryHost: registry.hostname,
      existingDigest: existingDigest,
      platform: resolvedPlatform.scope,
      requestedTransport: transport,
      resolvedTransport: registry.transport,
      unpackAfterPull: unpackAfterPull,
      maxConcurrentDownloads: maxConcurrentDownloads,
      generatedAt: Date()
    )
  }

  func pull(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    let configuration = try await policy.loadSystemConfiguration()
    try policy.ensureUserManaged(
      reference: plan.normalizedReference,
      configuration: configuration
    )
    let registry = try policy.resolveRegistryTransport(
      reference: plan.normalizedReference,
      requestedTransport: plan.requestedTransport,
      configuration: configuration
    )
    let currentDigest = try await ClientImage.list().first {
      $0.reference == plan.normalizedReference
    }?.digest
    try ImageTransferExecutionSafety.validatePull(
      plan: plan,
      authorization: authorization,
      resolvedRegistryHost: registry.hostname,
      resolvedTransport: registry.transport,
      currentDigest: currentDigest,
      isInfrastructureImage: policy.isInfrastructureReference(
        plan.normalizedReference,
        configuration: configuration
      )
    )

    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .fetchingImage, message: "Fetching image")
    let applePlatform = try policy.applePlatform(for: plan.platform)
    try Task.checkCancellation()
    let image = try await ClientImage.pull(
      reference: plan.normalizedReference,
      platform: applePlatform,
      scheme: try RequestScheme(plan.resolvedTransport.rawValue),
      containerSystemConfig: configuration,
      progressUpdate: { events in
        await relay.consume(events)
      },
      maxConcurrentDownloads: plan.maxConcurrentDownloads
    )
    var result = ImagePullResult(
      reference: image.reference,
      digest: image.digest,
      replacedDigest: plan.existingDigest,
      unpackOutcome: nil
    )

    do {
      try Task.checkCancellation()
      let platforms = try await policy.transferPlatforms(
        for: plan.platform,
        in: image,
        requireAllPlatforms: plan.unpackAfterPull
      )
      if plan.unpackAfterPull {
        var outcomes: [ImagePlatformUnpackOutcome] = []
        for platform in platforms {
          let platformValue = AppleImagePolicy.platformValue(platform)
          do {
            try Task.checkCancellation()
            await relay.emit(
              phase: .unpackingImage,
              message: "Preparing \(platform.description) snapshot"
            )
            let state: ImagePlatformUnpackState
            do {
              _ = try await image.getSnapshot(platform: platform)
              state = .alreadyPresent
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              try Task.checkCancellation()
              _ = try await image.getCreateSnapshot(platform: platform) { events in
                await relay.consume(events)
              }
              state = .created
            }
            outcomes.append(
              ImagePlatformUnpackOutcome(platform: platformValue, state: state)
            )
          } catch is CancellationError {
            result = ImagePullResult(
              reference: image.reference,
              digest: image.digest,
              replacedDigest: plan.existingDigest,
              unpackOutcome: ImageUnpackOutcome(platforms: outcomes)
            )
            throw ImagePullPartialCompletionError(
              result: result,
              stage: .unpacking,
              failureMessage: "Snapshot preparation was cancelled.",
              wasCancelled: true
            )
          } catch {
            outcomes.append(
              ImagePlatformUnpackOutcome(
                platform: platformValue,
                state: .failed(error.localizedDescription)
              )
            )
          }
        }

        let unpackOutcome = ImageUnpackOutcome(platforms: outcomes)
        result = ImagePullResult(
          reference: image.reference,
          digest: image.digest,
          replacedDigest: plan.existingDigest,
          unpackOutcome: unpackOutcome
        )
        guard unpackOutcome.isComplete else {
          let failures = outcomes.compactMap { outcome -> String? in
            guard case .failed(let message) = outcome.state else { return nil }
            return "\(outcome.platform.description): \(message)"
          }
          throw ImagePullPartialCompletionError(
            result: result,
            stage: .unpacking,
            failureMessage: failures.joined(separator: "; "),
            wasCancelled: false
          )
        }
      }
    } catch let error as ImagePullPartialCompletionError {
      throw error
    } catch is CancellationError {
      throw ImagePullPartialCompletionError(
        result: result,
        stage: .validatingPlatform,
        failureMessage: "Validation was cancelled.",
        wasCancelled: true
      )
    } catch {
      throw ImagePullPartialCompletionError(
        result: result,
        stage: .validatingPlatform,
        failureMessage: error.localizedDescription,
        wasCancelled: false
      )
    }

    await relay.emit(phase: .completed, message: "Image ready")
    return result
  }

  func preparePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    let reference = try policy.validatedReference(reference)
    let configuration = try await policy.loadSystemConfiguration()
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    try policy.ensureUserManaged(image, configuration: configuration)
    let resolvedPlatform = try policy.resolvePlatform(platform)
    if let applePlatform = resolvedPlatform.platform {
      try await policy.validatePlatform(applePlatform, in: image)
    }
    let registry = try policy.resolveRegistryTransport(
      reference: image.reference,
      requestedTransport: transport,
      configuration: configuration
    )
    return ImagePushPlan(
      reference: image.reference,
      displayReference: try ClientImage.denormalizeReference(
        image.reference,
        containerSystemConfig: configuration
      ),
      sourceDigest: image.digest,
      registryHost: registry.hostname,
      platform: resolvedPlatform.scope,
      requestedTransport: transport,
      resolvedTransport: registry.transport,
      generatedAt: Date()
    )
  }

  func push(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let configuration = try await policy.loadSystemConfiguration()
    let registry = try policy.resolveRegistryTransport(
      reference: plan.reference,
      requestedTransport: plan.requestedTransport,
      configuration: configuration
    )
    let image = try await ClientImage.get(
      reference: plan.reference,
      containerSystemConfig: configuration
    )
    try policy.ensureUserManaged(image, configuration: configuration)
    try ImageTransferExecutionSafety.validatePush(
      plan: plan,
      authorization: authorization,
      resolvedRegistryHost: registry.hostname,
      resolvedTransport: registry.transport,
      currentDigest: image.digest,
      isInfrastructureImage: policy.isInfrastructureReference(
        image.reference,
        configuration: configuration
      )
    )
    let applePlatform = try policy.applePlatform(for: plan.platform)
    if let applePlatform {
      try await policy.validatePlatform(applePlatform, in: image)
    }

    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .pushingImage, message: "Pushing image")
    try Task.checkCancellation()
    try await image.push(
      platform: applePlatform,
      scheme: try RequestScheme(plan.resolvedTransport.rawValue),
      containerSystemConfig: configuration
    ) { events in
      await relay.consume(events)
    }
    await relay.emit(phase: .completed, message: "Image pushed")
  }
}
