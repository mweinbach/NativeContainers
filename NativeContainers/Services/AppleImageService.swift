import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation

actor AppleImageService: ImageManaging {
  private let containerReader: any ContainerSnapshotReading
  private let pruneTransport: any ImagePruneTransport
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    containerReader: any ContainerSnapshotReading = AppleContainerSnapshotReader(),
    pruneTransport: any ImagePruneTransport = AppleImagePruneClient(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.containerReader = containerReader
    self.pruneTransport = pruneTransport
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    let reference = try validatedImageReference(reference)
    guard (1...16).contains(maxConcurrentDownloads) else {
      throw ImageManagementError.invalidConcurrentDownloads
    }
    let configuration = try await loadSystemConfiguration()
    let normalizedReference = try ClientImage.normalizeReference(
      reference,
      containerSystemConfig: configuration
    )
    try ensureUserManaged(reference: normalizedReference, configuration: configuration)
    let resolvedPlatform = try resolvePlatform(platform)
    let registry = try resolveRegistryTransport(
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

  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    try await withRuntimeMutation {
      try await self.pullImageWhileLocked(
        plan,
        authorization: authorization,
        progress: progress
      )
    }
  }

  private func pullImageWhileLocked(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    let configuration = try await loadSystemConfiguration()
    try ensureUserManaged(reference: plan.normalizedReference, configuration: configuration)
    let registry = try resolveRegistryTransport(
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
      isInfrastructureImage: isInfrastructureReference(
        plan.normalizedReference,
        configuration: configuration
      )
    )

    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .fetchingImage, message: "Fetching image")
    let applePlatform = try applePlatform(for: plan.platform)
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
      let platforms = try await transferPlatforms(
        for: plan.platform,
        in: image,
        requireAllPlatforms: plan.unpackAfterPull
      )
      if plan.unpackAfterPull {
        var outcomes: [ImagePlatformUnpackOutcome] = []
        for platform in platforms {
          let platformValue = Self.platformValue(platform)
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

  func inspectImage(reference: String) async throws -> ImageInspection {
    let reference = try validatedImageReference(reference)
    async let configurationRequest = loadSystemConfiguration()
    async let allImagesRequest = ClientImage.list()
    async let containersRequest = containerReader.list()

    let configuration = try await configurationRequest
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    let index = try await image.index()
    let allImages = try await allImagesRequest
    let containers = try await containersRequest
    var variants: [ImageVariantInspection] = []
    var warnings: [String] = []

    for descriptor in index.manifests {
      if descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
        continue
      }
      guard let platform = descriptor.platform else {
        warnings.append("Manifest \(descriptor.digest) has no platform and was skipped.")
        continue
      }
      do {
        let manifest = try await image.manifest(for: platform)
        let imageConfiguration = try await image.config(for: platform)
        let processConfiguration = imageConfiguration.config
        let size =
          descriptor.size + manifest.config.size
          + manifest.layers.reduce(0) { $0 + $1.size }
        variants.append(
          ImageVariantInspection(
            platform: platform.description,
            os: platform.os,
            architecture: platform.architecture,
            variant: platform.variant,
            manifestDigest: descriptor.digest,
            sizeBytes: size,
            createdAt: Self.parseImageDate(imageConfiguration.created),
            author: imageConfiguration.author,
            user: processConfiguration?.user,
            workingDirectory: processConfiguration?.workingDir,
            entrypoint: processConfiguration?.entrypoint ?? [],
            command: processConfiguration?.cmd ?? [],
            environment: processConfiguration?.env ?? [],
            labels: processConfiguration?.labels ?? [:],
            layerCount: imageConfiguration.rootfs.diffIDs.count
          )
        )
      } catch {
        warnings.append(
          "Could not inspect \(platform.description): \(error.localizedDescription)"
        )
      }
    }

    variants.sort { $0.platform.localizedStandardCompare($1.platform) == .orderedAscending }
    let aliases = allImages.filter { $0.digest == image.digest && $0.reference != image.reference }
      .map(\.reference)
      .sorted()
    let usedBy = containerIDs(
      using: image.reference,
      among: containers,
      configuration: configuration
    )

    return ImageInspection(
      reference: image.reference,
      displayReference: try ClientImage.denormalizeReference(
        image.reference,
        containerSystemConfig: configuration
      ),
      digest: image.digest,
      mediaType: image.descriptor.mediaType,
      indexSizeBytes: image.descriptor.size,
      createdAt: variants.compactMap(\.createdAt).min(),
      variants: variants,
      aliases: aliases,
      usedByContainerIDs: usedBy,
      warnings: warnings
    )
  }

  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    let source = try validatedImageReference(source)
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { throw ImageManagementError.missingTargetReference }

    let configuration = try await loadSystemConfiguration()
    let sourceImage = try await ClientImage.get(
      reference: source,
      containerSystemConfig: configuration
    )
    try ensureUserManaged(sourceImage, configuration: configuration)
    let targetReference = try ClientImage.normalizeReference(
      target,
      containerSystemConfig: configuration
    )
    try ensureUserManaged(reference: targetReference, configuration: configuration)
    let existingTarget = try await ClientImage.list().first {
      $0.reference == targetReference
    }

    return ImageTagPlan(
      sourceReference: sourceImage.reference,
      sourceDigest: sourceImage.digest,
      targetReference: targetReference,
      displayTargetReference: try ClientImage.denormalizeReference(
        targetReference,
        containerSystemConfig: configuration
      ),
      replacedDigest: existingTarget?.digest
    )
  }

  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    try await withRuntimeMutation {
      try await self.tagImageWhileLocked(plan, replacingExisting: replacingExisting)
    }
  }

  private func tagImageWhileLocked(
    _ plan: ImageTagPlan,
    replacingExisting: Bool
  ) async throws {
    let configuration = try await loadSystemConfiguration()
    let sourceImage = try await ClientImage.get(
      reference: plan.sourceReference,
      containerSystemConfig: configuration
    )
    guard sourceImage.digest == plan.sourceDigest else {
      throw ImageManagementError.stalePlan("tag operation")
    }
    try ensureUserManaged(sourceImage, configuration: configuration)
    try ensureUserManaged(reference: plan.targetReference, configuration: configuration)

    let currentTarget = try await ClientImage.list().first {
      $0.reference == plan.targetReference
    }
    if let currentTarget, currentTarget.digest != sourceImage.digest {
      guard currentTarget.digest == plan.replacedDigest else {
        throw ImageManagementError.stalePlan("tag operation")
      }
      guard replacingExisting else {
        throw ImageManagementError.tagWouldReplace(reference: plan.displayTargetReference)
      }
    }
    if currentTarget?.digest == sourceImage.digest { return }
    _ = try await sourceImage.tag(new: plan.targetReference)
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    let reference = try validatedImageReference(reference)
    async let configurationRequest = loadSystemConfiguration()
    async let allImagesRequest = ClientImage.list()
    async let containersRequest = containerReader.list()
    let configuration = try await configurationRequest
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    let allImages = try await allImagesRequest
    let containers = try await containersRequest

    return ImageDeletionPlan(
      reference: image.reference,
      digest: image.digest,
      aliases: allImages.filter { $0.digest == image.digest && $0.reference != image.reference }
        .map(\.reference)
        .sorted(),
      usedByContainerIDs: containerIDs(
        using: image.reference,
        among: containers,
        configuration: configuration
      ),
      isInfrastructureImage: Utility.isInfraImage(
        name: image.reference,
        builderImage: configuration.build.image,
        initImage: configuration.vminit.image
      )
    )
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    try await withRuntimeMutation {
      try await self.deleteImageWhileLocked(plan)
    }
  }

  private func deleteImageWhileLocked(
    _ plan: ImageDeletionPlan
  ) async throws -> ImageCleanupResult {
    let current = try await prepareImageDeletion(reference: plan.reference)
    guard current.digest == plan.digest else {
      throw ImageManagementError.stalePlan("deletion")
    }
    guard !current.isInfrastructureImage else {
      throw ImageManagementError.infrastructureImage(current.reference)
    }
    guard current.usedByContainerIDs.isEmpty else {
      throw ImageManagementError.imageInUse(
        reference: current.reference,
        containerIDs: current.usedByContainerIDs
      )
    }
    let configuration = try await loadSystemConfiguration()
    let image = try await ClientImage.get(
      reference: current.reference,
      containerSystemConfig: configuration
    )
    return try await removeImages([
      ImagePruneRecord(
        reference: image.reference,
        digest: image.digest,
        indexSizeBytes: image.descriptor.size
      )
    ])
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    let configuration = try await loadSystemConfiguration()
    let selection = try await pruneCandidates(mode: mode, configuration: configuration)
    let estimate: UInt64?
    if mode == .allUnused {
      estimate = try await pruneTransport.calculateReclaimableBytes(
        activeReferences: selection.activeReferences
      )
    } else {
      estimate = nil
    }

    return ImagePrunePlan(
      mode: mode,
      generatedAt: Date(),
      candidates: selection.images.map {
        ImagePruneCandidate(
          reference: $0.reference,
          digest: $0.digest,
          indexSizeBytes: $0.indexSizeBytes
        )
      }.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending },
      estimatedReclaimableBytes: estimate
    )
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    do {
      return try await withRuntimeMutation {
        try await self.pruneImagesWhileLocked(plan)
      }
    } catch let partial as ImageCleanupPartialCompletionError {
      throw partial
    } catch is CancellationError {
      throw ImageCleanupPartialCompletionError(
        result: ImageCleanupResult(
          removedReferences: [],
          failedReferences: plan.candidates.map {
            ImageOperationFailure(
              reference: $0.reference,
              message: "Not removed because image cleanup was cancelled."
            )
          },
          removedBlobDigests: [],
          reclaimedBytes: 0
        )
      )
    }
  }

  private func pruneImagesWhileLocked(
    _ plan: ImagePrunePlan
  ) async throws -> ImageCleanupResult {
    let configuration = try await loadSystemConfiguration()
    let current = try await pruneCandidates(mode: plan.mode, configuration: configuration)
    let currentByReference = Dictionary(
      uniqueKeysWithValues: current.images.map { ($0.reference, $0) })
    var images: [ImagePruneRecord] = []
    var staleFailures: [ImageOperationFailure] = []

    for candidate in plan.candidates {
      guard let image = currentByReference[candidate.reference], image.digest == candidate.digest
      else {
        staleFailures.append(
          ImageOperationFailure(
            reference: candidate.reference,
            message: "Changed or became active after review; skipped."
          )
        )
        continue
      }
      images.append(image)
    }

    let result = try await removeImages(images)
    return ImageCleanupResult(
      removedReferences: result.removedReferences,
      failedReferences: staleFailures + result.failedReferences,
      removedBlobDigests: result.removedBlobDigests,
      reclaimedBytes: result.reclaimedBytes
    )
  }

  func prepareImagePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    let reference = try validatedImageReference(reference)
    let configuration = try await loadSystemConfiguration()
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    try ensureUserManaged(image, configuration: configuration)
    let resolvedPlatform = try resolvePlatform(platform)
    if let applePlatform = resolvedPlatform.platform {
      try await validatePlatform(applePlatform, in: image)
    }
    let registry = try resolveRegistryTransport(
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

  func pushImage(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    try await withRuntimeMutation {
      try await self.pushImageWhileLocked(
        plan,
        authorization: authorization,
        progress: progress
      )
    }
  }

  private func pushImageWhileLocked(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let configuration = try await loadSystemConfiguration()
    let registry = try resolveRegistryTransport(
      reference: plan.reference,
      requestedTransport: plan.requestedTransport,
      configuration: configuration
    )
    let image = try await ClientImage.get(
      reference: plan.reference,
      containerSystemConfig: configuration
    )
    try ensureUserManaged(image, configuration: configuration)
    try ImageTransferExecutionSafety.validatePush(
      plan: plan,
      authorization: authorization,
      resolvedRegistryHost: registry.hostname,
      resolvedTransport: registry.transport,
      currentDigest: image.digest,
      isInfrastructureImage: isInfrastructureReference(
        image.reference,
        configuration: configuration
      )
    )
    let applePlatform = try applePlatform(for: plan.platform)
    if let applePlatform {
      try await validatePlatform(applePlatform, in: image)
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

  private func validatedImageReference(_ reference: String) throws -> String {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else { throw ImageManagementError.missingReference }
    return reference
  }

  private func resolvePlatform(
    _ request: ImagePlatformRequest
  ) throws -> (scope: ImagePlatformScope, platform: ContainerizationOCI.Platform?) {
    switch request {
    case .all:
      return (.all, nil)
    case .current:
      let platform = ContainerizationOCI.Platform.current
      return (.specific(Self.platformValue(platform)), platform)
    case .arm64:
      let platform = try ContainerizationOCI.Platform(from: "linux/arm64/v8")
      return (.specific(Self.platformValue(platform)), platform)
    case .amd64:
      let platform = try ContainerizationOCI.Platform(from: "linux/amd64")
      return (.specific(Self.platformValue(platform)), platform)
    }
  }

  private func applePlatform(
    for scope: ImagePlatformScope
  ) throws -> ContainerizationOCI.Platform? {
    switch scope {
    case .all:
      nil
    case .specific(let platform):
      try ContainerizationOCI.Platform(from: platform.description)
    }
  }

  private static func platformValue(
    _ platform: ContainerizationOCI.Platform
  ) -> OCIPlatformValue {
    OCIPlatformValue(
      os: platform.os,
      architecture: platform.architecture,
      variant: platform.variant
    )
  }

  private func validatePlatform(
    _ platform: ContainerizationOCI.Platform,
    in image: ClientImage
  ) async throws {
    let available = try await availablePlatforms(in: image)
    try ImageTransferExecutionSafety.validatePlatform(
      Self.platformValue(platform),
      available: available.map(Self.platformValue),
      reference: image.reference
    )
    _ = try await image.config(for: platform)
  }

  private func transferPlatforms(
    for scope: ImagePlatformScope,
    in image: ClientImage,
    requireAllPlatforms: Bool
  ) async throws -> [ContainerizationOCI.Platform] {
    switch scope {
    case .specific:
      guard let platform = try applePlatform(for: scope) else {
        throw ImageManagementError.noRunnablePlatforms(image.reference)
      }
      try await validatePlatform(platform, in: image)
      return [platform]
    case .all:
      guard requireAllPlatforms else { return [] }
      let platforms = try await availablePlatforms(in: image)
      guard !platforms.isEmpty else {
        throw ImageManagementError.noRunnablePlatforms(image.reference)
      }
      return platforms
    }
  }

  private func availablePlatforms(
    in image: ClientImage
  ) async throws -> [ContainerizationOCI.Platform] {
    let index = try await image.index()
    var unique: [String: ContainerizationOCI.Platform] = [:]
    for descriptor in index.manifests {
      guard
        descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest",
        let platform = descriptor.platform
      else { continue }
      unique[platform.description] = platform
    }
    return unique.values.sorted { $0.description < $1.description }
  }

  private func resolveRegistryTransport(
    reference: String,
    requestedTransport: RegistryTransport,
    configuration: ContainerSystemConfig
  ) throws -> (hostname: String, transport: RegistryTransport) {
    let parsed = try Reference.parse(reference)
    guard let domain = parsed.domain else {
      throw ImageManagementError.missingRegistryHost(reference)
    }
    let endpoint = try AppleRegistryEndpoint(server: domain)
    let requestedScheme = try RequestScheme(requestedTransport.rawValue)
    let resolvedScheme = try requestedScheme.schemeFor(
      host: endpoint.connectionHost,
      internalDnsDomain: configuration.dns.domain
    )
    guard let resolvedTransport = RegistryTransport(rawValue: resolvedScheme.rawValue) else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    return (endpoint.hostname, resolvedTransport)
  }

  private func ensureUserManaged(
    _ image: ClientImage,
    configuration: ContainerSystemConfig
  ) throws {
    try ensureUserManaged(reference: image.reference, configuration: configuration)
  }

  private func ensureUserManaged(
    reference: String,
    configuration: ContainerSystemConfig
  ) throws {
    guard !isInfrastructureReference(reference, configuration: configuration) else {
      throw ImageManagementError.infrastructureImage(reference)
    }
  }

  private func isInfrastructureReference(
    _ reference: String,
    configuration: ContainerSystemConfig
  ) -> Bool {
    if Utility.isInfraImage(
      name: reference,
      builderImage: configuration.build.image,
      initImage: configuration.vminit.image
    ) {
      return true
    }
    guard
      let normalizedReference = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      )
    else { return false }
    return [configuration.build.image, configuration.vminit.image].contains { managedReference in
      guard
        let normalizedManagedReference = try? ClientImage.normalizeReference(
          managedReference,
          containerSystemConfig: configuration
        )
      else { return false }
      return normalizedManagedReference == normalizedReference
    }
  }

  private func containerIDs(
    using imageReference: String,
    among containers: [ContainerSnapshot],
    configuration: ContainerSystemConfig
  ) -> [String] {
    let normalizedImageReference = try? ClientImage.normalizeReference(
      imageReference,
      containerSystemConfig: configuration
    )
    return containers.filter { container in
      let containerReference = container.configuration.image.reference
      if containerReference == imageReference { return true }
      guard let normalizedImageReference else { return false }
      return
        (try? ClientImage.normalizeReference(
          containerReference,
          containerSystemConfig: configuration
        )) == normalizedImageReference
    }.map(\.id).sorted()
  }

  private func pruneCandidates(
    mode: ImagePruneMode,
    configuration: ContainerSystemConfig
  ) async throws -> (images: [ImagePruneRecord], activeReferences: Set<String>) {
    async let imagesRequest = pruneTransport.list()
    async let containersRequest = containerReader.list()
    let (allImages, containers) = try await (imagesRequest, containersRequest)
    var activeReferences = Set<String>()
    for container in containers {
      let reference = container.configuration.image.reference
      activeReferences.insert(reference)
      if let normalized = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      ) {
        activeReferences.insert(normalized)
      }
    }
    for reference in [configuration.build.image, configuration.vminit.image] {
      activeReferences.insert(reference)
      if let normalized = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      ) {
        activeReferences.insert(normalized)
      }
    }

    let userImages = allImages.filter {
      !Utility.isInfraImage(
        name: $0.reference,
        builderImage: configuration.build.image,
        initImage: configuration.vminit.image
      )
    }
    let candidates = userImages.filter { image in
      guard !activeReferences.contains(image.reference) else { return false }
      switch mode {
      case .dangling:
        guard let reference = try? Reference.parse(image.reference) else { return true }
        return reference.tag?.isEmpty != false
      case .allUnused:
        return true
      }
    }
    return (candidates, activeReferences)
  }

  private func removeImages(_ images: [ImagePruneRecord]) async throws -> ImageCleanupResult {
    var removedReferences: [String] = []
    var failures: [ImageOperationFailure] = []

    func cancellationResult(
      through index: Int
    ) async -> ImageCleanupResult {
      let currentReferences = await uncancelledImageReferences()
      let reconciled = images.prefix(index + 1).compactMap { image in
        currentReferences.map { references in
          references.contains(image.reference) ? nil : image.reference
        } ?? (removedReferences.contains(image.reference) ? image.reference : nil)
      }
      let confirmedRemoved = Set(removedReferences).union(reconciled)
      let pending = images.filter { !confirmedRemoved.contains($0.reference) }.map {
        ImageOperationFailure(
          reference: $0.reference,
          message: "Not removed because image cleanup was cancelled."
        )
      }
      let cleanup = await uncancelledOrphanCleanup()
      return ImageCleanupResult(
        removedReferences: confirmedRemoved.sorted(),
        failedReferences: failures + pending,
        removedBlobDigests: cleanup?.deletedDigests.sorted() ?? [],
        reclaimedBytes: cleanup?.reclaimedBytes ?? 0
      )
    }

    for (index, image) in images.enumerated() {
      guard !Task.isCancelled else {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      }
      do {
        try await pruneTransport.delete(reference: image.reference)
        removedReferences.append(image.reference)
      } catch is CancellationError {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      } catch {
        failures.append(
          ImageOperationFailure(
            reference: image.reference,
            message: error.localizedDescription
          )
        )
      }
      if Task.isCancelled {
        throw ImageCleanupPartialCompletionError(
          result: await cancellationResult(through: index)
        )
      }
    }

    var removedBlobDigests: [String] = []
    var reclaimedBytes: UInt64 = 0
    do {
      let cleanup = try await pruneTransport.cleanUpOrphanedBlobs()
      removedBlobDigests = cleanup.deletedDigests
      reclaimedBytes = cleanup.reclaimedBytes
    } catch is CancellationError {
      let cleanup = await uncancelledOrphanCleanup()
      throw ImageCleanupPartialCompletionError(
        result: ImageCleanupResult(
          removedReferences: removedReferences.sorted(),
          failedReferences: failures,
          removedBlobDigests: cleanup?.deletedDigests.sorted() ?? [],
          reclaimedBytes: cleanup?.reclaimedBytes ?? 0
        )
      )
    } catch {
      failures.append(
        ImageOperationFailure(
          reference: "Content store cleanup",
          message: error.localizedDescription
        )
      )
    }

    return ImageCleanupResult(
      removedReferences: removedReferences.sorted(),
      failedReferences: failures,
      removedBlobDigests: removedBlobDigests.sorted(),
      reclaimedBytes: reclaimedBytes
    )
  }

  private func uncancelledImageReferences() async -> Set<String>? {
    let pruneTransport = self.pruneTransport
    return await Task.detached {
      do {
        return Set(try await pruneTransport.list().map(\.reference))
      } catch {
        return nil
      }
    }.value
  }

  private func uncancelledOrphanCleanup() async -> (
    deletedDigests: [String],
    reclaimedBytes: UInt64
  )? {
    let pruneTransport = self.pruneTransport
    return await Task.detached {
      try? await pruneTransport.cleanUpOrphanedBlobs()
    }.value
  }

  private static func parseImageDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: value)
  }

  private func withRuntimeMutation<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await runtimeMutationCoordinator.perform(operation)
  }

  private func loadSystemConfiguration() async throws -> ContainerSystemConfig {
    try await AppleContainerConfiguration.load()
  }
}
