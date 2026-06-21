import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ComposeProjectMutationExecutorTests {
  @Test
  func startsExactContainersInDependencyOrderAndFinishesJournal() async throws {
    let database = mutationContainer(
      id: "database-1",
      service: "database",
      replica: 1,
      state: .stopped
    )
    let web = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .stopped
    )
    let state = ComposeMutationState(
      snapshots: [
        mutationSnapshot(database),
        mutationSnapshot(web),
      ]
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(
      action: .start,
      records: [web, database],
      dependencies: ["web": ["database"], "database": []]
    )

    let result = try await executor.execute(mutationRequest(plan))

    #expect(result.remainingContainerCount == 2)
    #expect(await state.startIDs == ["database-1", "web-1"])
    #expect(await journal.phases == [.executing, .executing, .executing, .verifying, .finished])
  }

  @Test
  func gracefulStopLeavesStuckContainerRunningWhenAutomaticKillIsDisabled() async throws {
    let record = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .running
    )
    let state = ComposeMutationState(
      snapshots: [mutationSnapshot(record)],
      gracefulSignalStopsContainer: false
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(
      action: .stop,
      records: [record],
      killStuckContainers: false
    )

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await executor.execute(mutationRequest(plan))
    }

    #expect(await state.signals == ["web-1:TERM"])
    #expect(await state.currentRecords.first?.state == .running)
    #expect(await journal.phases == [.executing])
  }

  @Test
  func gracefulStopRevalidatesBeforeOptionalKillAndConfirmsExit() async throws {
    let record = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .running
    )
    let state = ComposeMutationState(
      snapshots: [mutationSnapshot(record)],
      gracefulSignalStopsContainer: false
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(
      action: .stop,
      records: [record],
      killStuckContainers: true
    )

    _ = try await executor.execute(mutationRequest(plan))

    #expect(await state.signals == ["web-1:TERM", "web-1:KILL"])
    #expect(await state.currentRecords.first?.state == .stopped)
    #expect(await journal.phases.last == .finished)
  }

  @Test
  func sameIDReplacementBeforeDeleteIsNeverMutated() async throws {
    let original = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .stopped
    )
    let replacement = ContainerRecord(
      id: original.id,
      imageReference: original.imageReference,
      imageDigest: original.imageDigest,
      platform: original.platform,
      state: .stopped,
      ipAddress: nil,
      createdAt: original.createdAt.addingTimeInterval(1),
      startedAt: nil,
      cpuCount: original.cpuCount,
      memoryBytes: original.memoryBytes,
      ports: [],
      labels: original.labels
    )
    let state = ComposeMutationState(
      snapshots: [mutationSnapshot(original)],
      replacementAfterListCount: 1,
      replacementSnapshot: mutationSnapshot(replacement)
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(action: .down, records: [original])

    await #expect(throws: ComposeProjectLifecycleError.observedStateChanged) {
      _ = try await executor.execute(mutationRequest(plan))
    }

    #expect(await state.deleteIDs.isEmpty)
    #expect(await state.currentRecords == [replacement])
  }

  @Test
  func commandFailureStillRemovesPrivateFreshUpWorkspaceAndLeavesJournalPending() async throws {
    let state = ComposeMutationState(snapshots: [])
    let journal = MutationJournalDouble()
    let workspace = MutationWorkspaceDouble()
    let command = MutationCommandDouble(
      result: HostCommandResult(
        exitCode: 1,
        standardOutput: "",
        standardError: "daemon unavailable",
        outputWasTruncated: false
      )
    )
    let executor = AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      containers: MutationContainerTransport(state: state),
      inventory: MutationInventoryLoader(state: state),
      commandExecutor: command,
      executionWorkspace: workspace,
      journal: journal,
      sleeper: ImmediateMutationSleeper(),
      timing: ComposeMutationTiming(
        gracefulPollAttempts: 1,
        confirmationPollAttempts: 1,
        pollInterval: .zero
      )
    )
    let plan = mutationPlan(action: .up, records: [])

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await executor.execute(mutationRequest(plan))
    }

    #expect(workspace.prepareCount == 1)
    #expect(workspace.removeCount == 1)
    #expect(await command.arguments.first?.prefix(2) == ["--context", "nativecontainers"])
    #expect(await journal.phases == [.executing])
  }

  @Test
  func exactExistingUpStartsReviewedIdentityWithoutComposeCommand() async throws {
    let record = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .stopped
    )
    let state = ComposeMutationState(snapshots: [mutationSnapshot(record)])
    let journal = MutationJournalDouble()
    let command = MutationCommandDouble(
      result: HostCommandResult(
        exitCode: 99,
        standardOutput: "",
        standardError: "must not run",
        outputWasTruncated: false
      )
    )
    let executor = makeExecutor(state: state, journal: journal, commandExecutor: command)
    let plan = mutationPlan(action: .up, records: [record])

    _ = try await executor.execute(mutationRequest(plan))

    #expect(await state.startIDs == ["web-1"])
    #expect(await command.arguments.isEmpty)
    #expect(await journal.completedStepTokens.last == ["container-0001"])
  }

  @Test
  func downDeletesTypedOrphanAndNamedVolumeOnlyAfterExactRevalidation() async throws {
    let declared = mutationContainer(
      id: "web-1",
      service: "web",
      replica: 1,
      state: .stopped
    )
    let orphan = mutationContainer(
      id: "legacy-1",
      service: "legacy",
      replica: 1,
      state: .stopped
    )
    let volume = mutationVolume(name: "sample_data", consumers: [])
    let state = ComposeMutationState(
      snapshots: [mutationSnapshot(declared), mutationSnapshot(orphan)],
      volumes: [volume]
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(
      action: .down,
      records: [declared, orphan],
      orphanIDs: [orphan.id],
      volumes: [volume],
      removeOrphans: true,
      removeVolumes: true
    )

    let result = try await executor.execute(mutationRequest(plan))

    #expect(result.remainingContainerCount == 0)
    #expect(result.remainingVolumeCount == 0)
    #expect(await state.deleteIDs == ["web-1", "legacy-1"])
    #expect(await state.deletedVolumeNames == ["sample_data"])
    #expect(
      await journal.completedStepTokens.last
        == ["container-0001", "container-0002", "volume-0001"]
    )
  }

  @Test
  func lateVolumeConsumerPreventsNameOnlyDeletion() async throws {
    let volume = mutationVolume(name: "sample_data", consumers: [])
    let usedVolume = mutationVolume(name: "sample_data", consumers: ["foreign-container"])
    let state = ComposeMutationState(
      snapshots: [],
      volumes: [volume],
      replacementVolumeAfterInventoryCount: 1,
      replacementVolume: usedVolume
    )
    let journal = MutationJournalDouble()
    let executor = makeExecutor(state: state, journal: journal)
    let plan = mutationPlan(
      action: .down,
      records: [],
      volumes: [volume],
      removeVolumes: true
    )

    await #expect(throws: ComposeProjectLifecycleError.observedStateChanged) {
      _ = try await executor.execute(mutationRequest(plan))
    }

    #expect(await state.deletedVolumeNames.isEmpty)
    #expect(await state.currentVolumes == [usedVolume])
  }

  private func makeExecutor(
    state: ComposeMutationState,
    journal: MutationJournalDouble,
    commandExecutor: any HostCommandExecuting = MutationCommandDouble(
      result: HostCommandResult(
        exitCode: 0,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false
      )
    )
  ) -> AppleComposeProjectMutationExecutor {
    AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      containers: MutationContainerTransport(state: state),
      infrastructure: MutationInfrastructureTransport(state: state),
      inventory: MutationInventoryLoader(state: state),
      commandExecutor: commandExecutor,
      journal: journal,
      sleeper: ImmediateMutationSleeper(),
      timing: ComposeMutationTiming(
        gracefulPollAttempts: 1,
        confirmationPollAttempts: 1,
        pollInterval: .zero
      )
    )
  }
}

