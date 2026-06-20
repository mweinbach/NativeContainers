import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import MachineAPIClient
import SystemPackage
import TerminalProgress

private enum InfrastructureLookup<Value: Sendable>: Sendable {
  case resolved(Value?)
  case failed
}

actor AppleContainerService: ContainerManaging {
  private static let maximumLogBytes = 512 * 1_024
  private static let maximumCommandOutputBytes = 1_024 * 1_024
  private static let creationOperationLabel = "com.nativecontainers.creation-operation"

  private let containerClient = ContainerClient()
  private let machineClient = MachineClient()
  private let infrastructureClient: AppleInfrastructureClient
  private let containerCleanupClient: AppleContainerCleanupClient
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let terminalProcessLauncher: any ContainerTerminalProcessLaunching

  init(
    terminalProcessLauncher: any ContainerTerminalProcessLaunching =
      AppleContainerTerminalProcessLauncher(),
    infrastructureClient: AppleInfrastructureClient = AppleInfrastructureClient(),
    containerCleanupClient: AppleContainerCleanupClient = AppleContainerCleanupClient(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.terminalProcessLauncher = terminalProcessLauncher
    self.infrastructureClient = infrastructureClient
    self.containerCleanupClient = containerCleanupClient
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func loadInventory() async throws -> ContainerInventory {
    async let healthRequest = ClientHealthCheck.ping()
    async let containerRequest = containerClient.list()
    async let imageRequest = ClientImage.list()
    async let volumeRequest = infrastructureClient.listVolumes()
    async let networkRequest = infrastructureClient.listNetworks()
    async let machineRequest = machineClient.list()
    async let systemConfigurationRequest = loadSystemConfiguration()

    let (
      health,
      snapshots,
      clientImages,
      configurations,
      networkResources,
      machineSnapshots,
      systemConfiguration
    ) = try await (
      healthRequest,
      containerRequest,
      imageRequest,
      volumeRequest,
      networkRequest,
      machineRequest,
      systemConfigurationRequest
    )

    let system = ContainerSystemInfo(
      version: health.apiServerVersion,
      build: health.apiServerBuild,
      commit: health.apiServerCommit,
      applicationRoot: health.appRoot,
      installRoot: health.installRoot
    )

    let containers = snapshots.map { snapshot in
      ContainerRecord(
        id: snapshot.id,
        imageReference: snapshot.configuration.image.reference,
        platform: String(describing: snapshot.platform),
        state: RuntimeState(rawValue: snapshot.status.rawValue) ?? .unknown,
        ipAddress: snapshot.networks.first.map { String(describing: $0.ipv4Address) },
        createdAt: snapshot.configuration.creationDate,
        startedAt: snapshot.startedDate,
        cpuCount: snapshot.configuration.resources.cpus,
        memoryBytes: snapshot.configuration.resources.memoryInBytes,
        ports: snapshot.configuration.publishedPorts.flatMap { port in
          (0..<port.count).map { offset in
            ContainerPort(
              hostAddress: String(describing: port.hostAddress),
              hostPort: port.hostPort + offset,
              containerPort: port.containerPort + offset,
              protocolName: port.proto.rawValue
            )
          }
        }
      )
    }

    let images = clientImages.filter { image in
      !Utility.isInfraImage(
        name: image.reference,
        builderImage: systemConfiguration.build.image,
        initImage: systemConfiguration.vminit.image
      )
    }.map { image in
      ImageRecord(
        reference: image.reference,
        digest: image.digest,
        mediaType: image.descriptor.mediaType,
        indexSizeBytes: image.descriptor.size
      )
    }

    let volumeConsumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for volumeName in snapshot.configuration.mounts.compactMap(\.volumeName) {
        result[volumeName, default: []].insert(snapshot.id)
      }
    }
    let networkConsumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for attachment in snapshot.configuration.networks {
        result[attachment.network, default: []].insert(snapshot.id)
      }
    }
    let allocatedVolumeSizes = await loadAllocatedVolumeSizes(
      names: configurations.map(\.name)
    )

    let volumes = configurations.map { volume in
      VolumeRecord(
        id: volume.id,
        name: volume.name,
        driver: volume.driver,
        format: volume.format,
        source: volume.source,
        createdAt: volume.creationDate,
        sizeBytes: volume.sizeInBytes,
        allocatedBytes: allocatedVolumeSizes[volume.name],
        labels: volume.labels,
        options: volume.options,
        isAnonymous: volume.isAnonymous,
        usedByContainerIDs: (volumeConsumers[volume.name] ?? []).sorted()
      )
    }

    let networks = networkResources.map { network in
      NetworkRecord(
        id: network.id,
        name: network.name,
        mode: ContainerNetworkMode(rawValue: network.configuration.mode.rawValue) ?? .nat,
        createdAt: network.creationDate,
        configuredIPv4Subnet: network.configuration.ipv4Subnet.map(String.init(describing:)),
        configuredIPv6Subnet: network.configuration.ipv6Subnet.map(String.init(describing:)),
        assignedIPv4Subnet: String(describing: network.status.ipv4Subnet),
        ipv4Gateway: String(describing: network.status.ipv4Gateway),
        assignedIPv6Subnet: network.status.ipv6Subnet.map(String.init(describing:)),
        labels: network.labels.dictionary,
        plugin: network.configuration.plugin,
        options: network.configuration.options,
        isBuiltin: network.isBuiltin,
        usedByContainerIDs: (networkConsumers[network.id] ?? []).sorted()
      )
    }

    let machines = machineSnapshots.map { machine in
      LinuxMachineRecord(
        id: machine.id,
        imageReference: machine.configuration.image.reference,
        platform: String(describing: machine.platform),
        state: RuntimeState(rawValue: machine.status.rawValue) ?? .unknown,
        ipAddress: machine.ipAddress,
        createdAt: machine.createdDate,
        startedAt: machine.startedDate,
        diskSizeBytes: machine.diskSize,
        cpuCount: machine.bootConfig.cpus,
        memoryDescription: String(describing: machine.bootConfig.memory),
        isInitialized: machine.initialized
      )
    }

    return ContainerInventory(
      system: system,
      containers: containers.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
      images: images.sorted {
        $0.reference.localizedStandardCompare($1.reference) == .orderedAscending
      },
      volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      networks: networks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      machines: machines.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    )
  }

  func startContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status != .running else { return }

    var environment: [String: String] = [:]
    if snapshot.configuration.ssh,
      let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    {
      environment["SSH_AUTH_SOCK"] = socket
    }

    let process = try await containerClient.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: environment
    )
    try await process.start()
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
    async let containersRequest = containerClient.list()

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
    async let containersRequest = containerClient.list()
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
    return try await removeImages([image])
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    let configuration = try await loadSystemConfiguration()
    let selection = try await pruneCandidates(mode: mode, configuration: configuration)
    let estimate: UInt64?
    if mode == .allUnused {
      estimate = try await ClientImage.calculateDiskUsage(
        activeReferences: selection.activeReferences
      ).reclaimableSize
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
          indexSizeBytes: $0.descriptor.size
        )
      }.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending },
      estimatedReclaimableBytes: estimate
    )
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    try await withRuntimeMutation {
      try await self.pruneImagesWhileLocked(plan)
    }
  }

  private func pruneImagesWhileLocked(
    _ plan: ImagePrunePlan
  ) async throws -> ImageCleanupResult {
    let configuration = try await loadSystemConfiguration()
    let current = try await pruneCandidates(mode: plan.mode, configuration: configuration)
    let currentByReference = Dictionary(
      uniqueKeysWithValues: current.images.map { ($0.reference, $0) })
    var images: [ClientImage] = []
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

  func prepareVolumeCreation(_ request: VolumeCreateRequest) async throws -> VolumeCreationPlan {
    guard request.labels[VolumeConfiguration.anonymousLabel] == nil else {
      throw ResourceManagementError.reservedMetadataKey(VolumeConfiguration.anonymousLabel)
    }
    _ = try ResourceLabels(request.labels)
    guard try await currentVolumeRecord(name: request.name) == nil else {
      throw ResourceManagementError.resourceAlreadyExists(request.name)
    }
    return VolumeCreationPlan(request: request, generatedAt: Date())
  }

  func createVolume(_ plan: VolumeCreationPlan) async throws -> VolumeRecord {
    do {
      return try await withRuntimeMutation {
        try await self.createVolumeWhileLocked(plan)
      }
    } catch {
      let originalError = error
      switch await uncancelledVolumeRecord(name: plan.request.name) {
      case .resolved(let record?) where volume(record, matches: plan.request):
        if originalError is CancellationError {
          try await removeOwnedVolume(plan.request)
          throw CancellationError()
        }
        return record
      case .resolved:
        throw originalError
      case .failed:
        if originalError is CancellationError {
          throw ResourceManagementError.cleanupStateUnknown(plan.request.name)
        }
        throw originalError
      }
    }
  }

  private func createVolumeWhileLocked(_ plan: VolumeCreationPlan) async throws -> VolumeRecord {
    guard try await currentVolumeRecord(name: plan.request.name) == nil else {
      throw ResourceManagementError.stalePlan(plan.request.name)
    }
    try Task.checkCancellation()

    var labels = plan.request.labels
    labels[ResourceOperationLabel.key] = plan.request.operationID.uuidString
    let options = [
      "size": "\(plan.request.sizeBytes)B",
      "journal": plan.request.journalMode.rawValue,
    ]
    let configuration = try await infrastructureClient.createVolume(
      name: plan.request.name,
      driver: "local",
      driverOptions: options,
      labels: labels
    )
    try Task.checkCancellation()

    let allocatedBytes: UInt64?
    do {
      allocatedBytes = try await infrastructureClient.volumeDiskUsage(name: configuration.name)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      allocatedBytes = nil
    }
    try Task.checkCancellation()

    let created = VolumeRecord(
      id: configuration.id,
      name: configuration.name,
      driver: configuration.driver,
      format: configuration.format,
      source: configuration.source,
      createdAt: configuration.creationDate,
      sizeBytes: configuration.sizeInBytes,
      allocatedBytes: allocatedBytes,
      labels: configuration.labels,
      options: configuration.options,
      isAnonymous: configuration.isAnonymous,
      usedByContainerIDs: []
    )
    guard volume(created, matches: plan.request) else {
      throw ResourceManagementError.stalePlan(plan.request.name)
    }
    return created
  }

  func prepareVolumeDeletion(name: String) async throws -> VolumeDeletionPlan {
    guard let volume = try await currentVolumeRecord(name: name) else {
      throw ResourceManagementError.stalePlan(name)
    }
    return VolumeDeletionPlan(
      volume: volume,
      identity: volume.configurationIdentity,
      generatedAt: Date()
    )
  }

  func deleteVolume(_ plan: VolumeDeletionPlan) async throws {
    try await withRuntimeMutation {
      try await self.deleteVolumeWhileLocked(plan)
    }
  }

  private func deleteVolumeWhileLocked(_ plan: VolumeDeletionPlan) async throws {
    guard let current = try await currentVolumeRecord(name: plan.volume.name) else {
      return
    }
    try InfrastructureExecutionSafety.validateVolumeDeletion(
      plan: plan,
      current: current
    )
    try Task.checkCancellation()

    do {
      try await infrastructureClient.deleteVolume(name: current.name)
    } catch {
      guard shouldReconcileAfterInfrastructureError(error) else { throw error }
      switch await uncancelledVolumeRecord(name: current.name) {
      case .resolved(nil):
        return
      case .resolved(let reconciled?):
        guard reconciled.configurationIdentity == plan.identity else {
          throw ResourceManagementError.stalePlan(current.name)
        }
        throw error
      case .failed:
        throw error
      }
    }
  }

  func prepareVolumePrune() async throws -> VolumePrunePlan {
    let volumes = try await loadCurrentVolumeRecords()
    let candidates = volumes
      .filter { $0.usedByContainerIDs.isEmpty }
      .map {
        VolumeDeletionPlan(
          volume: $0,
          identity: $0.configurationIdentity,
          generatedAt: Date()
        )
      }
    return VolumePrunePlan(candidates: candidates, generatedAt: Date())
  }

  func pruneVolumes(_ plan: VolumePrunePlan) async throws -> ResourceCleanupResult {
    try await withRuntimeMutation {
      var removed: [String] = []
      var failures: [ResourceOperationFailure] = []
      var reclaimedBytes: UInt64 = 0

      func cancellationResult(startingAt index: Int) -> ResourceCleanupResult {
        let pending = plan.candidates[index...].map {
          ResourceOperationFailure(
            resource: $0.volume.name,
            message: "Not removed because pruning was cancelled."
          )
        }
        return ResourceCleanupResult(
          removedResourceNames: removed.sorted(),
          failedResources: failures + pending,
          reclaimedBytes: reclaimedBytes
        )
      }

      for (index, candidate) in plan.candidates.enumerated() {
        if Task.isCancelled {
          throw ResourceCleanupPartialCompletionError(
            operation: "Volume pruning",
            result: cancellationResult(startingAt: index)
          )
        }

        let allocated: UInt64
        do {
          allocated = try await self.infrastructureClient.volumeDiskUsage(
            name: candidate.volume.name
          )
        } catch is CancellationError {
          throw ResourceCleanupPartialCompletionError(
            operation: "Volume pruning",
            result: cancellationResult(startingAt: index)
          )
        } catch {
          allocated = 0
        }

        do {
          try Task.checkCancellation()
          try await self.deleteVolumeWhileLocked(candidate)
          removed.append(candidate.volume.name)
          let (sum, overflow) = reclaimedBytes.addingReportingOverflow(allocated)
          reclaimedBytes = overflow ? UInt64.max : sum
        } catch is CancellationError {
          throw ResourceCleanupPartialCompletionError(
            operation: "Volume pruning",
            result: cancellationResult(startingAt: index)
          )
        } catch {
          failures.append(
            ResourceOperationFailure(
              resource: candidate.volume.name,
              message: error.localizedDescription
            )
          )
        }
      }

      return ResourceCleanupResult(
        removedResourceNames: removed.sorted(),
        failedResources: failures,
        reclaimedBytes: reclaimedBytes
      )
    }
  }

  func prepareNetworkCreation(_ request: NetworkCreateRequest) async throws -> NetworkCreationPlan {
    guard request.name != NetworkClient.noNetworkName else {
      throw ResourceManagementError.invalidNetworkName
    }
    _ = try ResourceLabels(request.labels)
    _ = try request.ipv4Subnet.map { try CIDRv4($0) }
    _ = try request.ipv6Subnet.map { try CIDRv6($0) }
    guard try await currentNetworkRecord(id: request.name) == nil else {
      throw ResourceManagementError.resourceAlreadyExists(request.name)
    }
    return NetworkCreationPlan(request: request, generatedAt: Date())
  }

  func createNetwork(_ plan: NetworkCreationPlan) async throws -> NetworkRecord {
    do {
      return try await withRuntimeMutation {
        try await self.createNetworkWhileLocked(plan)
      }
    } catch {
      let originalError = error
      switch await uncancelledNetworkRecord(id: plan.request.name) {
      case .resolved(let record?) where network(record, matches: plan.request):
        if originalError is CancellationError {
          try await removeOwnedNetwork(plan.request)
          throw CancellationError()
        }
        return record
      case .resolved:
        throw originalError
      case .failed:
        if originalError is CancellationError {
          throw ResourceManagementError.cleanupStateUnknown(plan.request.name)
        }
        throw originalError
      }
    }
  }

  private func createNetworkWhileLocked(_ plan: NetworkCreationPlan) async throws -> NetworkRecord {
    guard try await currentNetworkRecord(id: plan.request.name) == nil else {
      throw ResourceManagementError.stalePlan(plan.request.name)
    }
    try Task.checkCancellation()

    var labels = plan.request.labels
    labels[ResourceOperationLabel.key] = plan.request.operationID.uuidString
    let configuration = try NetworkConfiguration(
      name: plan.request.name,
      mode: NetworkMode(rawValue: plan.request.mode.rawValue) ?? .nat,
      ipv4Subnet: try plan.request.ipv4Subnet.map { try CIDRv4($0) },
      ipv6Subnet: try plan.request.ipv6Subnet.map { try CIDRv6($0) },
      labels: ResourceLabels(labels),
      plugin: "container-network-vmnet"
    )
    let resource = try await infrastructureClient.createNetwork(configuration: configuration)
    try Task.checkCancellation()

    let created = NetworkRecord(
      id: resource.id,
      name: resource.name,
      mode: ContainerNetworkMode(rawValue: resource.configuration.mode.rawValue) ?? .nat,
      createdAt: resource.creationDate,
      configuredIPv4Subnet: resource.configuration.ipv4Subnet.map(String.init(describing:)),
      configuredIPv6Subnet: resource.configuration.ipv6Subnet.map(String.init(describing:)),
      assignedIPv4Subnet: String(describing: resource.status.ipv4Subnet),
      ipv4Gateway: String(describing: resource.status.ipv4Gateway),
      assignedIPv6Subnet: resource.status.ipv6Subnet.map(String.init(describing:)),
      labels: resource.labels.dictionary,
      plugin: resource.configuration.plugin,
      options: resource.configuration.options,
      isBuiltin: resource.isBuiltin,
      usedByContainerIDs: []
    )
    guard network(created, matches: plan.request) else {
      throw ResourceManagementError.stalePlan(plan.request.name)
    }
    return created
  }

  func prepareNetworkDeletion(id: String) async throws -> NetworkDeletionPlan {
    guard let network = try await currentNetworkRecord(id: id) else {
      throw ResourceManagementError.stalePlan(id)
    }
    return NetworkDeletionPlan(
      network: network,
      identity: network.configurationIdentity,
      generatedAt: Date()
    )
  }

  func deleteNetwork(_ plan: NetworkDeletionPlan) async throws {
    try await withRuntimeMutation {
      try await self.deleteNetworkWhileLocked(plan)
    }
  }

  private func deleteNetworkWhileLocked(_ plan: NetworkDeletionPlan) async throws {
    guard let current = try await currentNetworkRecord(id: plan.network.id) else {
      return
    }
    try InfrastructureExecutionSafety.validateNetworkDeletion(
      plan: plan,
      current: current
    )
    try Task.checkCancellation()

    do {
      try await infrastructureClient.deleteNetwork(id: current.id)
    } catch {
      guard shouldReconcileAfterInfrastructureError(error) else { throw error }
      switch await uncancelledNetworkRecord(id: current.id) {
      case .resolved(nil):
        return
      case .resolved(let reconciled?):
        guard reconciled.configurationIdentity == plan.identity else {
          throw ResourceManagementError.stalePlan(current.name)
        }
        throw error
      case .failed:
        throw error
      }
    }
  }

  func prepareNetworkPrune() async throws -> NetworkPrunePlan {
    let networks = try await loadCurrentNetworkRecords()
    let candidates = networks
      .filter { !$0.isBuiltin && $0.usedByContainerIDs.isEmpty }
      .map {
        NetworkDeletionPlan(
          network: $0,
          identity: $0.configurationIdentity,
          generatedAt: Date()
        )
      }
    return NetworkPrunePlan(candidates: candidates, generatedAt: Date())
  }

  func pruneNetworks(_ plan: NetworkPrunePlan) async throws -> ResourceCleanupResult {
    try await withRuntimeMutation {
      var removed: [String] = []
      var failures: [ResourceOperationFailure] = []

      func cancellationResult(startingAt index: Int) -> ResourceCleanupResult {
        let pending = plan.candidates[index...].map {
          ResourceOperationFailure(
            resource: $0.network.name,
            message: "Not removed because pruning was cancelled."
          )
        }
        return ResourceCleanupResult(
          removedResourceNames: removed.sorted(),
          failedResources: failures + pending,
          reclaimedBytes: 0
        )
      }

      for (index, candidate) in plan.candidates.enumerated() {
        if Task.isCancelled {
          throw ResourceCleanupPartialCompletionError(
            operation: "Network pruning",
            result: cancellationResult(startingAt: index)
          )
        }

        do {
          try await self.deleteNetworkWhileLocked(candidate)
          removed.append(candidate.network.name)
        } catch is CancellationError {
          throw ResourceCleanupPartialCompletionError(
            operation: "Network pruning",
            result: cancellationResult(startingAt: index)
          )
        } catch {
          failures.append(
            ResourceOperationFailure(
              resource: candidate.network.name,
              message: error.localizedDescription
            )
          )
        }
      }

      return ResourceCleanupResult(
        removedResourceNames: removed.sorted(),
        failedResources: failures,
        reclaimedBytes: 0
      )
    }
  }

  func resolveContainerBrowserURL(_ target: ContainerBrowserTarget) async throws -> URL {
    let snapshot = try await containerClient.get(id: target.containerID)
    guard snapshot.configuration.creationDate == target.containerCreatedAt else {
      throw ResourceManagementError.containerReplaced(target.containerID)
    }
    guard snapshot.status == .running else {
      throw ResourceManagementError.containerNotRunning(target.containerID)
    }

    let publishedPorts = snapshot.configuration.publishedPorts.flatMap { port in
      (0..<port.count).map { offset in
        ContainerPort(
          hostAddress: String(describing: port.hostAddress),
          hostPort: port.hostPort + offset,
          containerPort: port.containerPort + offset,
          protocolName: port.proto.rawValue
        )
      }
    }
    guard let publishedPort = publishedPorts.first(where: { $0.id == target.portID }) else {
      throw ResourceManagementError.publishedPortChanged
    }

    return try ContainerBrowserURLBuilder.makeURL(
      port: publishedPort,
      scheme: target.scheme
    )
  }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    do {
      try await withRuntimeMutation {
        try await self.createContainerWhileLocked(request: request, progress: progress)
      }
    } catch {
      let operationMessage = error.localizedDescription
      do {
        try await removeContainerIfOwned(
          id: request.name,
          operationID: request.operationID
        )
      } catch {
        throw AppleContainerServiceError.containerCleanupFailed(
          id: request.name,
          operation: operationMessage,
          cleanup: error.localizedDescription
        )
      }
      throw error
    }
  }

  private func createContainerWhileLocked(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .preparing, message: "Preparing container")
    try Utility.validEntityName(request.name)

    if (try? await containerClient.get(id: request.name)) != nil {
      throw AppleContainerServiceError.containerAlreadyExists(request.name)
    }

    let systemConfiguration = try await loadSystemConfiguration()
    let processFlags = Flags.Process(
      cwd: request.workingDirectory,
      env: request.environment.map(\.entry),
      envFile: [],
      gid: nil,
      interactive: false,
      tty: false,
      uid: nil,
      ulimits: [],
      user: nil
    )
    let resourceFlags = Flags.Resource(
      cpus: Int64(request.cpuCount),
      memory: "\(request.memoryBytes / ContainerCreationRequest.bytesPerMiB)MiB"
    )
    let managementFlags = Flags.Management(
      arch: request.architecture.rawValue,
      capAdd: [],
      capDrop: [],
      cidfile: "",
      detach: true,
      dns: Flags.DNS(),
      dnsDisabled: false,
      entrypoint: nil,
      initImage: nil,
      kernel: nil,
      labels: ["\(Self.creationOperationLabel)=\(request.operationID.uuidString)"],
      mounts: [],
      name: request.name,
      networks: [],
      os: "linux",
      platform: nil,
      publishPorts: request.publishedPorts.map(\.appleSpecification),
      publishSockets: [],
      readOnly: request.readOnlyRootFilesystem,
      remove: request.removeWhenStopped,
      rosetta: false,
      runtime: nil,
      ssh: request.forwardSSHAgent,
      shmSize: nil,
      tmpFs: [],
      useInit: request.useInitProcess,
      virtualization: false,
      volumes: []
    )
    try managementFlags.validate()
    let appleProgress: ProgressUpdateHandler = { events in
      await relay.consume(events)
    }
    let requestedPlatform = Parser.platform(os: "linux", arch: request.architecture.rawValue)
    await relay.emit(phase: .fetchingImage, message: "Checking image platform")
    let image: ClientImage
    if let localImage = try? await ClientImage.get(
      reference: request.imageReference,
      containerSystemConfig: systemConfiguration
    ) {
      do {
        _ = try await localImage.config(for: requestedPlatform)
        image = localImage
      } catch {
        image = try await ClientImage.pull(
          reference: request.imageReference,
          platform: requestedPlatform,
          containerSystemConfig: systemConfiguration,
          progressUpdate: appleProgress
        )
      }
    } else {
      image = try await ClientImage.fetch(
        reference: request.imageReference,
        platform: requestedPlatform,
        containerSystemConfig: systemConfiguration,
        progressUpdate: appleProgress
      )
    }

    await relay.emit(phase: .unpackingImage, message: "Unpacking image")
    _ = try await image.getCreateSnapshot(
      platform: requestedPlatform,
      progressUpdate: appleProgress
    )

    await relay.emit(phase: .fetchingKernel, message: "Preparing Linux kernel")
    let kernel = try await ClientKernel.getDefaultKernel(for: .current)

    await relay.emit(phase: .fetchingInitImage, message: "Fetching runtime image")
    let initImage = try await ClientImage.fetch(
      reference: systemConfiguration.vminit.image,
      platform: .current,
      containerSystemConfig: systemConfiguration,
      progressUpdate: appleProgress
    )
    await relay.emit(phase: .unpackingInitImage, message: "Unpacking runtime image")
    _ = try await initImage.getCreateSnapshot(
      platform: .current,
      progressUpdate: appleProgress
    )

    let imageConfiguration = try await image.config(for: requestedPlatform).config
    let processConfiguration = try Parser.process(
      arguments: request.arguments,
      processFlags: processFlags,
      managementFlags: managementFlags,
      config: imageConfiguration
    )
    var configuration = ContainerConfiguration(
      id: request.name,
      image: image.description,
      process: processConfiguration
    )
    configuration.platform = requestedPlatform
    configuration.resources = try Parser.resources(
      cpus: resourceFlags.cpus,
      memory: resourceFlags.memory,
      defaultCPUs: systemConfiguration.container.cpus,
      defaultMemory: systemConfiguration.container.memory
    )
    configuration.rosetta = request.architecture == .amd64
    configuration.labels = [Self.creationOperationLabel: request.operationID.uuidString]
    configuration.publishedPorts = try Parser.publishPorts(
      request.publishedPorts.map(\.appleSpecification)
    )
    guard configuration.publishedPorts.count <= 64 else {
      throw ContainerCreationValidationError.tooManyPortPublications
    }
    guard !configuration.publishedPorts.hasOverlaps() else {
      throw ContainerCreationValidationError.duplicatePortPublication
    }
    configuration.ssh = request.forwardSSHAgent
    configuration.readOnly = request.readOnlyRootFilesystem
    configuration.useInit = request.useInitProcess
    configuration.stopSignal = imageConfiguration?.stopSignal

    guard
      let builtinNetwork = try await infrastructureClient.listNetworks().first(where: {
        $0.id == NetworkClient.defaultNetworkName && $0.isBuiltin
      })
    else {
      throw AppleContainerServiceError.builtinNetworkUnavailable
    }
    let hostname = systemConfiguration.dns.domain.map { "\(request.name).\($0)." } ?? request.name
    configuration.networks = [
      AttachmentConfiguration(
        network: builtinNetwork.id,
        options: AttachmentOptions(hostname: hostname, macAddress: nil, mtu: 1_280)
      )
    ]
    configuration.dns = .init(
      nameservers: [],
      domain: systemConfiguration.dns.domain,
      searchDomains: [],
      options: []
    )

    await relay.emit(phase: .creating, message: "Creating container")
    try await containerClient.create(
      configuration: configuration,
      options: ContainerCreateOptions(autoRemove: request.removeWhenStopped),
      kernel: kernel
    )

    try Task.checkCancellation()
    if request.startAfterCreation {
      await relay.emit(phase: .starting, message: "Starting container")
      try await startContainer(id: request.name)
    }
    try Task.checkCancellation()
    await relay.emit(phase: .completed, message: "Container ready")
  }

  func inspectContainer(id: String) async throws -> ContainerInspection {
    let snapshot = try await containerClient.get(id: id)
    async let diskUsageRequest = containerClient.diskUsage(id: id)
    async let logsRequest = loadContainerLogs(id: id)

    let statistics: ContainerStatistics?
    if snapshot.status == .running {
      let value = try await containerClient.stats(id: id)
      statistics = ContainerStatistics(
        memoryUsageBytes: value.memoryUsageBytes,
        memoryLimitBytes: value.memoryLimitBytes,
        cpuUsageMicroseconds: value.cpuUsageUsec,
        networkReceivedBytes: value.networkRxBytes,
        networkTransmittedBytes: value.networkTxBytes,
        blockReadBytes: value.blockReadBytes,
        blockWrittenBytes: value.blockWriteBytes,
        processCount: value.numProcesses
      )
    } else {
      statistics = nil
    }

    let (diskUsage, logs) = try await (diskUsageRequest, logsRequest)
    return ContainerInspection(
      diskUsageBytes: diskUsage,
      statistics: statistics,
      standardOutput: logs.standardOutput,
      bootLog: logs.bootLog,
      logsAreTruncated: logs.logsAreTruncated
    )
  }

  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else { return nil }
    let value = try await containerClient.stats(id: id)
    return ContainerStatistics(
      memoryUsageBytes: value.memoryUsageBytes,
      memoryLimitBytes: value.memoryLimitBytes,
      cpuUsageMicroseconds: value.cpuUsageUsec,
      networkReceivedBytes: value.networkRxBytes,
      networkTransmittedBytes: value.networkTxBytes,
      blockReadBytes: value.blockReadBytes,
      blockWrittenBytes: value.blockWriteBytes,
      processCount: value.numProcesses
    )
  }

  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    let logs = try await readLogs(id: id)
    return ContainerLogsSnapshot(
      standardOutput: logs.standardOutput.text,
      bootLog: logs.boot.text,
      logsAreTruncated: logs.standardOutput.isTruncated || logs.boot.isTruncated
    )
  }

  func stopContainer(id: String) async throws {
    try await containerClient.stop(
      id: id,
      opts: ContainerStopOptions(timeoutInSeconds: 5, signal: nil)
    )
  }

  func restartContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    if snapshot.status == .running {
      try await stopContainer(id: id)
    }
    try await startContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try await containerClient.kill(id: id, signal: "KILL")
  }

  func deleteContainer(id: String) async throws {
    try await containerClient.delete(id: id)
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else {
      throw ContainerToolValidationError.containerNotRunning(id)
    }

    var configuration = snapshot.configuration.initProcess
    configuration.executable = request.executable
    configuration.arguments = request.arguments
    configuration.terminal = false
    configuration.environment = try Parser.allEnv(
      imageEnvs: configuration.environment,
      envFiles: [],
      envs: request.environment.map(\.entry)
    )
    if let workingDirectory = request.workingDirectory {
      configuration.workingDirectory = workingDirectory
    }

    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    let process = try await containerClient.createProcess(
      containerId: id,
      processId: UUID().uuidString.lowercased(),
      configuration: configuration,
      stdio: [nil, standardOutputPipe.fileHandleForWriting, standardErrorPipe.fileHandleForWriting]
    )
    let standardOutputTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardOutputPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let standardErrorTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardErrorPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
      try await process.start()
      try standardOutputPipe.fileHandleForWriting.close()
      try standardErrorPipe.fileHandleForWriting.close()
      let exitCode = try await Self.wait(
        for: process,
        timeoutSeconds: request.timeoutSeconds
      )
      let standardOutput = try await standardOutputTask.value
      let standardError = try await standardErrorTask.value
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      return ContainerCommandResult(
        exitCode: exitCode,
        standardOutput: String(decoding: standardOutput.data, as: UTF8.self),
        standardError: String(decoding: standardError.data, as: UTF8.self),
        outputWasTruncated: standardOutput.isTruncated || standardError.isTruncated,
        duration: startedAt.duration(to: clock.now)
      )
    } catch {
      try? await process.kill(SIGKILL)
      try? standardOutputPipe.fileHandleForWriting.close()
      try? standardErrorPipe.fileHandleForWriting.close()
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      standardOutputTask.cancel()
      standardErrorTask.cancel()
      throw error
    }
  }

  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw ContainerTerminalError.invalidContainerIdentifier
    }

    let transport = PipeContainerTerminalTransport()
    do {
      let process = try await terminalProcessLauncher.makeProcess(
        containerID: id,
        request: request,
        standardInput: transport.childStandardInput,
        standardOutput: transport.childStandardOutput
      )

      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: request.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: request.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }

  func copyIntoContainer(id: String, source: URL, destination: String) async throws {
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
      throw ContainerToolValidationError.invalidLocalURL
    }
    try await containerClient.copyIn(
      id: id,
      source: source.path(percentEncoded: false),
      destination: destination,
      createParents: true
    )
  }

  func copyFromContainer(id: String, source: String, destination: URL) async throws {
    var destination = destination.standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(
      atPath: destination.path(percentEncoded: false),
      isDirectory: &isDirectory
    ), isDirectory.boolValue {
      destination.append(path: URL(filePath: source).lastPathComponent)
    }
    try await containerClient.copyOut(
      id: id,
      source: source,
      destination: destination.path(percentEncoded: false),
      createParents: true
    )
  }

  func startMachine(id: String) async throws {
    _ = try await machineClient.boot(id: id)
  }

  func stopMachine(id: String) async throws {
    try await machineClient.stop(id: id)
  }

  func deleteMachine(id: String) async throws {
    try await machineClient.delete(id: id)
  }

  private func readLogs(id: String) async throws -> (
    standardOutput: (text: String, isTruncated: Bool),
    boot: (text: String, isTruncated: Bool)
  ) {
    let handles = try await containerClient.logs(id: id)
    defer {
      for handle in handles {
        try? handle.close()
      }
    }

    guard handles.count >= 2 else {
      return (("", false), ("", false))
    }
    return try (
      Self.readTail(from: handles[0], maximumBytes: Self.maximumLogBytes),
      Self.readTail(from: handles[1], maximumBytes: Self.maximumLogBytes)
    )
  }

  private static func readTail(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (text: String, isTruncated: Bool) {
    let length = try handle.seekToEnd()
    let maximumBytes = UInt64(maximumBytes)
    let isTruncated = length > maximumBytes
    try handle.seek(toOffset: isTruncated ? length - maximumBytes : 0)
    let data = try handle.readToEnd() ?? Data()
    return (String(decoding: data, as: UTF8.self), isTruncated)
  }

  private static func wait(
    for process: any ClientProcess,
    timeoutSeconds: Int
  ) async throws -> Int32 {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          try await process.wait()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(timeoutSeconds))
          try? await process.kill(SIGKILL)
          throw ContainerToolValidationError.commandTimedOut(timeoutSeconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw CancellationError()
        }
        return result
      }
    } onCancel: {
      Task {
        try? await process.kill(SIGKILL)
      }
    }
  }

  private static func readBoundedOutput(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (data: Data, isTruncated: Bool) {
    var result = Data()
    var isTruncated = false
    while !Task.isCancelled {
      guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
      if chunk.count >= maximumBytes {
        result = Data(chunk.suffix(maximumBytes))
        isTruncated = true
      } else {
        let excess = result.count + chunk.count - maximumBytes
        if excess > 0 {
          result.removeFirst(excess)
          isTruncated = true
        }
        result.append(chunk)
      }
    }
    return (result, isTruncated)
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
  ) async throws -> (images: [ClientImage], activeReferences: Set<String>) {
    async let imagesRequest = ClientImage.list()
    async let containersRequest = containerClient.list()
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

  private func removeImages(_ images: [ClientImage]) async throws -> ImageCleanupResult {
    var removedReferences: [String] = []
    var failures: [ImageOperationFailure] = []

    do {
      for image in images {
        try Task.checkCancellation()
        do {
          try await ClientImage.delete(reference: image.reference, garbageCollect: false)
          removedReferences.append(image.reference)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          failures.append(
            ImageOperationFailure(
              reference: image.reference,
              message: error.localizedDescription
            )
          )
        }
      }
    } catch is CancellationError {
      _ = try? await Task.detached {
        try await ClientImage.cleanUpOrphanedBlobs()
      }.value
      throw CancellationError()
    }

    var removedBlobDigests: [String] = []
    var reclaimedBytes: UInt64 = 0
    do {
      (removedBlobDigests, reclaimedBytes) = try await ClientImage.cleanUpOrphanedBlobs()
    } catch is CancellationError {
      _ = try? await Task.detached {
        try await ClientImage.cleanUpOrphanedBlobs()
      }.value
      throw CancellationError()
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

  private func uncancelledVolumeRecord(
    name: String
  ) async -> InfrastructureLookup<VolumeRecord> {
    await Task.detached { [self] in
      do {
        return .resolved(try await currentVolumeRecord(name: name))
      } catch {
        return .failed
      }
    }.value
  }

  private func uncancelledNetworkRecord(
    id: String
  ) async -> InfrastructureLookup<NetworkRecord> {
    await Task.detached { [self] in
      do {
        return .resolved(try await currentNetworkRecord(id: id))
      } catch {
        return .failed
      }
    }.value
  }

  private func removeOwnedVolume(_ request: VolumeCreateRequest) async throws {
    do {
      try await Task.detached { [self] in
        guard let current = try await currentVolumeRecord(name: request.name),
          volume(current, matches: request)
        else {
          return
        }

        do {
          try await infrastructureClient.deleteVolume(name: request.name)
        } catch {
          if let remaining = try await currentVolumeRecord(name: request.name),
            volume(remaining, matches: request)
          {
            throw error
          }
          return
        }

        if let remaining = try await currentVolumeRecord(name: request.name),
          volume(remaining, matches: request)
        {
          throw ResourceManagementError.ownedResourceCleanupFailed(request.name)
        }
      }.value
    } catch {
      throw ResourceManagementError.ownedResourceCleanupFailed(request.name)
    }
  }

  private func removeOwnedNetwork(_ request: NetworkCreateRequest) async throws {
    do {
      try await Task.detached { [self] in
        guard let current = try await currentNetworkRecord(id: request.name),
          network(current, matches: request)
        else {
          return
        }

        do {
          try await infrastructureClient.deleteNetwork(id: current.id)
        } catch {
          if let remaining = try await currentNetworkRecord(id: current.id),
            network(remaining, matches: request)
          {
            throw error
          }
          return
        }

        if let remaining = try await currentNetworkRecord(id: current.id),
          network(remaining, matches: request)
        {
          throw ResourceManagementError.ownedResourceCleanupFailed(request.name)
        }
      }.value
    } catch {
      throw ResourceManagementError.ownedResourceCleanupFailed(request.name)
    }
  }

  private func shouldReconcileAfterInfrastructureError(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    guard let resourceError = error as? ResourceManagementError else { return false }
    if case .operationTimedOut = resourceError { return true }
    return false
  }

  private func removeContainerIfOwned(id: String, operationID: UUID) async throws {
    let cleanupClient = containerCleanupClient
    try await Task.detached {
      var lastFailure = "The container remained present after force deletion."

      for attempt in 0..<2 {
        let snapshots: [ContainerSnapshot]
        do {
          snapshots = try await cleanupClient.list(id: id)
        } catch {
          lastFailure = "Ownership verification failed: \(error.localizedDescription)"
          if attempt == 0 {
            try await Task.sleep(for: .milliseconds(250))
          }
          continue
        }

        guard let snapshot = snapshots.first else { return }
        guard
          snapshot.configuration.labels[Self.creationOperationLabel] == operationID.uuidString
        else {
          return
        }

        if snapshot.status == .running {
          do {
            try await cleanupClient.kill(id: id)
          } catch {
            lastFailure = "KILL failed: \(error.localizedDescription)"
          }
        }

        do {
          try await cleanupClient.forceDelete(id: id)
        } catch {
          lastFailure = "Force deletion failed: \(error.localizedDescription)"
        }

        do {
          let remaining = try await cleanupClient.list(id: id)
          guard let current = remaining.first else { return }
          guard
            current.configuration.labels[Self.creationOperationLabel] == operationID.uuidString
          else {
            return
          }
          lastFailure = "The owned container still exists after force deletion."
        } catch {
          lastFailure = "Post-cleanup verification failed: \(error.localizedDescription)"
        }

        if attempt == 0 {
          try await Task.sleep(for: .milliseconds(250))
        }
      }

      throw AppleContainerCleanupError.exhausted(id: id, reason: lastFailure)
    }.value
  }

  private func loadAllocatedVolumeSizes(names: [String]) async -> [String: UInt64] {
    let uniqueNames = Array(Set(names)).sorted()
    return await withTaskGroup(of: (String, UInt64?).self) { group in
      let initialCount = min(4, uniqueNames.count)
      for name in uniqueNames.prefix(initialCount) {
        group.addTask {
          do {
            return (name, try await self.infrastructureClient.volumeDiskUsage(name: name))
          } catch {
            return (name, nil)
          }
        }
      }

      var nextIndex = initialCount
      var result: [String: UInt64] = [:]
      while let (name, size) = await group.next() {
        if let size {
          result[name] = size
        }
        if nextIndex < uniqueNames.count {
          let nextName = uniqueNames[nextIndex]
          nextIndex += 1
          group.addTask {
            do {
              return (
                nextName,
                try await self.infrastructureClient.volumeDiskUsage(name: nextName)
              )
            } catch {
              return (nextName, nil)
            }
          }
        }
      }
      return result
    }
  }

  private func loadCurrentVolumeRecords() async throws -> [VolumeRecord] {
    async let configurationRequest = infrastructureClient.listVolumes()
    async let containerRequest = containerClient.list()
    let (configurations, snapshots) = try await (configurationRequest, containerRequest)
    let allocatedSizes = await loadAllocatedVolumeSizes(names: configurations.map(\.name))

    let consumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for volumeName in snapshot.configuration.mounts.compactMap(\.volumeName) {
        result[volumeName, default: []].insert(snapshot.id)
      }
    }

    return configurations.map { configuration in
      VolumeRecord(
        id: configuration.id,
        name: configuration.name,
        driver: configuration.driver,
        format: configuration.format,
        source: configuration.source,
        createdAt: configuration.creationDate,
        sizeBytes: configuration.sizeInBytes,
        allocatedBytes: allocatedSizes[configuration.name],
        labels: configuration.labels,
        options: configuration.options,
        isAnonymous: configuration.isAnonymous,
        usedByContainerIDs: (consumers[configuration.name] ?? []).sorted()
      )
    }
  }

  private func currentVolumeRecord(name: String) async throws -> VolumeRecord? {
    async let configurationRequest = infrastructureClient.listVolumes()
    async let containerRequest = containerClient.list()
    let (configurations, snapshots) = try await (configurationRequest, containerRequest)
    guard let configuration = configurations.first(where: { $0.name == name }) else {
      return nil
    }

    let consumers = Set(
      snapshots.compactMap { snapshot in
        snapshot.configuration.mounts.contains(where: { $0.volumeName == name })
          ? snapshot.id
          : nil
      }
    )
    return VolumeRecord(
      id: configuration.id,
      name: configuration.name,
      driver: configuration.driver,
      format: configuration.format,
      source: configuration.source,
      createdAt: configuration.creationDate,
      sizeBytes: configuration.sizeInBytes,
      allocatedBytes: nil,
      labels: configuration.labels,
      options: configuration.options,
      isAnonymous: configuration.isAnonymous,
      usedByContainerIDs: consumers.sorted()
    )
  }

  private func loadCurrentNetworkRecords() async throws -> [NetworkRecord] {
    async let networkRequest = infrastructureClient.listNetworks()
    async let containerRequest = containerClient.list()
    let (networkResources, snapshots) = try await (networkRequest, containerRequest)

    let consumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for attachment in snapshot.configuration.networks {
        result[attachment.network, default: []].insert(snapshot.id)
      }
    }

    return networkResources.map { resource in
      NetworkRecord(
        id: resource.id,
        name: resource.name,
        mode: ContainerNetworkMode(rawValue: resource.configuration.mode.rawValue) ?? .nat,
        createdAt: resource.creationDate,
        configuredIPv4Subnet: resource.configuration.ipv4Subnet.map {
          String(describing: $0)
        },
        configuredIPv6Subnet: resource.configuration.ipv6Subnet.map {
          String(describing: $0)
        },
        assignedIPv4Subnet: String(describing: resource.status.ipv4Subnet),
        ipv4Gateway: String(describing: resource.status.ipv4Gateway),
        assignedIPv6Subnet: resource.status.ipv6Subnet.map { String(describing: $0) },
        labels: resource.labels.dictionary,
        plugin: resource.configuration.plugin,
        options: resource.configuration.options,
        isBuiltin: resource.isBuiltin,
        usedByContainerIDs: (consumers[resource.id] ?? []).sorted()
      )
    }
  }

  private func currentNetworkRecord(id: String) async throws -> NetworkRecord? {
    try await loadCurrentNetworkRecords().first { $0.id == id }
  }

  private nonisolated func volume(_ volume: VolumeRecord, matches request: VolumeCreateRequest) -> Bool {
    var expectedLabels = request.labels
    expectedLabels[ResourceOperationLabel.key] = request.operationID.uuidString
    let expectedOptions = [
      "size": "\(request.sizeBytes)B",
      "journal": request.journalMode.rawValue,
    ]
    return volume.name == request.name
      && volume.driver == "local"
      && volume.format == "ext4"
      && volume.sizeBytes == request.sizeBytes
      && volume.options == expectedOptions
      && volume.labels == expectedLabels
  }

  private nonisolated func network(_ network: NetworkRecord, matches request: NetworkCreateRequest) -> Bool {
    let expectedIPv4 = request.ipv4Subnet.flatMap { value in
      (try? CIDRv4(value)).map { String(describing: $0) }
    }
    let expectedIPv6 = request.ipv6Subnet.flatMap { value in
      (try? CIDRv6(value)).map { String(describing: $0) }
    }
    var expectedLabels = request.labels
    expectedLabels[ResourceOperationLabel.key] = request.operationID.uuidString
    return network.name == request.name
      && network.mode == request.mode
      && network.configuredIPv4Subnet == expectedIPv4
      && network.configuredIPv6Subnet == expectedIPv6
      && network.plugin == "container-network-vmnet"
      && network.options.isEmpty
      && network.labels == expectedLabels
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

private enum AppleContainerCleanupError: LocalizedError {
  case exhausted(id: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .exhausted(let id, let reason):
      "Could not remove owned container “\(id)”. \(reason)"
    }
  }
}

private enum AppleContainerServiceError: LocalizedError {
  case containerAlreadyExists(String)
  case builtinNetworkUnavailable
  case containerCleanupFailed(id: String, operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .containerAlreadyExists(let name):
      "A container named “\(name)” already exists."
    case .builtinNetworkUnavailable:
      "Apple’s built-in container network is unavailable."
    case .containerCleanupFailed(let id, let operation, let cleanup):
      "Container operation failed: \(operation) Automatic KILL and force deletion for “\(id)” also failed: \(cleanup)"
    }
  }
}

private actor AppleContainerProgressRelay {
  private let handler: ContainerProgressHandler
  private var phase: ContainerOperationProgress.Phase = .preparing
  private var message = "Preparing"
  private var submessage: String?
  private var completedItems = 0
  private var totalItems = 0
  private var transferredBytes: Int64 = 0
  private var totalBytes: Int64 = 0

  init(handler: @escaping ContainerProgressHandler) {
    self.handler = handler
  }

  func emit(phase: ContainerOperationProgress.Phase, message: String) async {
    self.phase = phase
    self.message = message
    submessage = nil
    completedItems = 0
    totalItems = 0
    transferredBytes = 0
    totalBytes = 0
    await publish()
  }

  func consume(_ events: [ProgressUpdateEvent]) async {
    for event in events {
      switch event {
      case .setDescription(let value):
        phase = Self.phase(for: value)
        message = value
        submessage = nil
        completedItems = 0
        totalItems = 0
        transferredBytes = 0
        totalBytes = 0
      case .setSubDescription(let value):
        submessage = value
      case .addItems(let value):
        completedItems += value
      case .setItems(let value):
        completedItems = value
      case .addTotalItems(let value):
        totalItems += value
      case .setTotalItems(let value):
        totalItems = value
      case .addSize(let value):
        transferredBytes += value
      case .setSize(let value):
        transferredBytes = value
      case .addTotalSize(let value):
        totalBytes += value
      case .setTotalSize(let value):
        totalBytes = value
      case .custom(let value):
        submessage = value
      case .addTasks, .setTasks, .addTotalTasks, .setTotalTasks, .setItemsName:
        break
      }
    }
    await publish()
  }

  private func publish() async {
    let displayMessage = submessage.map { "\(message) — \($0)" } ?? message
    await handler(
      ContainerOperationProgress(
        phase: phase,
        message: displayMessage,
        completedItems: max(completedItems, 0),
        totalItems: max(totalItems, 0),
        transferredBytes: max(transferredBytes, 0),
        totalBytes: max(totalBytes, 0)
      )
    )
  }

  private static func phase(for description: String) -> ContainerOperationProgress.Phase {
    switch description.lowercased() {
    case let value where value.contains("unpack") && value.contains("init"):
      .unpackingInitImage
    case let value where value.contains("fetch") && value.contains("init"):
      .fetchingInitImage
    case let value where value.contains("unpack"):
      .unpackingImage
    case let value where value.contains("kernel"):
      .fetchingKernel
    case let value where value.contains("push") || value.contains("upload"):
      .pushingImage
    case let value where value.contains("fetch") || value.contains("pull"):
      .fetchingImage
    default:
      .preparing
    }
  }
}
