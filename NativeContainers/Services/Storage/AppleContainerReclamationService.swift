import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Foundation

protocol ContainerStorageReclaiming: Sendable {
  func prepareContainerPrune() async throws -> ContainerPrunePlan
  func pruneContainers(_ plan: ContainerPrunePlan) async throws -> ContainerCleanupResult
}

protocol ContainerReclamationTransport: Sendable {
  func list(ids: [String]) async throws -> [ContainerSnapshot]
  func diskUsage(id: String) async throws -> UInt64
  func deleteStopped(id: String) async throws
}

struct AppleContainerReclamationClient: ContainerReclamationTransport {
  private let requestSender: any AppleXPCRequestSending

  init(operationTimeout: Duration = .seconds(15)) {
    requestSender = AppleXPCRequestClient(operationTimeout: operationTimeout)
  }

  init(requestSender: any AppleXPCRequestSending) {
    self.requestSender = requestSender
  }

  func list(ids: [String] = []) async throws -> [ContainerSnapshot] {
    let message = XPCMessage(route: .containerList)
    message.set(
      key: .listFilters,
      value: try JSONEncoder().encode(ContainerListFilters(ids: ids))
    )
    let response = try await requestSender.send(
      message,
      operation: "Inspect reclaimable containers"
    )
    guard let data = response.dataNoCopy(key: .containers) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
  }

  func diskUsage(id: String) async throws -> UInt64 {
    let message = XPCMessage(route: .containerDiskUsage)
    message.set(key: .id, value: id)
    let response = try await requestSender.send(
      message,
      operation: "Measure container storage"
    )
    return response.uint64(key: .containerSize)
  }

  func deleteStopped(id: String) async throws {
    let message = XPCMessage(route: .containerDelete)
    message.set(key: .id, value: id)
    message.set(key: .forceDelete, value: false)
    _ = try await requestSender.send(
      message,
      operation: "Delete stopped container"
    )
  }
}

enum ContainerReclamationSafety {
  static func candidate(
    from snapshot: ContainerSnapshot,
    allocatedBytes: UInt64?
  ) throws -> ContainerPruneCandidate? {
    let labels = snapshot.configuration.labels
    guard snapshot.status == .stopped else { return nil }
    guard snapshot.id != ContainerBuilderRecord.containerID else { return nil }
    guard !labels.keys.contains(where: { $0.hasPrefix(ComposeLabelKey.prefix) }) else {
      return nil
    }
    guard
      labels[ResourceOperationLabel.applePluginKey] == nil,
      labels[ResourceOperationLabel.appleResourceRoleKey] == nil
    else {
      return nil
    }
    guard
      let ownership = labels[AppleContainerOwnership.creationOperationLabel],
      let ownershipID = UUID(uuidString: ownership)
    else {
      return nil
    }

    return ContainerPruneCandidate(
      id: snapshot.id,
      ownershipID: ownershipID,
      createdAt: snapshot.configuration.creationDate,
      imageReference: snapshot.configuration.image.reference,
      imageDigest: snapshot.configuration.image.descriptor.digest,
      platform: snapshot.platform.description,
      configurationSeal: try configurationSeal(snapshot.configuration),
      allocatedBytes: allocatedBytes,
      hasPublishedSockets: !snapshot.configuration.publishedSockets.isEmpty
    )
  }

  static func validate(
    _ candidate: ContainerPruneCandidate,
    against snapshot: ContainerSnapshot
  ) throws {
    guard
      let current = try self.candidate(from: snapshot, allocatedBytes: nil),
      current.id == candidate.id,
      current.ownershipID == candidate.ownershipID,
      current.createdAt == candidate.createdAt,
      current.imageReference == candidate.imageReference,
      current.imageDigest == candidate.imageDigest,
      current.platform == candidate.platform,
      current.configurationSeal == candidate.configurationSeal
    else {
      throw StorageReclamationError.staleSource
    }
  }

  private static func configurationSeal(
    _ configuration: ContainerConfiguration
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(configuration)
  }
}

struct AppleContainerReclamationService: ContainerStorageReclaiming {
  typealias Sleeper = @Sendable (Duration) async -> Void

  private let transport: any ContainerReclamationTransport
  private let attachmentService: any ContainerAttachmentWorkspaceManaging
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let now: @Sendable () -> Date
  private let reconciliationAttempts: Int
  private let sleep: Sleeper