@Suite(.serialized)
struct ComposePreparedPlanStoreTests {
  @Test
  func preparedPlanCanBeConsumedExactlyOnce() async throws {
    let plan = mutationPlan(action: .start, records: [])
    let store = ComposePreparedPlanStore()
    let directory = URL(filePath: "/tmp/reviewed-compose", directoryHint: .isDirectory)
    await store.store(plan: plan, directoryURL: directory)

    let prepared = try await store.consume(plan)

    #expect(prepared.plan == plan)
    #expect(prepared.directoryURL == directory)
    await #expect(throws: ComposeProjectLifecycleError.stalePlan) {
      _ = try await store.consume(plan)
    }
  }

  @Test
  func expiredPreparedPlanIsRejectedWithoutMutationAuthority() async throws {
    let clock = PreparedPlanClock(Date(timeIntervalSince1970: 1_000))
    let plan = mutationPlan(action: .start, records: [])
    let store = ComposePreparedPlanStore(
      timeToLive: 10,
      now: { clock.value }
    )
    await store.store(
      plan: plan,
      directoryURL: URL(filePath: "/tmp/reviewed-compose", directoryHint: .isDirectory)
    )
    clock.value = Date(timeIntervalSince1970: 1_011)

    await #expect(throws: ComposeProjectLifecycleError.stalePlan) {
      _ = try await store.consume(plan)
    }
  }
}

