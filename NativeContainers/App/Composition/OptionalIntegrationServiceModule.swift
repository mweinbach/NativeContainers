import ContainerAPIClient
import Foundation

struct OptionalIntegrationServiceModule: Sendable {
  let dockerCompatibility: any DockerCompatibilityManaging
  let dockerComposeClient: any DockerComposeClientInstalling
  let composeProjectLifecycle: any ComposeProjectLifecycleManaging

  static func live(
    containerClient: ContainerClient,
    infrastructure: any AppleInfrastructureTransport,
    inventory: any ContainerInventoryLoading,
    runtimeMutationCoordinator: RuntimeMutationCoordinator
  ) -> Self {
    let socktainerInstaller = SocktainerInstallService()
    let socktainerProcess = SocktainerProcessService()
    let dockerCompatibility = DockerCompatibilityService(
      installer: socktainerInstaller,
      process: socktainerProcess,
      dockerContext: DockerContextService(socketURL: socktainerProcess.socketURL)
    )
    let dockerComposeClient = DockerComposeClientInstallService()
    let composeConfigService = DockerComposeConfigService(
      composeClient: dockerComposeClient
    )
    let composeJournal = ComposeOperationJournal(
      directoryURL: FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0].appending(
        path: "NativeContainers-Compose-Operations",
        directoryHint: .isDirectory
      )
    )
    let composeExecutionWorkspace = FileComposeExecutionWorkspace()
    let composeMutationExecutor = AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: runtimeMutationCoordinator,
      containers: AppleComposeContainerMutationClient(client: containerClient),
      infrastructure: infrastructure,
      inventory: inventory,
      executionWorkspace: composeExecutionWorkspace,
      journal: composeJournal
    )
    let composeProjectLifecycle = ComposeProjectLifecycleService(
      configRenderer: composeConfigService,
      desiredStateDecoder: ComposeDesiredStateDecoder(
        allowsNativeContainersForkFeatures: false
      ),
      executionWorkspace: composeExecutionWorkspace,
      planner: ComposeLifecyclePlanner(
        allowsNativeContainersForkRecreation: false
      ),
      inventory: inventory,
      executionTool: composeConfigService,
      mutationExecutor: composeMutationExecutor,
      journal: composeJournal
    )

    return Self(
      dockerCompatibility: dockerCompatibility,
      dockerComposeClient: dockerComposeClient,
      composeProjectLifecycle: composeProjectLifecycle
    )
  }
}

struct DemandStartedOptionalIntegrationServices: Sendable {
  let dockerCompatibility: DemandStartedDockerCompatibilityService
  let dockerComposeClient: DemandStartedDockerComposeClientService
  let composeProjectLifecycle: DemandStartedComposeProjectLifecycleService

  init(
    factory: @escaping @Sendable () -> OptionalIntegrationServiceModule
  ) {
    let module = DemandStartedService(factory: factory)
    dockerCompatibility = DemandStartedDockerCompatibilityService(module: module)
    dockerComposeClient = DemandStartedDockerComposeClientService(module: module)
    composeProjectLifecycle = DemandStartedComposeProjectLifecycleService(module: module)
  }
}

struct DemandStartedDockerCompatibilityService: DockerCompatibilityManaging {
  private let module: DemandStartedService<OptionalIntegrationServiceModule>

  init(module: DemandStartedService<OptionalIntegrationServiceModule>) {
    self.module = module
  }

  var hasStarted: Bool { module.hasStarted }

  func snapshot() async -> DockerCompatibilitySnapshot {
    await module.resolve().dockerCompatibility.snapshot()
  }

  func installPinnedBridge() async throws {
    try await module.resolve().dockerCompatibility.installPinnedBridge()
  }

  func startBridge() async throws {
    try await module.resolve().dockerCompatibility.startBridge()
  }

  func stopBridge() async throws {
    try await module.resolve().dockerCompatibility.stopBridge()
  }

  func forceStopBridge() async throws {
    try await module.resolve().dockerCompatibility.forceStopBridge()
  }

  func removeStaleSocket() async throws {
    try await module.resolve().dockerCompatibility.removeStaleSocket()
  }

  func createOrRepairDockerContext() async throws {
    try await module.resolve().dockerCompatibility.createOrRepairDockerContext()
  }
}

struct DemandStartedDockerComposeClientService: DockerComposeClientInstalling {
  private let module: DemandStartedService<OptionalIntegrationServiceModule>

  init(module: DemandStartedService<OptionalIntegrationServiceModule>) {
    self.module = module
  }

  var hasStarted: Bool { module.hasStarted }
  var release: DockerComposeRelease { module.resolve().dockerComposeClient.release }
  var executableURL: URL { module.resolve().dockerComposeClient.executableURL }
  var provenanceURL: URL { module.resolve().dockerComposeClient.provenanceURL }

  func snapshot() async -> DockerComposeClientSnapshot {
    await module.resolve().dockerComposeClient.snapshot()
  }

  func installationState() async -> DockerComposeClientInstallationState {
    await module.resolve().dockerComposeClient.installationState()
  }

  func verifiedExecutableURL() async throws -> URL {
    try await module.resolve().dockerComposeClient.verifiedExecutableURL()
  }

  func install() async throws {
    try await module.resolve().dockerComposeClient.install()
  }
}

struct DemandStartedComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let module: DemandStartedService<OptionalIntegrationServiceModule>

  init(module: DemandStartedService<OptionalIntegrationServiceModule>) {
    self.module = module
  }

  var hasStarted: Bool { module.hasStarted }

  func discoverInputRequirements(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectInputRequirements {
    try await module.resolve().composeProjectLifecycle.discoverInputRequirements(
      directoryURL: directoryURL,
      options: options
    )
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    try await module.resolve().composeProjectLifecycle.review(
      directoryURL: directoryURL,
      options: options
    )
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions,
    inputs: ComposeProjectReviewInputs
  ) async throws -> ComposeProjectPlan {
    try await module.resolve().composeProjectLifecycle.review(
      directoryURL: directoryURL,
      options: options,
      inputs: inputs
    )
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    try await module.resolve().composeProjectLifecycle.execute(plan)
  }

  func discardInputRequirements(_ requirementsID: UUID) async {
    await module.resolve().composeProjectLifecycle.discardInputRequirements(requirementsID)
  }

  func discardReview(planID: UUID) async {
    await module.resolve().composeProjectLifecycle.discardReview(planID: planID)
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] {
    try await module.resolve().composeProjectLifecycle.pendingRecoverySnapshots()
  }

  func discardRecoveryAfterReview(operationID: UUID) async throws {
    try await module.resolve().composeProjectLifecycle.discardRecoveryAfterReview(
      operationID: operationID
    )
  }
}
