import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationOCI
import Foundation
import Testing

@testable import NativeContainers

@Suite("Container builder management")
struct ContainerBuilderManagementTests {
  @Test
  func inspectionReportsTrustedBuilderAndWholeBundleAllocation() async throws {
    let running = makeBuilderSnapshot(status: .running)
    let transport = BuilderTransportDouble(listResults: [[running]], allocatedBytes: 530_751_488)
    let service = makeService(transport: transport, nodePresence: NodePresenceDouble([true]))

    let inspection = try await service.loadBuilder()

    #expect(inspection.builder.state == .running)
    #expect(inspection.builder.isTrustedBuilder)
    #expect(inspection.builder.allocatedBytes == 530_751_488)
    #expect(inspection.reviewedSnapshot?.creationDate == builderCreationDate)
  }

  @Test
  func orphanedBundleAndIdentityConflictAreNeverActionable() async throws {
    let orphanService = makeService(
      transport: BuilderTransportDouble(listResults: [[]]),
      nodePresence: NodePresenceDouble([true])
    )
    await #expect(throws: ContainerBuilderManagementError.orphanedBundle) {
      try await orphanService.prepareBuilderAction(.deleteBuilderAndCache)
    }

    let conflict = makeBuilderSnapshot(status: .stopped, executable: "/bin/false")
    let conflictService = makeService(
      transport: BuilderTransportDouble(listResults: [[conflict]]),
      nodePresence: NodePresenceDouble([true])
    )
    await #expect(throws: ContainerBuilderManagementError.untrustedBuilder) {
      try await conflictService.prepareBuilderAction(.deleteBuilderAndCache)
    }
  }

  @Test
  func stopRequiresConfirmationThenReconcilesCommittedReplyFailure() async throws {
    let running = makeBuilderSnapshot(status: .running)
    let stopped = makeBuilderSnapshot(status: .stopped)
    let transport = BuilderTransportDouble(
      listResults: [[running], [running], [stopped]],
      stopThrowsAfterCommit: true
    )
    let service = makeService(transport: transport, nodePresence: NodePresenceDouble([true]))
    let plan = try await service.prepareBuilderAction(.stop)

    await #expect(throws: ContainerBuilderManagementError.interruptionRequiresConfirmation) {
      try await service.performBuilderAction(plan, authorization: .none)
    }
    let result = try await service.performBuilderAction(
      plan,
      authorization: ContainerBuilderManagementAuthorization(
        allowsInterruptRunningBuilder: true
      )
    )

    #expect(result.action == .stop)
    #expect(result.inspection.builder.state == .stopped)
    #expect(await transport.stopCount == 1)
    #expect(await transport.killCount == 0)
  }

  @Test
  func forceStopUsesExplicitKillAndPreservesReviewedIdentity() async throws {
    let running = makeBuilderSnapshot(status: .running)
    let stopped = makeBuilderSnapshot(status: .stopped)
    let transport = BuilderTransportDouble(listResults: [[running], [running], [stopped]])
    let service = makeService(transport: transport, nodePresence: NodePresenceDouble([true]))
    let plan = try await service.prepareBuilderAction(.forceStop)

    let result = try await service.performBuilderAction(
      plan,
      authorization: ContainerBuilderManagementAuthorization(
        allowsInterruptRunningBuilder: true
      )
    )

    #expect(result.inspection.builder.state == .stopped)
    #expect(await transport.killCount == 1)
    #expect(await transport.stopCount == 0)
  }

  @Test
  func replacementBetweenReviewAndMutationIsRejectedBeforeStop() async throws {
    let reviewed = makeBuilderSnapshot(status: .running)
    let replacement = makeBuilderSnapshot(
      status: .running,
      creationDate: builderCreationDate.addingTimeInterval(1)
    )
    let transport = BuilderTransportDouble(listResults: [[reviewed], [replacement]])
    let service = makeService(transport: transport, nodePresence: NodePresenceDouble([true]))
    let plan = try await service.prepareBuilderAction(.stop)

    await #expect(throws: ContainerBuilderManagementError.staleReview) {
      try await service.performBuilderAction(
        plan,
        authorization: ContainerBuilderManagementAuthorization(
          allowsInterruptRunningBuilder: true
        )
      )
    }
    #expect(await transport.stopCount == 0)
    #expect(await transport.killCount == 0)
  }

  @Test
  func deletingStoppedBuilderRequiresInventoryAndBundleToDisappear() async throws {
    let stopped = makeBuilderSnapshot(status: .stopped)
    let transport = BuilderTransportDouble(listResults: [[stopped], [stopped], []])
    let service = makeService(
      transport: transport,
      nodePresence: NodePresenceDouble([true, true, false])
    )
    let plan = try await service.prepareBuilderAction(.deleteBuilderAndCache)

    let result = try await service.performBuilderAction(plan, authorization: .none)

    #expect(result.action == .deleteBuilderAndCache)
    #expect(result.inspection.builder.state == .absent)
    #expect(!result.inspection.builder.bundlePresent)
    #expect(await transport.deleteCount == 1)
  }

  @Test
  func inventoryRemovalWithOrphanedBundleReportsIncompleteCleanup() async throws {
    let stopped = makeBuilderSnapshot(status: .stopped)
    let transport = BuilderTransportDouble(listResults: [[stopped], [stopped], []])
    let service = makeService(
      transport: transport,
      nodePresence: NodePresenceDouble([true])
    )
    let plan = try await service.prepareBuilderAction(.deleteBuilderAndCache)

    await #expect(throws: ContainerBuilderManagementError.incompleteBundleCleanup) {
      try await service.performBuilderAction(plan, authorization: .none)
    }
    #expect(await transport.deleteCount == 1)
  }

  @Test
  @MainActor
  func modelKeepsReviewSeparateFromExecutionAndRefreshesAfterMutation() async throws {
    let running = makeInspection(state: .running)
    let stopped = makeInspection(state: .stopped)
    let manager = BuilderManagerDouble(initial: running, completed: stopped)
    let refreshes = BuilderRefreshRecorder()
    let model = ContainerBuilderManagementModel(service: manager) {
      await refreshes.record()
    }

    await model.load()
    let plan = await model.prepare(.stop)
    let succeeded = await model.execute(
      plan,
      authorization: ContainerBuilderManagementAuthorization(
        allowsInterruptRunningBuilder: true
      )
    )

    #expect(succeeded)
    #expect(model.plan == nil)
    #expect(model.result?.action == .stop)
    #expect(model.inspection?.builder.state == .stopped)
    #expect(model.errorMessage == nil)
    #expect(await refreshes.count == 1)
  }

  @Test
  func deleteClientAlwaysRequestsNonForceDeletion() async throws {
    let sender = RecordingBuilderRequestSender()
    let client = AppleContainerBuilderClient(requestSender: sender)

    try await client.delete(id: ContainerBuilderRecord.containerID)

    #expect(await sender.ids == [ContainerBuilderRecord.containerID])
    #expect(await sender.forceDeleteValues == [false])
    #expect(await sender.operations == ["Delete stopped shared builder"])
  }

  private func makeService(
    transport: BuilderTransportDouble,
    nodePresence: NodePresenceDouble
  ) -> AppleContainerBuilderManagementService {
    AppleContainerBuilderManagementService(
      contextLoader: BuilderContextLoader(),
      transport: transport,
      runtimeMutationCoordinator: RuntimeMutationCoordinator(),
      buildExecutionCoordinator: RuntimeMutationCoordinator(),
      nodeExists: { url in nodePresence.contains(url) },
      sleep: { _ in }
    )
  }
}

