import ContainerXPC
import Foundation
import Testing

@testable import NativeContainers

@Suite("Infrastructure management")
struct InfrastructureManagementTests {
  @Test
  func volumeRequestsNormalizeAndValidateBoundaries() throws {
    let request = try VolumeCreateRequest(
      operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: " data.v1 ",
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB,
      journalMode: .journal,
      labels: ["com.example.kind": "database"]
    )

    #expect(request.name == "data.v1")
    #expect(request.sizeBytes == 67_108_864)
    #expect(request.journalMode == .journal)

    #expect(throws: ResourceManagementError.invalidVolumeName) {
      try VolumeCreateRequest(name: "-invalid")
    }
    #expect(throws: ResourceManagementError.invalidVolumeName) {
      try VolumeCreateRequest(name: String(repeating: "a", count: 256))
    }
    #expect(throws: ResourceManagementError.invalidVolumeSize) {
      try VolumeCreateRequest(name: "valid", sizeBytes: 1)
    }
    #expect(throws: ResourceManagementError.invalidVolumeSize) {
      try VolumeCreateRequest(
        name: "valid",
        sizeBytes: VolumeCreateRequest.maximumSizeBytes + VolumeCreateRequest.bytesPerMiB
      )
    }
    #expect(throws: ResourceManagementError.reservedMetadataKey(ResourceOperationLabel.key)) {
      try VolumeCreateRequest(
        name: "valid",
        labels: [ResourceOperationLabel.key: "caller-controlled"]
      )
    }
  }

  @Test
  func networkRequestsNormalizeAndValidateNames() throws {
    let request = try NetworkCreateRequest(
      operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: " backend ",
      mode: .hostOnly,
      ipv4Subnet: " 192.168.100.0/24 ",
      ipv6Subnet: " ",
      labels: ["com.example.kind": "private"]
    )

    #expect(request.name == "backend")
    #expect(request.mode == .hostOnly)
    #expect(request.ipv4Subnet == "192.168.100.0/24")
    #expect(request.ipv6Subnet == nil)

    #expect(throws: ResourceManagementError.invalidNetworkName) {
      try NetworkCreateRequest(name: "Uppercase")
    }
    #expect(throws: ResourceManagementError.invalidNetworkName) {
      try NetworkCreateRequest(name: "-backend")
    }
    #expect(
      throws: ResourceManagementError.reservedMetadataKey(
        ResourceOperationLabel.appleResourceRoleKey
      )
    ) {
      try NetworkCreateRequest(
        name: "backend",
        labels: [ResourceOperationLabel.appleResourceRoleKey: "builtin"]
      )
    }
  }

  @Test
  func infrastructureClientRejectsMissingListPayloads() async {
    let client = AppleInfrastructureClient(requestSender: MissingPayloadXPCSender())

    await #expect(throws: ResourceManagementError.invalidInfrastructureResponse) {
      try await client.listVolumes()
    }
    await #expect(throws: ResourceManagementError.invalidInfrastructureResponse) {
      try await client.listNetworks()
    }
    await #expect(throws: ResourceManagementError.invalidInfrastructureResponse) {
      try await client.volumeDiskUsage(name: "missing-size")
    }
  }

  @Test
  func metadataParserHandlesCommentsValuesAndDuplicates() throws {
    let values = try ResourceMetadataParser.parse(
      """
      # labels
      com.example.owner=platform
      com.example.note=one=two
      """
    )

    #expect(values["com.example.owner"] == "platform")
    #expect(values["com.example.note"] == "one=two")
    #expect(throws: ResourceManagementError.invalidMetadataLine(1)) {
      try ResourceMetadataParser.parse("missing-separator")
    }
    #expect(throws: ResourceManagementError.duplicateMetadataKey("key")) {
      try ResourceMetadataParser.parse("key=one\nkey=two")
    }
  }

  @Test
  func browserURLsRequireExplicitSchemeAndNormalizeWildcards() throws {
    let ipv4 = ContainerPort(
      hostAddress: "0.0.0.0",
      hostPort: 8_080,
      containerPort: 80,
      protocolName: "tcp"
    )
    let ipv6 = ContainerPort(
      hostAddress: "::",
      hostPort: 443,
      containerPort: 8_443,
      protocolName: "tcp"
    )

    #expect(
      try ContainerBrowserURLBuilder.makeURL(port: ipv4, scheme: .http).absoluteString
        == "http://127.0.0.1:8080/"
    )
    #expect(
      try ContainerBrowserURLBuilder.makeURL(port: ipv4, scheme: .https).absoluteString
        == "https://127.0.0.1:8080/"
    )
    #expect(
      try ContainerBrowserURLBuilder.makeURL(port: ipv6, scheme: .https).absoluteString
        == "https://[::1]/"
    )

    let udp = ContainerPort(
      hostAddress: "127.0.0.1",
      hostPort: 53,
      containerPort: 53,
      protocolName: "udp"
    )
    #expect(throws: ResourceManagementError.browserRequiresTCP) {
      try ContainerBrowserURLBuilder.makeURL(port: udp, scheme: .http)
    }
  }

  @Test
  func reviewedVolumeDeletionFailsClosedOnIdentityDriftAndNewUse() throws {
    let reviewed = volumeRecord()
    let plan = VolumeDeletionPlan(
      volume: reviewed,
      identity: reviewed.configurationIdentity,
      generatedAt: Date(timeIntervalSince1970: 10)
    )

    try InfrastructureExecutionSafety.validateVolumeDeletion(plan: plan, current: reviewed)

    let replaced = volumeRecord(source: "/runtime/replacement")
    #expect(throws: ResourceManagementError.stalePlan(reviewed.name)) {
      try InfrastructureExecutionSafety.validateVolumeDeletion(plan: plan, current: replaced)
    }

    let newlyUsed = volumeRecord(usedByContainerIDs: ["stopped-container"])
    #expect(
      throws: ResourceManagementError.volumeInUse(
        name: reviewed.name,
        containerIDs: ["stopped-container"]
      )
    ) {
      try InfrastructureExecutionSafety.validateVolumeDeletion(plan: plan, current: newlyUsed)
    }
  }

  @Test
  func reviewedNetworkDeletionRejectsBuiltinUseAndReplacement() throws {
    let reviewed = networkRecord()
    let plan = NetworkDeletionPlan(
      network: reviewed,
      identity: reviewed.configurationIdentity,
      generatedAt: Date(timeIntervalSince1970: 10)
    )

    try InfrastructureExecutionSafety.validateNetworkDeletion(plan: plan, current: reviewed)

    let builtin = networkRecord(isBuiltin: true)
    let builtinPlan = NetworkDeletionPlan(
      network: builtin,
      identity: builtin.configurationIdentity,
      generatedAt: Date(timeIntervalSince1970: 10)
    )
    #expect(throws: ResourceManagementError.builtinNetwork(reviewed.name)) {
      try InfrastructureExecutionSafety.validateNetworkDeletion(
        plan: builtinPlan,
        current: builtin
      )
    }

    let used = networkRecord(usedByContainerIDs: ["api"])
    #expect(
      throws: ResourceManagementError.networkInUse(name: reviewed.name, containerIDs: ["api"])
    ) {
      try InfrastructureExecutionSafety.validateNetworkDeletion(plan: plan, current: used)
    }

    let replaced = networkRecord(plugin: "different-plugin")
    #expect(throws: ResourceManagementError.stalePlan(reviewed.name)) {
      try InfrastructureExecutionSafety.validateNetworkDeletion(plan: plan, current: replaced)
    }
  }

  @MainActor
  @Test
  func volumeOperationModelRefreshesAfterReviewedCreation() async throws {
    let service = InfrastructureServiceDouble()
    let refreshCounter = RefreshCounter()
    let model = VolumeManagementModel(service: service) {
      await refreshCounter.increment()
    }
    let request = try VolumeCreateRequest(
      operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "database",
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )

    let plan = await model.prepareCreation(request)
    #expect(plan?.request == request)
    #expect(await model.createReviewedVolume(plan))
    #expect(await service.createdVolumeNames == ["database"])
    #expect(await refreshCounter.value == 1)
    #expect(model.creationPlan == nil)
    #expect(model.errorMessage == nil)
  }

  @MainActor
  @Test
  func volumeOperationModelBlocksReviewedInUseDeletionBeforeMutation() async {
    let service = InfrastructureServiceDouble()
    let refreshCounter = RefreshCounter()
    let model = VolumeManagementModel(service: service) {
      await refreshCounter.increment()
    }
    let volume = volumeRecord(usedByContainerIDs: ["stopped-container"])
    let plan = VolumeDeletionPlan(
      volume: volume,
      identity: volume.configurationIdentity,
      generatedAt: Date(timeIntervalSince1970: 10)
    )

    #expect(!(await model.deleteReviewedVolume(plan)))
    #expect(await service.deletedVolumeNames.isEmpty)
    #expect(await refreshCounter.value == 0)
    #expect(model.errorMessage != nil)
  }

  @MainActor
  @Test
  func cancelledVolumeMutationRefreshesFromAnUncancelledTask() async throws {
    let service = CancellingInfrastructureServiceDouble()
    let refreshCounter = RefreshCounter()
    let model = VolumeManagementModel(service: service) {
      await refreshCounter.increment()
    }
    let request = try VolumeCreateRequest(name: "cancelled-volume")
    let plan = VolumeCreationPlan(
      request: request,
      generatedAt: Date(timeIntervalSince1970: 1)
    )

    let operation = Task {
      await model.createReviewedVolume(plan)
    }
    while !(await service.hasStarted) {
      await Task.yield()
    }
    operation.cancel()

    #expect(!(await operation.value))
    #expect(await refreshCounter.value == 1)
  }

  @MainActor
  @Test
  func partialPruneResultSurvivesCancellation() async {
    let removed = volumeRecord()
    let remaining = volumeRecord(source: "/runtime/volumes/remaining/data.img")
    let remainingPlan = VolumeDeletionPlan(
      volume: remaining,
      identity: remaining.configurationIdentity,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    let result = ResourceCleanupResult(
      removedResourceNames: [removed.name],
      failedResources: [
        ResourceOperationFailure(
          resource: "remaining",
          message: "Not removed because pruning was cancelled."
        )
      ],
      reclaimedBytes: 4_194_304
    )
    let service = PartialCleanupInfrastructureServiceDouble(result: result)
    let refreshCounter = RefreshCounter()
    let model = VolumeManagementModel(service: service) {
      await refreshCounter.increment()
    }
    let plan = VolumePrunePlan(
      candidates: [remainingPlan],
      generatedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(!(await model.pruneReviewedVolumes(plan)))
    #expect(model.cleanupResult == result)
    #expect(await refreshCounter.value == 1)
    #expect(model.errorMessage?.contains("cancelled") == true)
  }
}

private func volumeRecord(
  source: String = "/runtime/volumes/database/data.img",
  usedByContainerIDs: [String] = []
) -> VolumeRecord {
  VolumeRecord(
    id: "database",
    name: "database",
    driver: "local",
    format: "ext4",
    source: source,
    createdAt: Date(timeIntervalSince1970: 1),
    sizeBytes: 67_108_864,
    allocatedBytes: 4_194_304,
    labels: ["com.example.kind": "database"],
    options: ["size": "67108864B", "journal": "ordered"],
    isAnonymous: false,
    usedByContainerIDs: usedByContainerIDs
  )
}

private func networkRecord(
  plugin: String = "container-network-vmnet",
  isBuiltin: Bool = false,
  usedByContainerIDs: [String] = []
) -> NetworkRecord {
  NetworkRecord(
    id: "backend",
    name: "backend",
    mode: .nat,
    createdAt: Date(timeIntervalSince1970: 1),
    configuredIPv4Subnet: "192.168.100.0/24",
    configuredIPv6Subnet: nil,
    assignedIPv4Subnet: "192.168.100.0/24",
    ipv4Gateway: "192.168.100.1",
    assignedIPv6Subnet: nil,
    labels: ["com.example.kind": "private"],
    plugin: plugin,
    options: [:],
    isBuiltin: isBuiltin,
    usedByContainerIDs: usedByContainerIDs
  )
}

private struct MissingPayloadXPCSender: AppleXPCRequestSending {
  func send(_ message: XPCMessage, operation: String) async throws -> XPCMessage {
    XPCMessage(route: .volumeList)
  }
}

private actor RefreshCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

private actor InfrastructureServiceDouble: InfrastructureManaging {
  private(set) var createdVolumeNames: [String] = []
  private(set) var deletedVolumeNames: [String] = []

  func prepareVolumeCreation(_ request: VolumeCreateRequest) async throws -> VolumeCreationPlan {
    VolumeCreationPlan(request: request, generatedAt: Date(timeIntervalSince1970: 1))
  }

  func createVolume(_ plan: VolumeCreationPlan) async throws -> VolumeRecord {
    createdVolumeNames.append(plan.request.name)
    return VolumeRecord(
      id: plan.request.name,
      name: plan.request.name,
      driver: "local",
      format: "ext4",
      source: "/runtime/volumes/\(plan.request.name)/data.img",
      createdAt: Date(timeIntervalSince1970: 1),
      sizeBytes: plan.request.sizeBytes,
      allocatedBytes: 1_048_576,
      labels: plan.request.labels,
      options: [
        "size": "\(plan.request.sizeBytes)B",
        "journal": plan.request.journalMode.rawValue,
      ],
      isAnonymous: false,
      usedByContainerIDs: []
    )
  }

  func deleteVolume(_ plan: VolumeDeletionPlan) async throws {
    deletedVolumeNames.append(plan.volume.name)
  }
}

private actor CancellingInfrastructureServiceDouble: InfrastructureManaging {
  private(set) var hasStarted = false

  func createVolume(_ plan: VolumeCreationPlan) async throws -> VolumeRecord {
    hasStarted = true
    try await Task.sleep(for: .seconds(60))
    return volumeRecord()
  }
}

private actor PartialCleanupInfrastructureServiceDouble: InfrastructureManaging {
  let result: ResourceCleanupResult

  init(result: ResourceCleanupResult) {
    self.result = result
  }

  func pruneVolumes(_ plan: VolumePrunePlan) async throws -> ResourceCleanupResult {
    throw ResourceCleanupPartialCompletionError(
      operation: "Volume pruning",
      result: result
    )
  }
}
