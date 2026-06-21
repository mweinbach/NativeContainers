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

  private func makeExecutor(
    state: ComposeMutationState,
    journal: MutationJournalDouble
  ) -> AppleComposeProjectMutationExecutor {
    AppleComposeProjectMutationExecutor(
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      containers: MutationContainerTransport(state: state),
      inventory: MutationInventoryLoader(state: state),
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
  private let gracefulSignalStopsContainer: Bool
  private let replacementAfterListCount: Int?
  private let replacementSnapshot: ComposeRuntimeContainerSnapshot?
  private var listCount = 0

  private(set) var startIDs: [String] = []
  private(set) var signals: [String] = []
  private(set) var deleteIDs: [String] = []

  init(
    snapshots: [ComposeRuntimeContainerSnapshot],
    gracefulSignalStopsContainer: Bool = true,
    replacementAfterListCount: Int? = nil,
    replacementSnapshot: ComposeRuntimeContainerSnapshot? = nil
  ) {
    self.snapshots = snapshots
    self.gracefulSignalStopsContainer = gracefulSignalStopsContainer
    self.replacementAfterListCount = replacementAfterListCount
    self.replacementSnapshot = replacementSnapshot
  }

  var currentRecords: [ContainerRecord] {
    snapshots.map(\.record)
  }

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

  func inventory() -> ContainerInventory {
    ContainerInventory(
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
      volumes: [],
      networks: [],
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

  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {}

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {
    phases.append(progress.phase)
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
  killStuckContainers: Bool = true
) -> ComposeProjectPlan {
  let serviceNames = Array(
    Set(
      records.compactMap {
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
  let configuration = Data(#"{"name":"sample","services":{}}"#.utf8)
  return ComposeProjectPlan(
    id: UUID(),
    generatedAt: Date(timeIntervalSince1970: 1_000),
    options: ComposeProjectReviewOptions(
      action: action,
      projectName: "sample",
      pullPolicy: .never,
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
      volumes: [],
      networks: []
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
      volumes: [],
      networks: []
    ),
    issues: [],
    affectedContainerIDs: records.map(\.id).sorted(),
    affectedVolumeNames: [],
    affectedNetworkNames: [],
    orphanContainerIDs: [],
    preservedResourceNames: []
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