private let builderCreationDate = Date(timeIntervalSince1970: 1_718_000_000)
private let builderApplicationRoot = URL(fileURLWithPath: "/runtime", isDirectory: true)
private let builderExportsRoot = "/runtime/builder"
private let builderNetworkID = "default"

private struct BuilderContextLoader: ContainerBuilderRuntimeContextLoading {
  func load() async throws -> ContainerBuilderRuntimeContext {
    ContainerBuilderRuntimeContext(
      applicationRoot: builderApplicationRoot,
      bundleURL:
        builderApplicationRoot
        .appending(path: "containers", directoryHint: .isDirectory)
        .appending(path: ContainerBuilderRecord.containerID, directoryHint: .isDirectory),
      identityRequirements: ContainerBuilderSnapshotAdapter.identityRequirements(
        exportsRootPath: builderExportsRoot,
        builtinNetworkID: builderNetworkID
      )
    )
  }
}

private actor BuilderTransportDouble: ContainerBuilderTransport {
  private var listResults: [[ContainerSnapshot]]
  private let allocatedBytes: UInt64
  private let stopThrowsAfterCommit: Bool

  private(set) var stopCount = 0
  private(set) var killCount = 0
  private(set) var deleteCount = 0

  init(
    listResults: [[ContainerSnapshot]],
    allocatedBytes: UInt64 = 512 * 1_048_576,
    stopThrowsAfterCommit: Bool = false
  ) {
    self.listResults = listResults
    self.allocatedBytes = allocatedBytes
    self.stopThrowsAfterCommit = stopThrowsAfterCommit
  }

  func list(id: String) async throws -> [ContainerSnapshot] {
    guard !listResults.isEmpty else { return [] }
    if listResults.count == 1 {
      return listResults[0]
    }
    return listResults.removeFirst()
  }

  func diskUsage(id: String) async throws -> UInt64 {
    allocatedBytes
  }

  func stop(id: String) async throws {
    stopCount += 1
    if stopThrowsAfterCommit {
      throw BuilderDoubleError.replyLost
    }
  }

  func kill(id: String) async throws {
    killCount += 1
  }

  func delete(id: String) async throws {
    deleteCount += 1
  }
}