private final class PreparedPlanClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Date

  init(_ value: Date) {
    storedValue = value
  }

  var value: Date {
    get { lock.withLock { storedValue } }
    set { lock.withLock { storedValue = newValue } }
  }
}

private actor ComposeMutationState {
  private var snapshots: [ComposeRuntimeContainerSnapshot]
  private var volumes: [VolumeRecord]
  private var networks: [NetworkRecord]
  private let gracefulSignalStopsContainer: Bool
  private let replacementAfterListCount: Int?
  private let replacementSnapshot: ComposeRuntimeContainerSnapshot?
  private let replacementVolumeAfterInventoryCount: Int?
  private let replacementVolume: VolumeRecord?
  private var listCount = 0
  private var inventoryCount = 0

  private(set) var startIDs: [String] = []
  private(set) var signals: [String] = []
  private(set) var deleteIDs: [String] = []
  private(set) var deletedVolumeNames: [String] = []
  private(set) var deletedNetworkIDs: [String] = []

  init(
    snapshots: [ComposeRuntimeContainerSnapshot],
    volumes: [VolumeRecord] = [],
    networks: [NetworkRecord] = [],
    gracefulSignalStopsContainer: Bool = true,
    replacementAfterListCount: Int? = nil,
    replacementSnapshot: ComposeRuntimeContainerSnapshot? = nil,
    replacementVolumeAfterInventoryCount: Int? = nil,
    replacementVolume: VolumeRecord? = nil
  ) {
    self.snapshots = snapshots
    self.volumes = volumes
    self.networks = networks
    self.gracefulSignalStopsContainer = gracefulSignalStopsContainer
    self.replacementAfterListCount = replacementAfterListCount
    self.replacementSnapshot = replacementSnapshot
    self.replacementVolumeAfterInventoryCount = replacementVolumeAfterInventoryCount
    self.replacementVolume = replacementVolume
  }

  var currentRecords: [ContainerRecord] {
    snapshots.map(\.record)
  }

  var currentVolumes: [VolumeRecord] { volumes }

  func list() -> [ComposeRuntimeContainerSnapshot] {
    listCount += 1
    if let replacementAfterListCount,
      listCount > replacementAfterListCount,
      let replacementSnapshot
    {
      snapshots = [replacementSnapshot]
    }
    return snapshots
  }

  func start(id: String) {
    startIDs.append(id)
    update(id: id, state: .running)
  }

  func signal(id: String, signal: String) {
    signals.append("\(id):\(signal)")
    if signal == "KILL" || gracefulSignalStopsContainer {
      update(id: id, state: .stopped)
    }
  }

  func delete(id: String) {
    deleteIDs.append(id)
    snapshots.removeAll { $0.record.id == id }
  }

  func deleteVolume(name: String) {
    deletedVolumeNames.append(name)
    volumes.removeAll { $0.name == name }
  }

  func deleteNetwork(id: String) {
    deletedNetworkIDs.append(id)
    networks.removeAll { $0.id == id }
  }

  func inventory() -> ContainerInventory {
    inventoryCount += 1
    if let replacementVolumeAfterInventoryCount,
      inventoryCount > replacementVolumeAfterInventoryCount,
      let replacementVolume
    {
      volumes = [replacementVolume]
    }
    return ContainerInventory(
      system: ContainerSystemInfo(
        version: "test",
        build: "test",
        commit: "test",
        applicationRoot: URL(filePath: "/tmp"),
        installRoot: URL(filePath: "/tmp")
      ),
      containers: snapshots.map(\.record),
      images: [
        ImageRecord(
          reference: "example/web:latest",
          digest: "sha256:image",
          mediaType: "application/test",
          indexSizeBytes: 1
        )
      ],
      volumes: volumes,
      networks: networks,
      machines: []
    )
  }

  private func update(id: String, state: RuntimeState) {
    guard let index = snapshots.firstIndex(where: { $0.record.id == id }) else {
      return
    }
    let current = snapshots[index]
    let record = current.record
    snapshots[index] = ComposeRuntimeContainerSnapshot(
      record: ContainerRecord(
        id: record.id,
        imageReference: record.imageReference,
        imageDigest: record.imageDigest,
        platform: record.platform,
        state: state,
        ipAddress: record.ipAddress,
        createdAt: record.createdAt,
        startedAt: state == .running ? Date(timeIntervalSince1970: 2_000) : record.startedAt,
        cpuCount: record.cpuCount,
        memoryBytes: record.memoryBytes,
        ports: record.ports,
        labels: record.labels
      ),
      imageDigest: current.imageDigest,
      stopSignal: current.stopSignal,
      hasPublishedSockets: current.hasPublishedSockets,
      usesSSHAgent: current.usesSSHAgent
    )
  }
}

