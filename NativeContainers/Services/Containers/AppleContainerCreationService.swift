import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

actor AppleContainerCreationService: ContainerCreating {
  private let containerClient: ContainerClient
  private let attachmentService: any ContainerAttachmentManaging
  private let lifecycleService: any ContainerLifecycleManaging
  private let ownedContainerRecovery: any OwnedContainerRecovering
  private let sshAgentService: any ContainerSSHAgentForwardingManaging
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    containerClient: ContainerClient = ContainerClient(),
    attachmentService: any ContainerAttachmentManaging = AppleContainerAttachmentService(),
    lifecycleService: any ContainerLifecycleManaging = AppleContainerLifecycleService(),
    ownedContainerRecovery: any OwnedContainerRecovering = AppleOwnedContainerRecoveryService(
      ownershipLabel: AppleContainerOwnership.creationOperationLabel
    ),
    sshAgentService: any ContainerSSHAgentForwardingManaging =
      AppleContainerSSHAgentService(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.containerClient = containerClient
    self.attachmentService = attachmentService
    self.lifecycleService = lifecycleService
    self.ownedContainerRecovery = ownedContainerRecovery
    self.sshAgentService = sshAgentService
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
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
        try await ownedContainerRecovery.removeOwnedContainer(
          id: request.name,
          operationID: request.operationID
        )
      } catch {
        await attachmentService.cleanupAttachmentWorkspace(
          operationID: request.operationID
        )
        throw AppleContainerCreationError.containerCleanupFailed(
          id: request.name,
          operation: operationMessage,
          cleanup: error.localizedDescription
        )
      }
      await attachmentService.cleanupAttachmentWorkspace(
        operationID: request.operationID
      )
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
      throw AppleContainerCreationError.containerAlreadyExists(request.name)
    }

    if let sshAgent = request.sshAgent {
      _ = try sshAgentService.environment(for: sshAgent)
    }

    let systemConfiguration = try await loadSystemConfiguration()
    let resolvedAttachments = try await attachmentService.resolveAttachments(
      request.attachments,
      operationID: request.operationID,
      containerID: request.name,
      dnsDomain: systemConfiguration.dns.domain
    )
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
    var ownershipLabels = [
      AppleContainerOwnership.creationOperationLabel: request.operationID.uuidString
    ]
    if !request.attachments.hostDirectoryMounts.isEmpty {
      ownershipLabels[AppleContainerOwnership.hostDirectoryAttachmentLabel] = "true"
    }
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
      labels: ownershipLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
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
    configuration.labels = ownershipLabels
    configuration.mounts = resolvedAttachments.mounts
    configuration.networks = resolvedAttachments.networks
    configuration.publishedSockets = resolvedAttachments.publishedSockets
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
      try await lifecycleService.startContainer(id: request.name)
    }
    try Task.checkCancellation()
    await relay.emit(phase: .completed, message: "Container ready")
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

private enum AppleContainerCreationError: LocalizedError {
  case containerAlreadyExists(String)
  case containerCleanupFailed(id: String, operation: String, cleanup: String)

  var errorDescription: String? {
    switch self {
    case .containerAlreadyExists(let name):
      "A container named “\(name)” already exists."
    case .containerCleanupFailed(let id, let operation, let cleanup):
      "Container operation failed: \(operation) Automatic KILL and force deletion for “\(id)” also failed: \(cleanup)"
    }
  }
}
