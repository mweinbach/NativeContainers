import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveComposeProjectLifecycleSmokeTests {
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_SOCKTAINER"] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_COMPOSE_LIFECYCLE"
        ] == "1",
      "Set both NATIVECONTAINERS_LIVE_SOCKTAINER=1 and NATIVECONTAINERS_LIVE_COMPOSE_LIFECYCLE=1 with Apple container 1.0.0 running, Alpine 3.20 local, the verified Compose client installed, and NATIVECONTAINERS_SOCKTAINER_BINARY set to the pinned bridge."
    )
  )
  func reviewedLifecycleRunsUpStopStartDownAndCleansEveryArtifact() async throws {
    let processEnvironment = ProcessInfo.processInfo.environment
    guard
      let binaryPath = processEnvironment["NATIVECONTAINERS_SOCKTAINER_BINARY"],
      !binaryPath.isEmpty
    else {
      throw LiveComposeLifecycleSmokeError(
        "NATIVECONTAINERS_SOCKTAINER_BINARY must explicitly name the pinned bridge."
      )
    }
    let binaryURL = URL(filePath: binaryPath)
    try SocktainerArtifactValidator().validate(
      artifactURL: binaryURL,
      release: .pinned
    )
    guard
      await AppleContainerHealthVersionChecker().compatibility(requiredVersion: "1.0.0")
        == .compatible(version: "1.0.0")
    else {
      throw LiveComposeLifecycleSmokeError(
        "Apple container 1.0.0 is not healthy."
      )
    }

    let rootURL = URL(filePath: "/tmp", directoryHint: .isDirectory).appending(
      path: "nc-lc-(UUID().uuidString.lowercased().prefix(8))",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    guard chmod(rootURL.nativeContainersPOSIXPath, 0o700) == 0 else {
      throw LiveComposeLifecycleSmokeError("The private fixture root could not be secured.")
    }

    let projectName = "ncwire-(UUID().uuidString.lowercased().prefix(8))"
    let socketURL =
      rootURL
      .appending(path: ".socktainer", directoryHint: .isDirectory)
      .appending(path: "container.sock", directoryHint: .notDirectory)
    let dockerConfigURL = rootURL.appending(
      path: ".docker",
      directoryHint: .isDirectory
    )
    let temporaryURL = rootURL.appending(path: "tmp", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )

    var isolatedEnvironment = processEnvironment
    isolatedEnvironment["HOME"] = rootURL.nativeContainersPOSIXPath
    isolatedEnvironment["DOCKER_CONFIG"] = dockerConfigURL.nativeContainersPOSIXPath
    isolatedEnvironment["TMPDIR"] = temporaryURL.nativeContainersPOSIXPath

    let process = SocktainerProcessService(
      socketURL: socketURL,
      environment: isolatedEnvironment,
      startupTimeout: .seconds(15)
    )
    let commandExecutor = FoundationHostCommandExecutor()
    let context = DockerContextService(
      socketURL: socketURL,
      commandExecutor: commandExecutor,
      environment: isolatedEnvironment
    )
    let composeClient = DockerComposeClientInstallService()
    _ = try await composeClient.verifiedExecutableURL()
    let configService = DockerComposeConfigService(
      composeClient: composeClient,
      commandExecutor: commandExecutor,
      processEnvironment: isolatedEnvironment
    )
    let inventory = AppleRuntimeInventoryService()
    let journal = ComposeOperationJournal(
      directoryURL: rootURL.appending(path: "Journal", directoryHint: .isDirectory)
    )
    let executionRootURL = rootURL.appending(
      path: "Execution",
      directoryHint: .isDirectory
    )
    let mutationExecutor = AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      inventory: inventory,
      commandExecutor: commandExecutor,
      executionWorkspace: FileComposeExecutionWorkspace(rootURL: executionRootURL),
      journal: journal
    )
    let lifecycle = ComposeProjectLifecycleService(
      configRenderer: configService,
      inventory: inventory,
      executionTool: configService,
      mutationExecutor: mutationExecutor,
      journal: journal
    )
    let fixture = try SocktainerComposeLiveFixtureConfiguration(
      projectName: projectName,
      workspaceURL: rootURL,
      composeExecutableURL: composeClient.executableURL,
      environment: isolatedEnvironment
    )
    let composeFileURL = rootURL.appending(
      path: "compose.yaml",
      directoryHint: .notDirectory
    )
    try liveLifecycleComposeYAML(fixture).write(
      to: composeFileURL,
      atomically: true,
      encoding: .utf8
    )
    guard chmod(composeFileURL.nativeContainersPOSIXPath, 0o600) == 0 else {
      throw LiveComposeLifecycleSmokeError("The fixture Compose file could not be secured.")
    }

    var operationFailure: String?
    do {
      try await process.start(executableURL: binaryURL)
      guard case .running = await process.status() else {
        throw LiveComposeLifecycleSmokeError(
          "Socktainer did not remain running after readiness."
        )
      }
      try await context.createOrRepairContext()
      guard (await context.status()).state == .ready else {
        throw LiveComposeLifecycleSmokeError(
          "The isolated NativeContainers Docker context is not ready."
        )
      }

      let upPlan = try await lifecycle.review(
        directoryURL: rootURL,
        options: ComposeProjectReviewOptions(
          action: .up,
          projectName: projectName,
          pullPolicy: .never
        )
      )
      try requireExecutable(upPlan)
      _ = try await lifecycle.execute(upPlan)
      let runningInventory = try await waitForLiveFixture(
        inventory: inventory,
        fixture: fixture
      ) { snapshot in
        snapshot.containers.contains {
          $0.id == fixture.containerName && $0.state == .running
        }
      }
      let runningContainer = try requireLiveContainer(
        in: runningInventory,
        fixture: fixture,
        expectedConfigurationHash: upPlan.serviceConfigurationHashes["probe"]
      )
      let frozenIdentity = ComposeProjectContainerIdentity(runningContainer)
      try requireLiveAttachments(in: runningInventory, fixture: fixture)
      try await requireEmptyJournal(journal)
      try requireEmptyExecutionWorkspace(executionRootURL)

      let stopPlan = try await lifecycle.review(
        directoryURL: rootURL,
        options: ComposeProjectReviewOptions(
          action: .stop,
          projectName: projectName,
          pullPolicy: .never
        )
      )
      try requireExecutable(stopPlan)
      _ = try await lifecycle.execute(stopPlan)
      let stoppedInventory = try await waitForLiveFixture(
        inventory: inventory,
        fixture: fixture
      ) { snapshot in
        snapshot.containers.contains {
          $0.id == fixture.containerName
            && $0.state != .running
            && $0.state != .stopping
        }
      }
      let stoppedContainer = try requireLiveContainer(
        in: stoppedInventory,
        fixture: fixture,
        expectedConfigurationHash: upPlan.serviceConfigurationHashes["probe"]
      )
      guard frozenIdentity.matches(stoppedContainer) else {
        throw LiveComposeLifecycleSmokeError(
          "Stop changed the reviewed container identity."
        )
      }
      try await requireEmptyJournal(journal)

      let startPlan = try await lifecycle.review(
        directoryURL: rootURL,
        options: ComposeProjectReviewOptions(
          action: .start,
          projectName: projectName,
          pullPolicy: .never
        )
      )
      try requireExecutable(startPlan)
      _ = try await lifecycle.execute(startPlan)
      let restartedInventory = try await waitForLiveFixture(
        inventory: inventory,
        fixture: fixture
      ) { snapshot in
        snapshot.containers.contains {
          $0.id == fixture.containerName && $0.state == .running
        }
      }
      let restartedContainer = try requireLiveContainer(
        in: restartedInventory,
        fixture: fixture,
        expectedConfigurationHash: upPlan.serviceConfigurationHashes["probe"]
      )
      guard frozenIdentity.matches(restartedContainer) else {
        throw LiveComposeLifecycleSmokeError(
          "Start changed the reviewed container identity."
        )
      }
      try await requireEmptyJournal(journal)

      let downPlan = try await lifecycle.review(
        directoryURL: rootURL,
        options: ComposeProjectReviewOptions(
          action: .down,
          projectName: projectName,
          pullPolicy: .never,
          removeOrphans: true,
          removeVolumes: true
        )
      )
      try requireExecutable(downPlan)
      _ = try await lifecycle.execute(downPlan)
      try await waitForLiveFixtureAbsence(inventory: inventory, fixture: fixture)
      try await requireEmptyJournal(journal)
    } catch {
      operationFailure = error.localizedDescription
    }

    let cleanupFailure = await Task.detached {
      await cleanLiveLifecycleFixture(
        fixture: fixture,
        inventory: inventory,
        journal: journal,
        process: process,
        socketURL: socketURL,
        rootURL: rootURL
      )
    }.value

    if let operationFailure, let cleanupFailure {
      throw LiveComposeLifecycleSmokeError(
        "Lifecycle failed: (operationFailure) Cleanup failed: (cleanupFailure)"
      )
    }
    if let operationFailure {
      throw LiveComposeLifecycleSmokeError(operationFailure)
    }
    if let cleanupFailure {
      throw LiveComposeLifecycleSmokeError(cleanupFailure)
    }
  }
}