private struct MutationContainerTransport: ComposeContainerMutationTransport {
  let state: ComposeMutationState

  func list() async throws -> [ComposeRuntimeContainerSnapshot] {
    await state.list()
  }

  func start(id: String) async throws {
    await state.start(id: id)
  }

  func signal(id: String, signal: String) async throws {
    await state.signal(id: id, signal: signal)
  }

  func delete(id: String) async throws {
    await state.delete(id: id)
  }
}

private enum MutationInfrastructureError: Error {
  case unexpectedCall
}

private struct MutationInfrastructureTransport: AppleInfrastructureTransport {
  let state: ComposeMutationState

  func createVolume(
    name: String,
    driver: String,
    driverOptions: [String: String],
    labels: [String: String]
  ) async throws -> VolumeConfiguration {
    throw MutationInfrastructureError.unexpectedCall
  }

  func deleteVolume(name: String) async throws {
    await state.deleteVolume(name: name)
  }

  func listVolumes() async throws -> [VolumeConfiguration] {
    throw MutationInfrastructureError.unexpectedCall
  }

  func volumeDiskUsage(name: String) async throws -> UInt64 {
    throw MutationInfrastructureError.unexpectedCall
  }

  func createNetwork(
    configuration: NetworkConfiguration
  ) async throws -> NetworkResource {
    throw MutationInfrastructureError.unexpectedCall
  }

  func deleteNetwork(id: String) async throws {
    await state.deleteNetwork(id: id)
  }

  func listNetworks() async throws -> [NetworkResource] {
    throw MutationInfrastructureError.unexpectedCall
  }
}

private struct MutationInventoryLoader: ContainerInventoryLoading {
  let state: ComposeMutationState

  func loadInventory() async throws -> ContainerInventory {
    await state.inventory()
  }
}

private struct ImmediateMutationSleeper: ComposeMutationSleeping {
  func sleep(for duration: Duration) async throws {}
}

private actor MutationJournalDouble: ComposeOperationJournaling {
  private(set) var phases: [ComposeOperationJournalPhase] = []
  private(set) var completedStepTokens: [[String]] = []

  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {}

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {
    phases.append(progress.phase)
    completedStepTokens.append(progress.completedStepTokens)
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] { [] }
  func discardPendingAfterReview(operationID: UUID) async throws {}
}

private actor MutationCommandDouble: HostCommandExecuting {
  let result: HostCommandResult
  private(set) var arguments: [[String]] = []

  init(result: HostCommandResult) {
    self.result = result
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    self.arguments.append(arguments)
    return result
  }
}

private final class MutationWorkspaceDouble: ComposeExecutionWorkspaceManaging,
  @unchecked Sendable
{
  private(set) var prepareCount = 0
  private(set) var removeCount = 0

  func prepare(
    operationID: UUID,
    canonicalConfiguration: Data,
    expectedSHA256: String
  ) throws -> ComposeExecutionConfigurationLease {
    prepareCount += 1
    return ComposeExecutionConfigurationLease(
      operationID: operationID,
      directoryURL: URL(filePath: "/tmp/compose-operation", directoryHint: .isDirectory),
      configurationURL: URL(filePath: "/tmp/compose-operation/compose.json"),
      directoryIdentity: .init(device: 1, inode: 2),
      fileIdentity: .init(
        device: 1,
        inode: 3,
        byteCount: Int64(canonicalConfiguration.count),
        sha256: expectedSHA256
      )
    )
  }

  func remove(_ lease: ComposeExecutionConfigurationLease) throws {
    removeCount += 1
  }
}

