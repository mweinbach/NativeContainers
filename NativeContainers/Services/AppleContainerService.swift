import ContainerAPIClient
import Foundation
import MachineAPIClient

actor AppleContainerService: ContainerManaging {
  private let inventoryService: AppleRuntimeInventoryService
  private let infrastructureService: AppleInfrastructureService
  private let lifecycleService: AppleContainerLifecycleService
  private let inspectionService: AppleContainerInspectionService
  private let toolService: AppleContainerToolService
  private let terminalService: AppleContainerTerminalService
  private let machineLifecycleService: AppleMachineLifecycleService
  private let creationService: AppleContainerCreationService
  private let imageService: AppleImageService

  init(
    terminalProcessLauncher: (any ContainerTerminalProcessLaunching)? = nil,
    containerClient: ContainerClient = ContainerClient(),
    machineClient: MachineClient = MachineClient(),
    infrastructureClient: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    containerCleanupClient: any AppleContainerCleanupTransport = AppleContainerCleanupClient(),
    inventoryService: AppleRuntimeInventoryService? = nil,
    infrastructureService: AppleInfrastructureService? = nil,
    lifecycleService: AppleContainerLifecycleService? = nil,
    inspectionService: AppleContainerInspectionService? = nil,
    toolService: AppleContainerToolService? = nil,
    terminalService: AppleContainerTerminalService? = nil,
    machineLifecycleService: AppleMachineLifecycleService? = nil,
    creationService: AppleContainerCreationService? = nil,
    imageService: AppleImageService? = nil,
    ownedContainerRecovery: AppleOwnedContainerRecoveryService? = nil,
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    let containerReader = AppleContainerSnapshotReader(client: containerClient)
    let resolvedInventoryService =
      inventoryService
      ?? AppleRuntimeInventoryService(
        infrastructureClient: infrastructureClient,
        containerReader: containerReader,
        machineClient: machineClient
      )
    let resolvedInfrastructureService =
      infrastructureService
      ?? AppleInfrastructureService(
        infrastructureClient: infrastructureClient,
        containerReader: containerReader,
        runtimeMutationCoordinator: runtimeMutationCoordinator
      )
    let resolvedLifecycleService =
      lifecycleService ?? AppleContainerLifecycleService(containerClient: containerClient)
    let resolvedInspectionService =
      inspectionService ?? AppleContainerInspectionService(containerClient: containerClient)
    let resolvedToolService =
      toolService ?? AppleContainerToolService(containerClient: containerClient)
    let resolvedTerminalService =
      terminalService
      ?? AppleContainerTerminalService(
        terminalProcessLauncher: terminalProcessLauncher
          ?? AppleContainerTerminalProcessLauncher(containerClient: containerClient)
      )
    let resolvedMachineLifecycleService =
      machineLifecycleService ?? AppleMachineLifecycleService(machineClient: machineClient)
    let resolvedImageService =
      imageService
      ?? AppleImageService(
        containerReader: containerReader,
        runtimeMutationCoordinator: runtimeMutationCoordinator
      )
    let resolvedRecoveryService =
      ownedContainerRecovery
      ?? AppleOwnedContainerRecoveryService(
        cleanupClient: containerCleanupClient,
        ownershipLabel: AppleContainerOwnership.creationOperationLabel
      )

    self.inventoryService = resolvedInventoryService
    self.infrastructureService = resolvedInfrastructureService
    self.lifecycleService = resolvedLifecycleService
    self.inspectionService = resolvedInspectionService
    self.toolService = resolvedToolService
    self.terminalService = resolvedTerminalService
    self.machineLifecycleService = resolvedMachineLifecycleService
    self.creationService =
      creationService
      ?? AppleContainerCreationService(
        containerClient: containerClient,
        infrastructureService: resolvedInfrastructureService,
        lifecycleService: resolvedLifecycleService,
        ownedContainerRecovery: resolvedRecoveryService,
        runtimeMutationCoordinator: runtimeMutationCoordinator
      )
    self.imageService = resolvedImageService
  }

  func loadInventory() async throws -> ContainerInventory {
    try await inventoryService.loadInventory()
  }

  func startContainer(id: String) async throws {
    try await lifecycleService.startContainer(id: id)
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    try await imageService.prepareImagePull(
      reference: reference,
      platform: platform,
      transport: transport,
      unpackAfterPull: unpackAfterPull,
      maxConcurrentDownloads: maxConcurrentDownloads
    )
  }

  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    try await imageService.pullImage(
      plan,
      authorization: authorization,
      progress: progress
    )
  }

  func inspectImage(reference: String) async throws -> ImageInspection {
    try await imageService.inspectImage(reference: reference)
  }

  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    try await imageService.prepareImageTag(source: source, target: target)
  }

  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {
    try await imageService.tagImage(plan, replacingExisting: replacingExisting)
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    try await imageService.prepareImageDeletion(reference: reference)
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    try await imageService.deleteImage(plan)
  }

  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    try await imageService.prepareImagePrune(mode: mode)
  }

  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    try await imageService.pruneImages(plan)
  }

  func prepareImagePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    try await imageService.prepareImagePush(
      reference: reference,
      platform: platform,
      transport: transport
    )
  }

  func pushImage(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    try await imageService.pushImage(
      plan,
      authorization: authorization,
      progress: progress
    )
  }

  func prepareVolumeCreation(_ request: VolumeCreateRequest) async throws -> VolumeCreationPlan {
    try await infrastructureService.prepareVolumeCreation(request)
  }

  func createVolume(_ plan: VolumeCreationPlan) async throws -> VolumeRecord {
    try await infrastructureService.createVolume(plan)
  }

  func prepareVolumeDeletion(name: String) async throws -> VolumeDeletionPlan {
    try await infrastructureService.prepareVolumeDeletion(name: name)
  }

  func deleteVolume(_ plan: VolumeDeletionPlan) async throws {
    try await infrastructureService.deleteVolume(plan)
  }

  func prepareVolumePrune() async throws -> VolumePrunePlan {
    try await infrastructureService.prepareVolumePrune()
  }

  func pruneVolumes(_ plan: VolumePrunePlan) async throws -> ResourceCleanupResult {
    try await infrastructureService.pruneVolumes(plan)
  }

  func prepareNetworkCreation(_ request: NetworkCreateRequest) async throws -> NetworkCreationPlan {
    try await infrastructureService.prepareNetworkCreation(request)
  }

  func createNetwork(_ plan: NetworkCreationPlan) async throws -> NetworkRecord {
    try await infrastructureService.createNetwork(plan)
  }

  func prepareNetworkDeletion(id: String) async throws -> NetworkDeletionPlan {
    try await infrastructureService.prepareNetworkDeletion(id: id)
  }

  func deleteNetwork(_ plan: NetworkDeletionPlan) async throws {
    try await infrastructureService.deleteNetwork(plan)
  }

  func prepareNetworkPrune() async throws -> NetworkPrunePlan {
    try await infrastructureService.prepareNetworkPrune()
  }

  func pruneNetworks(_ plan: NetworkPrunePlan) async throws -> ResourceCleanupResult {
    try await infrastructureService.pruneNetworks(plan)
  }

  func resolveContainerBrowserURL(_ target: ContainerBrowserTarget) async throws -> URL {
    try await infrastructureService.resolveContainerBrowserURL(target)
  }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    try await creationService.createContainer(request: request, progress: progress)
  }

  func inspectContainer(id: String) async throws -> ContainerInspection {
    try await inspectionService.inspectContainer(id: id)
  }

  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    try await inspectionService.sampleContainer(id: id)
  }

  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    try await inspectionService.loadContainerLogs(id: id)
  }

  func stopContainer(id: String) async throws {
    try await lifecycleService.stopContainer(id: id)
  }

  func restartContainer(id: String) async throws {
    try await lifecycleService.restartContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try await lifecycleService.forceStopContainer(id: id)
  }

  func deleteContainer(id: String) async throws {
    try await lifecycleService.deleteContainer(id: id)
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    try await toolService.executeCommand(in: id, request: request)
  }

  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    try await terminalService.openTerminal(in: id, request: request)
  }

  func copyIntoContainer(id: String, source: URL, destination: String) async throws {
    try await toolService.copyIntoContainer(id: id, source: source, destination: destination)
  }

  func copyFromContainer(id: String, source: String, destination: URL) async throws {
    try await toolService.copyFromContainer(id: id, source: source, destination: destination)
  }

  func startMachine(id: String) async throws {
    try await machineLifecycleService.startMachine(id: id)
  }

  func stopMachine(id: String) async throws {
    try await machineLifecycleService.stopMachine(id: id)
  }

  func deleteMachine(id: String) async throws {
    try await machineLifecycleService.deleteMachine(id: id)
  }

}
