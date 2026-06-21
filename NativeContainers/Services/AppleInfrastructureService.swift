import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import Foundation

private enum InfrastructureLookup<Value: Sendable>: Sendable {
  case resolved(Value?)
  case failed
}

struct AppleInfrastructureService: InfrastructureManaging, BuiltinNetworkProviding {
  private let infrastructureClient: any AppleInfrastructureTransport
  private let containerReader: any ContainerSnapshotReading
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    infrastructureClient: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    containerReader: any ContainerSnapshotReading = AppleContainerSnapshotReader(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.infrastructureClient = infrastructureClient
    self.containerReader = containerReader
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func builtinNetworkResource() async throws -> NetworkResource? {
    try await infrastructureClient.listNetworks().first {
      $0.id == NetworkClient.defaultNetworkName && $0.isBuiltin
    }
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
    let candidates =
      volumes
      .filter {
        $0.usedByContainerIDs.isEmpty
          && !$0.labels.keys.contains(where: { $0.hasPrefix(ComposeLabelKey.prefix) })
          && $0.labels[ResourceOperationLabel.appleResourceRoleKey] == nil
          && $0.labels[ResourceOperationLabel.applePluginKey] == nil
      }
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
    let candidates =
      networks
      .filter {
        !$0.isBuiltin
          && $0.usedByContainerIDs.isEmpty
          && !$0.labels.keys.contains(where: { $0.hasPrefix(ComposeLabelKey.prefix) })
      }
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
    let snapshot = try await containerReader.get(id: target.containerID)
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

  private func uncancelledVolumeRecord(
    name: String
  ) async -> InfrastructureLookup<VolumeRecord> {
    await Task.detached { [self] in
      for attempt in 0..<3 {
        do {
          if let record = try await currentVolumeRecord(name: name) {
            return .resolved(record)
          }
          if attempt == 2 {
            return .resolved(nil)
          }
        } catch {
          if attempt == 2 {
            return .failed
          }
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
      return .failed
    }.value
  }

  private func uncancelledNetworkRecord(
    id: String
  ) async -> InfrastructureLookup<NetworkRecord> {
    await Task.detached { [self] in
      for attempt in 0..<3 {
        do {
          if let record = try await currentNetworkRecord(id: id) {
            return .resolved(record)
          }
          if attempt == 2 {
            return .resolved(nil)
          }
        } catch {
          if attempt == 2 {
            return .failed
          }
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
      return .failed
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

  private func loadAllocatedVolumeSizes(names: [String]) async throws -> [String: UInt64] {
    let uniqueNames = Array(Set(names)).sorted()
    return try await withThrowingTaskGroup(of: (String, UInt64?).self) { group in
      let initialCount = min(4, uniqueNames.count)
      for name in uniqueNames.prefix(initialCount) {
        group.addTask {
          do {
            return (name, try await self.infrastructureClient.volumeDiskUsage(name: name))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return (name, nil)
          }
        }
      }

      var nextIndex = initialCount
      var result: [String: UInt64] = [:]
      while let (name, size) = try await group.next() {
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
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              return (nextName, nil)
            }
          }
        }
      }
      try Task.checkCancellation()
      return result
    }
  }

  private func loadCurrentVolumeRecords() async throws -> [VolumeRecord] {
    async let configurationRequest = infrastructureClient.listVolumes()
    async let containerRequest = containerReader.list()
    let (configurations, snapshots) = try await (configurationRequest, containerRequest)
    let allocatedSizes = try await loadAllocatedVolumeSizes(names: configurations.map(\.name))

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
    async let containerRequest = containerReader.list()
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
    async let containerRequest = containerReader.list()
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

  private nonisolated func volume(_ volume: VolumeRecord, matches request: VolumeCreateRequest)
    -> Bool
  {
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

  private nonisolated func network(_ network: NetworkRecord, matches request: NetworkCreateRequest)
    -> Bool
  {
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

  private func withRuntimeMutation<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await runtimeMutationCoordinator.perform(operation)
  }
}