  init(
    transport: any ContainerReclamationTransport = AppleContainerReclamationClient(),
    attachmentService: any ContainerAttachmentWorkspaceManaging =
      AppleContainerAttachmentService(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    now: @escaping @Sendable () -> Date = Date.init,
    reconciliationAttempts: Int = 3,
    sleep: @escaping Sleeper = { duration in
      try? await Task.sleep(for: duration)
    }
  ) {
    self.transport = transport
    self.attachmentService = attachmentService
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
    self.now = now
    self.reconciliationAttempts = max(reconciliationAttempts, 1)
    self.sleep = sleep
  }

  func prepareContainerPrune() async throws -> ContainerPrunePlan {
    let snapshots = try await transport.list(ids: [])
    var candidates: [ContainerPruneCandidate] = []

    for snapshot in snapshots {
      try Task.checkCancellation()
      guard
        let candidate = try ContainerReclamationSafety.candidate(
          from: snapshot,
          allocatedBytes: nil
        )
      else {
        continue
      }

      let allocatedBytes: UInt64?
      do {
        allocatedBytes = try await transport.diskUsage(id: candidate.id)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        allocatedBytes = nil
      }
      guard
        let measured = try ContainerReclamationSafety.candidate(
          from: snapshot,
          allocatedBytes: allocatedBytes
        )
      else {
        continue
      }
      candidates.append(measured)
    }

    return ContainerPrunePlan(
      candidates: candidates.sorted {
        $0.id.localizedStandardCompare($1.id) == .orderedAscending
      },
      generatedAt: now()
    )
  }

  func pruneContainers(
    _ plan: ContainerPrunePlan
  ) async throws -> ContainerCleanupResult {
    try await runtimeMutationCoordinator.perform {
      try await self.pruneContainersWhileLocked(plan)
    }
  }

  private func pruneContainersWhileLocked(
    _ plan: ContainerPrunePlan
  ) async throws -> ContainerCleanupResult {
    var removed: [String] = []
    var failures: [ResourceOperationFailure] = []
    var removedAllocatedBytes: UInt64 = 0

    func result(
      pendingStartingAt index: Int? = nil
    ) -> ContainerCleanupResult {
      let pending =
        index.map { start in
          plan.candidates.dropFirst(start).map {
            ResourceOperationFailure(
              resource: $0.id,
              message: "Not removed because reclamation was cancelled."
            )
          }
        } ?? []
      return ContainerCleanupResult(
        removedContainerIDs: removed.sorted(),
        failedContainers: failures + pending,
        removedAllocatedBytes: removedAllocatedBytes
      )
    }

    for (index, candidate) in plan.candidates.enumerated() {
      guard !Task.isCancelled else {
        throw ContainerCleanupPartialCompletionError(
          result: result(pendingStartingAt: index)
        )
      }

      let current: ContainerSnapshot
      do {
        let matches = try await transport.list(ids: [candidate.id])
        guard matches.count == 1, let snapshot = matches.first else {
          failures.append(
            ResourceOperationFailure(
              resource: candidate.id,
              message: "Changed or disappeared after review; skipped."
            )
          )
          continue
        }
        try ContainerReclamationSafety.validate(candidate, against: snapshot)
        current = snapshot
      } catch is CancellationError {
        throw ContainerCleanupPartialCompletionError(
          result: result(pendingStartingAt: index)
        )
      } catch {
        failures.append(
          ResourceOperationFailure(
            resource: candidate.id,
            message: "Changed or became active after review; skipped."
          )
        )
        continue
      }

      let allocatedBeforeDelete: UInt64
      do {
        allocatedBeforeDelete =
          try await transport.diskUsage(id: candidate.id)
      } catch is CancellationError {
        throw ContainerCleanupPartialCompletionError(
          result: result(pendingStartingAt: index)
        )
      } catch {
        allocatedBeforeDelete = candidate.allocatedBytes ?? 0
      }

      var deletionError: (any Error)?
      do {
        try Task.checkCancellation()
        try await transport.deleteStopped(id: current.id)
      } catch {
        deletionError = error
      }

      let reconciliation = await reconcile(candidate)
      switch reconciliation {
      case .absent:
        removed.append(candidate.id)
        removedAllocatedBytes = StorageByteMath.saturatingSum([
          removedAllocatedBytes,
          allocatedBeforeDelete,
        ])
        await cleanupAttachments(operationID: candidate.ownershipID)
        if deletionError is CancellationError || Task.isCancelled {
          throw ContainerCleanupPartialCompletionError(
            result: result(pendingStartingAt: index + 1)
          )
        }
      case .sameIdentity:
        if deletionError is CancellationError || Task.isCancelled {
          throw ContainerCleanupPartialCompletionError(
            result: result(pendingStartingAt: index)
          )
        }
        failures.append(
          ResourceOperationFailure(
            resource: candidate.id,
            message: deletionError?.localizedDescription
              ?? "The stopped container remained after deletion."
          )
        )
      case .replacement:
        failures.append(
          ResourceOperationFailure(
            resource: candidate.id,
            message: "The container identity changed during deletion; skipped."
          )
        )
      case .unavailable(let message):
        failures.append(
          ResourceOperationFailure(
            resource: candidate.id,
            message: "Could not verify deletion: \(message)"
          )
        )
      }

      if Task.isCancelled {
        throw ContainerCleanupPartialCompletionError(
          result: result(pendingStartingAt: index + 1)
        )
      }
    }

    return result()
  }

  private func reconcile(
    _ candidate: ContainerPruneCandidate
  ) async -> ContainerReconciliation {
    let transport = self.transport
    let attempts = reconciliationAttempts
    let sleep = self.sleep
    return await Task.detached {
      var lastMessage = "No reconciliation response."
      for attempt in 0..<attempts {
        do {
          let matches = try await transport.list(ids: [candidate.id])
          guard let snapshot = matches.first else { return .absent }
          guard matches.count == 1 else { return .replacement }
          do {
            try ContainerReclamationSafety.validate(candidate, against: snapshot)
            if attempt + 1 < attempts {
              await sleep(.milliseconds(150))
              continue
            }
            return .sameIdentity
          } catch {
            return .replacement
          }
        } catch {
          lastMessage = error.localizedDescription
          if attempt + 1 < attempts {
            await sleep(.milliseconds(150))
          }
        }
      }
      return .unavailable(lastMessage)
    }.value
  }

  private func cleanupAttachments(operationID: UUID) async {
    let attachmentService = self.attachmentService
    await Task.detached {
      await attachmentService.cleanupAttachmentWorkspace(
        operationID: operationID
      )
    }.value
  }
}

private enum ContainerReconciliation: Sendable {
  case absent
  case sameIdentity
  case replacement
  case unavailable(String)
}

struct UnavailableContainerStorageReclaimer: ContainerStorageReclaiming {
  func prepareContainerPrune() async throws -> ContainerPrunePlan {
    throw StorageReclamationError.unavailable
  }

  func pruneContainers(
    _ plan: ContainerPrunePlan
  ) async throws -> ContainerCleanupResult {
    throw StorageReclamationError.unavailable
  }
}