private func mutationRequest(_ plan: ComposeProjectPlan) -> ComposeProjectMutationRequest {
  ComposeProjectMutationRequest(
    plan: plan,
    operationID: UUID(),
    canonicalConfiguration: Data(#"{"name":"sample","services":{}}"#.utf8),
    composeExecutableURL: URL(filePath: "/tmp/docker-compose"),
    commandEnvironment: ComposeCommandEnvironment(processEnvironment: [:])
  )
}

private func mutationPlan(
  action: ComposeProjectLifecycleAction,
  records: [ContainerRecord],
  dependencies: [String: [String]] = ["web": []],
  killStuckContainers: Bool = true,
  orphanIDs: Set<String> = [],
  volumes: [VolumeRecord] = [],
  networks: [NetworkRecord] = [],
  removeOrphans: Bool = false,
  removeVolumes: Bool = false
) -> ComposeProjectPlan {
  let serviceNames = Array(
    Set(
      records.filter { !orphanIDs.contains($0.id) }.compactMap {
        $0.labels[ComposeLabelKey.service]
      })
  ).sorted()
  let activeServices = serviceNames.map { service in
    ComposeDesiredService(
      name: service,
      imageReference: "example/web:latest",
      replicaCount: records.filter {
        $0.labels[ComposeLabelKey.service] == service
      }.count,
      profiles: [],
      dependencyNames: dependencies[service, default: []],
      configurationHash: String(repeating: "c", count: 64),
      volumeNames: [],
      networkNames: [],
      publishedPortCount: 0
    )
  }
  var visited: Set<String> = []
  var serviceOrder: [String] = []
  func visit(_ service: String) {
    guard visited.insert(service).inserted else { return }
    for dependency in dependencies[service, default: []].sorted() {
      visit(dependency)
    }
    serviceOrder.append(service)
  }
  for service in serviceNames { visit(service) }
  if action == .stop || action == .down { serviceOrder.reverse() }
  let serviceIndexes = Dictionary(
    uniqueKeysWithValues: serviceOrder.enumerated().map { ($1, $0) }
  )
  let orderedRecords = records.sorted { lhs, rhs in
    let lhsIndex = serviceIndexes[lhs.labels[ComposeLabelKey.service] ?? ""] ?? Int.max
    let rhsIndex = serviceIndexes[rhs.labels[ComposeLabelKey.service] ?? ""] ?? Int.max
    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
    let lhsReplica = Int(lhs.labels[ComposeLabelKey.containerNumber] ?? "") ?? Int.max
    let rhsReplica = Int(rhs.labels[ComposeLabelKey.containerNumber] ?? "") ?? Int.max
    if lhsReplica != rhsReplica { return lhsReplica < rhsReplica }
    return lhs.id < rhs.id
  }
  let containerActions = orderedRecords.enumerated().map { offset, record in
    let operation: ComposeProjectContainerOperation =
      switch action {
      case .up: .converge
      case .start: .start
      case .stop: .stop
      case .down: orphanIDs.contains(record.id) ? .removeOrphan : .removeDeclared
      }
    return ComposeProjectContainerAction(
      stepID: .container(offset + 1),
      operation: operation,
      serviceName: record.labels[ComposeLabelKey.service] ?? "unknown",
      replicaNumber: Int(record.labels[ComposeLabelKey.containerNumber] ?? ""),
      expectedIdentity: ComposeProjectContainerIdentity(
        record,
        imageDigest: "sha256:image"
      )
    )
  }
  let volumeActions: [ComposeProjectVolumeAction] = volumes.enumerated().compactMap {
    offset, volume in
    guard action == .down, removeVolumes else { return nil }
    return ComposeProjectVolumeAction(
      stepID: .volume(offset + 1),
      operation: .removeManaged,
      logicalName: volume.labels[ComposeLabelKey.volume] ?? volume.name,
      runtimeName: volume.name,
      expectedIdentity: ComposeProjectVolumeIdentity(volume)
    )
  }
  let networkActions: [ComposeProjectNetworkAction] = networks.enumerated().compactMap {
    offset, network in
    guard action == .down else { return nil }
    return ComposeProjectNetworkAction(
      stepID: .network(offset + 1),
      operation: .removeManaged,
      logicalName: network.labels[ComposeLabelKey.network] ?? network.name,
      runtimeName: network.name,
      expectedIdentity: ComposeProjectNetworkIdentity(network)
    )
  }
  return ComposeProjectPlan(
    id: UUID(),
    generatedAt: Date(timeIntervalSince1970: 1_000),
    options: ComposeProjectReviewOptions(
      action: action,
      projectName: "sample",
      pullPolicy: .never,
      removeOrphans: removeOrphans,
      removeVolumes: removeVolumes,
      killStuckContainers: killStuckContainers
    ),
    source: ComposeProjectSourceSummary(
      directoryName: "sample",
      fileName: "compose.yaml",
      fileIdentity: ComposeProjectSourceFileIdentity(
        device: 1,
        inode: 2,
        owner: 501,
        permissions: 0o600,
        byteCount: 1,
        modificationSeconds: 1,
        modificationNanoseconds: 0,
        changeSeconds: 1,
        changeNanoseconds: 0,
        sha256: String(repeating: "a", count: 64)
      )
    ),
    desiredState: ComposeDesiredState(
      projectName: "sample",
      declaredServiceNames: serviceNames,
      serviceDependencies: dependencies,
      activeServices: activeServices,
      volumes: volumes.map {
        ComposeDesiredResource(
          kind: .volume,
          logicalName: $0.labels[ComposeLabelKey.volume] ?? $0.name,
          runtimeName: $0.name,
          isExternal: false,
          isActive: false
        )
      },
      networks: networks.map {
        ComposeDesiredResource(
          kind: .network,
          logicalName: $0.labels[ComposeLabelKey.network] ?? $0.name,
          runtimeName: $0.name,
          isExternal: false,
          isActive: false
        )
      }
    ),
    fullConfigurationSHA256: String(repeating: "f", count: 64),
    activeConfigurationSHA256: String(repeating: "e", count: 64),
    composeReleaseVersion: "test",
    composeBinarySHA256: String(repeating: "d", count: 64),
    composeSourceRevision: "test-revision",
    environmentSHA256: ComposeCommandEnvironment(processEnvironment: [:]).sha256,
    serviceConfigurationHashes: Dictionary(
      uniqueKeysWithValues: serviceNames.map {
        ($0, String(repeating: "c", count: 64))
      }
    ),
    observedIdentity: ComposeProjectInventoryIdentity(
      containers: records.map {
        ComposeProjectContainerIdentity($0, imageDigest: "sha256:image")
      },
      volumes: volumes.map(ComposeProjectVolumeIdentity.init),
      networks: networks.map(ComposeProjectNetworkIdentity.init)
    ),
    issues: [],
    containerActions: containerActions,
    volumeActions: volumeActions,
    networkActions: networkActions,
    orphanContainers: records.filter { orphanIDs.contains($0.id) }.map {
      ComposeProjectContainerIdentity($0, imageDigest: "sha256:image")
    },
    preservedResources: []
  )
}

private func mutationContainer(
  id: String,
  service: String,
  replica: Int,
  state: RuntimeState
) -> ContainerRecord {
  ContainerRecord(
    id: id,
    imageReference: "example/web:latest",
    imageDigest: "sha256:image",
    platform: "linux/arm64",
    state: state,
    ipAddress: nil,
    createdAt: Date(timeIntervalSince1970: 1_000 + Double(replica)),
    startedAt: state == .running ? Date(timeIntervalSince1970: 1_500) : nil,
    cpuCount: 2,
    memoryBytes: 1_024,
    ports: [],
    labels: [
      ComposeLabelKey.project: "sample",
      ComposeLabelKey.service: service,
      ComposeLabelKey.containerNumber: String(replica),
      ComposeLabelKey.oneOff: "False",
      ComposeLabelKey.configHash: String(repeating: "c", count: 64),
    ]
  )
}

private func mutationVolume(
  name: String,
  consumers: [String]
) -> VolumeRecord {
  VolumeRecord(
    id: "volume-\(name)",
    name: name,
    driver: "local",
    format: "ext4",
    source: "/tmp/\(name).img",
    createdAt: Date(timeIntervalSince1970: 1_000),
    sizeBytes: 1_024,
    allocatedBytes: 512,
    labels: [
      ComposeLabelKey.project: "sample",
      ComposeLabelKey.volume: "data",
    ],
    options: [:],
    isAnonymous: false,
    usedByContainerIDs: consumers
  )
}

private func mutationSnapshot(
  _ record: ContainerRecord
) -> ComposeRuntimeContainerSnapshot {
  ComposeRuntimeContainerSnapshot(
    record: record,
    imageDigest: "sha256:image",
    stopSignal: nil,
    hasPublishedSockets: false,
    usesSSHAgent: false
  )
}