private struct LiveComposeLifecycleSmokeError: LocalizedError, Sendable {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

private func liveLifecycleComposeYAML(
  _ fixture: SocktainerComposeLiveFixtureConfiguration
) -> String {
  """
  services:
    probe:
      image: docker.io/library/alpine:3.20
      container_name: (fixture.containerName)
      command: ["sh", "-c", "trap 'exit 0' TERM INT; while true; do sleep 1; done"]
      volumes:
        - data:/fixture
      networks:
        - default
  volumes:
    data:
      name: (fixture.volumeName)
  networks:
    default:
      name: (fixture.networkName)
  """
}

private func requireExecutable(_ plan: ComposeProjectPlan) throws {
  guard plan.canExecute else {
    let reasons = plan.blockers.map(\.message).joined(separator: " ")
    throw LiveComposeLifecycleSmokeError(
      "Reviewed (plan.options.action.rawValue) was blocked. (reasons)"
    )
  }
}

private func requireLiveContainer(
  in inventory: ContainerInventory,
  fixture: SocktainerComposeLiveFixtureConfiguration,
  expectedConfigurationHash: String?
) throws -> ContainerRecord {
  let matches = inventory.containers.filter { $0.id == fixture.containerName }
  guard
    matches.count == 1,
    let container = matches.first,
    container.labels[ComposeLabelKey.project] == fixture.projectName,
    container.labels[ComposeLabelKey.service] == "probe",
    container.labels[ComposeLabelKey.containerNumber] == "1",
    container.labels[ComposeLabelKey.oneOff]?.lowercased() == "false",
    expectedConfigurationHash == nil
      || container.labels[ComposeLabelKey.configHash] == expectedConfigurationHash,
    container.imageReference == "docker.io/library/alpine:3.20",
    container.imageDigest != nil
  else {
    throw LiveComposeLifecycleSmokeError(
      "Apple inventory did not expose the exact reviewed probe container."
    )
  }
  return container
}

private func requireLiveAttachments(
  in inventory: ContainerInventory,
  fixture: SocktainerComposeLiveFixtureConfiguration
) throws {
  guard
    let volume = inventory.volumes.first(where: { $0.name == fixture.volumeName }),
    volume.labels[ComposeLabelKey.project] == fixture.projectName,
    volume.labels[ComposeLabelKey.volume] == "data",
    volume.usedByContainerIDs == [fixture.containerName],
    let network = inventory.networks.first(where: { $0.name == fixture.networkName }),
    network.labels[ComposeLabelKey.project] == fixture.projectName,
    network.labels[ComposeLabelKey.network] == "default",
    network.usedByContainerIDs == [fixture.containerName]
  else {
    throw LiveComposeLifecycleSmokeError(
      "Apple inventory did not expose the exact reviewed volume and network attachments."
    )
  }
}

private func requireEmptyJournal(
  _ journal: ComposeOperationJournal
) async throws {
  guard try await journal.pendingRecoverySnapshots().isEmpty else {
    throw LiveComposeLifecycleSmokeError(
      "A successful lifecycle stage left a pending operation journal."
    )
  }
}

private func requireEmptyExecutionWorkspace(_ rootURL: URL) throws {
  guard FileManager.default.fileExists(atPath: rootURL.nativeContainersPOSIXPath) else {
    return
  }
  guard
    try FileManager.default.contentsOfDirectory(
      atPath: rootURL.nativeContainersPOSIXPath
    ).isEmpty
  else {
    throw LiveComposeLifecycleSmokeError(
      "A successful Up left a staged execution operation directory."
    )
  }
}

private func waitForLiveFixture(
  inventory: AppleRuntimeInventoryService,
  fixture: SocktainerComposeLiveFixtureConfiguration,
  predicate: (ContainerInventory) -> Bool
) async throws -> ContainerInventory {
  var lastInventory: ContainerInventory?
  for attempt in 0..<fixture.observationAttempts {
    let snapshot = try await inventory.loadInventory()
    lastInventory = snapshot
    if predicate(snapshot) {
      return snapshot
    }
    if attempt + 1 < fixture.observationAttempts {
      try await Task.sleep(for: fixture.pollInterval)
    }
  }
  throw LiveComposeLifecycleSmokeError(
    "The lifecycle state did not converge in Apple inventory. Last container count: (lastInventory?.containers.count ?? 0)."
  )
}

private func waitForLiveFixtureAbsence(
  inventory: AppleRuntimeInventoryService,
  fixture: SocktainerComposeLiveFixtureConfiguration
) async throws {
  _ = try await waitForLiveFixture(
    inventory: inventory,
    fixture: fixture
  ) { snapshot in
    !snapshot.containers.contains { $0.id == fixture.containerName }
      && !snapshot.volumes.contains { $0.name == fixture.volumeName }
      && !snapshot.networks.contains { $0.name == fixture.networkName }
      && !snapshot.containers.contains {
        $0.labels[ComposeLabelKey.project] == fixture.projectName
      }
      && !snapshot.volumes.contains {
        $0.labels[ComposeLabelKey.project] == fixture.projectName
      }
      && !snapshot.networks.contains {
        $0.labels[ComposeLabelKey.project] == fixture.projectName
      }
  }
}

private func cleanLiveLifecycleFixture(
  fixture: SocktainerComposeLiveFixtureConfiguration,
  inventory: AppleRuntimeInventoryService,
  journal: ComposeOperationJournal,
  process: SocktainerProcessService,
  socketURL: URL,
  rootURL: URL
) async -> String? {
  var failures: [String] = []
  do {
    let planner = SocktainerComposeFixtureCleanupPlanner()
    let nativeCleanup = AppleSocktainerComposeFixtureNativeCleanup()
    let plan = try planner.plan(
      from: try await inventory.loadInventory(),
      configuration: fixture
    )

    if let identity = plan.container {
      let current = try await inventory.loadInventory()
      if let container = current.containers.first(where: { $0.id == identity.id }) {
        guard identity.matches(container) else {
          throw LiveComposeLifecycleSmokeError(
            "Cleanup refused a replacement container."
          )
        }
        try await nativeCleanup.removeContainer(container)
      }
    }
    if let identity = plan.network {
      let current = try await inventory.loadInventory()
      if let network = current.networks.first(where: { $0.id == identity.id }) {
        guard identity.matches(network) else {
          throw LiveComposeLifecycleSmokeError(
            "Cleanup refused a replacement network."
          )
        }
        try await nativeCleanup.removeNetwork(network)
      }
    }
    if let identity = plan.volume {
      let current = try await inventory.loadInventory()
      if let volume = current.volumes.first(where: { $0.id == identity.id }) {
        guard identity.matches(volume) else {
          throw LiveComposeLifecycleSmokeError(
            "Cleanup refused a replacement volume."
          )
        }
        try await nativeCleanup.removeVolume(volume)
      }
    }

    try await waitForLiveFixtureAbsence(inventory: inventory, fixture: fixture)
    for recovery in try await journal.pendingRecoverySnapshots() {
      try await journal.discardPendingAfterReview(operationID: recovery.operationID)
    }
  } catch {
    failures.append(error.localizedDescription)
  }

  do {
    try await process.forceStop()
  } catch {
    failures.append("Socktainer stop: (error.localizedDescription)")
  }
  if FileManager.default.fileExists(atPath: socketURL.nativeContainersPOSIXPath) {
    failures.append("Socktainer socket remained after cleanup.")
  }

  if failures.isEmpty {
    do {
      try FileManager.default.removeItem(at: rootURL)
    } catch {
      failures.append("Workspace removal: (error.localizedDescription)")
    }
  }
  return failures.isEmpty ? nil : failures.joined(separator: " ")
}