private enum BuilderDoubleError: Error {
  case replyLost
}

private final class NodePresenceDouble: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool]

  init(_ values: [Bool]) {
    self.values = values
  }

  func contains(_ url: URL) -> Bool {
    lock.withLock {
      guard !values.isEmpty else { return false }
      if values.count == 1 {
        return values[0]
      }
      return values.removeFirst()
    }
  }
}

private actor BuilderManagerDouble: ContainerBuilderManaging {
  private let initial: ContainerBuilderInspection
  private let completed: ContainerBuilderInspection

  init(initial: ContainerBuilderInspection, completed: ContainerBuilderInspection) {
    self.initial = initial
    self.completed = completed
  }

  func loadBuilder() async throws -> ContainerBuilderInspection {
    initial
  }

  func prepareBuilderAction(
    _ action: ContainerBuilderManagementAction
  ) async throws -> ContainerBuilderManagementPlan {
    try ContainerBuilderManagementPlan(action: action, inspection: initial)
  }

  func performBuilderAction(
    _ plan: ContainerBuilderManagementPlan,
    authorization: ContainerBuilderManagementAuthorization
  ) async throws -> ContainerBuilderManagementResult {
    ContainerBuilderManagementResult(action: plan.action, inspection: completed)
  }
}

private actor BuilderRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private actor RecordingBuilderRequestSender: AppleXPCRequestSending {
  private(set) var ids: [String] = []
  private(set) var forceDeleteValues: [Bool] = []
  private(set) var operations: [String] = []

  func send(_ message: XPCMessage, operation: String) async throws -> XPCMessage {
    ids.append(message.string(key: .id) ?? "")
    forceDeleteValues.append(message.bool(key: .forceDelete))
    operations.append(operation)
    return XPCMessage(route: .containerDelete)
  }
}

private func makeInspection(
  state: ContainerBuilderRuntimeState
) -> ContainerBuilderInspection {
  let safety = ContainerBuilderSnapshotAdapter.safetySnapshot(
    makeBuilderSnapshot(status: state.runtimeStatus)
  )
  return ContainerBuilderInspection(
    builder: ContainerBuilderRecord(
      state: state,
      createdAt: builderCreationDate,
      imageReference: safety.configuration?.image,
      imageDigest: safety.configuration?.imageDescriptorDigest,
      cpuCount: safety.configuration?.cpuCount,
      memoryBytes: safety.configuration?.memoryBytes,
      allocatedBytes: 512 * 1_048_576,
      identityMismatches: [],
      bundlePresent: true
    ),
    reviewedSnapshot: ContainerBuilderReviewedSnapshot(
      creationDate: builderCreationDate,
      safety: safety
    ),
    runtimeApplicationRoot: builderApplicationRoot.path(percentEncoded: false)
  )
}

private func makeBuilderSnapshot(
  status: RuntimeStatus,
  creationDate: Date = builderCreationDate,
  executable: String = "/usr/local/bin/container-builder-shim"
) -> ContainerSnapshot {
  let descriptor = Descriptor(
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: "sha256:" + String(repeating: "a", count: 64),
    size: 1
  )
  let image = ImageDescription(
    reference: "ghcr.io/apple/container-builder-shim/builder:test",
    descriptor: descriptor
  )
  let process = ProcessConfiguration(
    executable: executable,
    arguments: ["--debug", "--vsock"],
    environment: ["BUILDKIT_COLORS=run=green"],
    workingDirectory: "/",
    terminal: false,
    user: .id(uid: 0, gid: 0)
  )
  var configuration = ContainerConfiguration(
    id: ContainerBuilderRecord.containerID,
    image: image,
    process: process
  )
  var resources = ContainerConfiguration.Resources()
  resources.cpus = 2
  resources.memoryInBytes = 2 * 1_073_741_824
  configuration.resources = resources
  configuration.labels = [
    ResourceLabelKeys.plugin: "builder",
    ResourceLabelKeys.role: ResourceRoleValues.builder,
  ]
  configuration.capAdd = ["ALL"]
  configuration.mounts = [
    .init(type: .tmpfs, source: "", destination: "/run", options: []),
    .init(
      type: .virtiofs,
      source: builderExportsRoot,
      destination: "/var/lib/container-builder-shim/exports",
      options: []
    ),
  ]
  configuration.rosetta = true
  configuration.networks = [
    AttachmentConfiguration(
      network: builderNetworkID,
      options: AttachmentOptions(hostname: ContainerBuilderRecord.containerID)
    )
  ]
  configuration.creationDate = creationDate
  return ContainerSnapshot(
    configuration: configuration,
    status: status,
    networks: []
  )
}

extension ContainerBuilderRuntimeState {
  fileprivate var runtimeStatus: RuntimeStatus {
    switch self {
    case .running: .running
    case .stopped: .stopped
    case .stopping: .stopping
    case .unknown, .absent: .unknown
    }
  }
}
