import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Darwin
import Foundation

struct ContainerBuilderRuntimeContext: Equatable, Sendable {
  let applicationRoot: URL
  let bundleURL: URL
  let identityRequirements: ContainerBuilderIdentityRequirements
}

protocol ContainerBuilderRuntimeContextLoading: Sendable {
  func load() async throws -> ContainerBuilderRuntimeContext
}

struct AppleContainerBuilderRuntimeContextLoader: ContainerBuilderRuntimeContextLoading {
  func load() async throws -> ContainerBuilderRuntimeContext {
    do {
      let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
      guard let network = try await NetworkClient().builtin else {
        throw ContainerBuilderManagementError.runtimeUnavailable(
          "Apple’s built-in container network is unavailable."
        )
      }
      let exportsRoot = health.appRoot.appending(
        path: "builder",
        directoryHint: .isDirectory
      )
      let bundleURL = health.appRoot
        .appending(path: "containers", directoryHint: .isDirectory)
        .appending(
          path: ContainerBuilderRecord.containerID,
          directoryHint: .isDirectory
        )
      return ContainerBuilderRuntimeContext(
        applicationRoot: health.appRoot.standardizedFileURL,
        bundleURL: bundleURL.standardizedFileURL,
        identityRequirements: ContainerBuilderSnapshotAdapter.identityRequirements(
          exportsRootPath: exportsRoot.path(percentEncoded: false),
          builtinNetworkID: network.id
        )
      )
    } catch let error as ContainerBuilderManagementError {
      throw error
    } catch {
      throw ContainerBuilderManagementError.runtimeUnavailable(
        error.localizedDescription
      )
    }
  }
}

protocol ContainerBuilderTransport: Sendable {
  func list(id: String) async throws -> [ContainerSnapshot]
  func diskUsage(id: String) async throws -> UInt64
  func stop(id: String) async throws
  func kill(id: String) async throws
  func delete(id: String) async throws
}

struct AppleContainerBuilderClient: ContainerBuilderTransport {
  private let requestSender: any AppleXPCRequestSending

  init(operationTimeout: Duration = .seconds(15)) {
    requestSender = AppleXPCRequestClient(operationTimeout: operationTimeout)
  }

  init(requestSender: any AppleXPCRequestSending) {
    self.requestSender = requestSender
  }

  func list(id: String) async throws -> [ContainerSnapshot] {
    let message = XPCMessage(route: .containerList)
    message.set(
      key: .listFilters,
      value: try JSONEncoder().encode(ContainerListFilters(ids: [id]))
    )
    let response = try await send(message, operation: "Inspect shared builder")
    guard let data = response.dataNoCopy(key: .containers) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
  }

  func diskUsage(id: String) async throws -> UInt64 {
    let message = XPCMessage(route: .containerDiskUsage)
    message.set(key: .id, value: id)
    let response = try await send(message, operation: "Inspect shared builder storage")
    return response.uint64(key: .containerSize)
  }

  func stop(id: String) async throws {
    let message = XPCMessage(route: .containerStop)
    message.set(key: .id, value: id)
    message.set(
      key: .stopOptions,
      value: try JSONEncoder().encode(
        ContainerStopOptions(timeoutInSeconds: 5, signal: nil)
      )
    )
    _ = try await send(message, operation: "Stop shared builder")
  }

  func kill(id: String) async throws {
    let message = XPCMessage(route: .containerKill)
    message.set(key: .id, value: id)
    message.set(key: .processIdentifier, value: id)
    message.set(key: .signal, value: "KILL")
    _ = try await send(message, operation: "Force stop shared builder")
  }

  func delete(id: String) async throws {
    let message = XPCMessage(route: .containerDelete)
    message.set(key: .id, value: id)
    message.set(key: .forceDelete, value: false)
    _ = try await send(message, operation: "Delete stopped shared builder")
  }

  private func send(
    _ message: XPCMessage,
    operation: String
  ) async throws -> XPCMessage {
    try await requestSender.send(message, operation: operation)
  }
}

typealias ContainerBuilderNodeExists = @Sendable (URL) -> Bool

private func defaultContainerBuilderNodeExists(_ url: URL) -> Bool {
  var info = stat()
  if lstat(url.path(percentEncoded: false), &info) == 0 {
    return true
  }
  return errno != ENOENT
}

private struct ContainerBuilderInspector: Sendable {
  let transport: any ContainerBuilderTransport
  let nodeExists: ContainerBuilderNodeExists

  func inspect(
    context: ContainerBuilderRuntimeContext
  ) async throws -> ContainerBuilderInspection {
    let snapshots = try await transport.list(id: ContainerBuilderRecord.containerID)
    guard snapshots.count <= 1 else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }

    let bundlePresent = nodeExists(context.bundleURL)
    guard let snapshot = snapshots.first else {
      return ContainerBuilderInspection(
        builder: .absent(bundlePresent: bundlePresent),
        reviewedSnapshot: nil,
        runtimeApplicationRoot: context.applicationRoot.path(percentEncoded: false)
      )
    }

    let safety = ContainerBuilderSnapshotAdapter.safetySnapshot(snapshot)
    let mismatches = ContainerBuilderSafetyPolicy.identityMismatches(
      safety.identity,
      requirements: context.identityRequirements
    )
    let allocatedBytes: UInt64?
    do {
      allocatedBytes = try await transport.diskUsage(id: snapshot.id)
    } catch {
      try Task.checkCancellation()
      allocatedBytes = nil
    }

    return ContainerBuilderInspection(
      builder: ContainerBuilderRecord(
        state: safety.state,
        createdAt: snapshot.configuration.creationDate,
        imageReference: snapshot.configuration.image.reference,
        imageDigest: snapshot.configuration.image.descriptor.digest,
        cpuCount: snapshot.configuration.resources.cpus,
        memoryBytes: snapshot.configuration.resources.memoryInBytes,
        allocatedBytes: allocatedBytes,
        identityMismatches: mismatches,
        bundlePresent: bundlePresent
      ),
      reviewedSnapshot: ContainerBuilderSnapshotAdapter.reviewedSnapshot(snapshot),
      runtimeApplicationRoot: context.applicationRoot.path(percentEncoded: false)
    )
  }
}

actor AppleContainerBuilderManagementService: ContainerBuilderManaging {
  typealias Sleeper = @Sendable (Duration) async throws -> Void

  private static let reconciliationAttempts = 20
  private static let reconciliationDelay = Duration.milliseconds(150)

  private let contextLoader: any ContainerBuilderRuntimeContextLoading
  private let transport: any ContainerBuilderTransport
  private let inspector: ContainerBuilderInspector
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator
  private let buildExecutionCoordinator: RuntimeMutationCoordinator
  private let sleep: Sleeper

  init(
    contextLoader: any ContainerBuilderRuntimeContextLoading =
      AppleContainerBuilderRuntimeContextLoader(),
    transport: any ContainerBuilderTransport = AppleContainerBuilderClient(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared,
    buildExecutionCoordinator: RuntimeMutationCoordinator = .imageBuilds,
    nodeExists: @escaping ContainerBuilderNodeExists = defaultContainerBuilderNodeExists,
    sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) }
  ) {
    self.contextLoader = contextLoader
    self.transport = transport
    inspector = ContainerBuilderInspector(
      transport: transport,
      nodeExists: nodeExists
    )
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
    self.buildExecutionCoordinator = buildExecutionCoordinator
    self.sleep = sleep
  }

  func loadBuilder() async throws -> ContainerBuilderInspection {
    try await inspector.inspect(context: contextLoader.load())
  }

  func prepareBuilderAction(
    _ action: ContainerBuilderManagementAction
  ) async throws -> ContainerBuilderManagementPlan {
    let inspection = try await loadBuilder()
    if inspection.builder.hasOrphanedBundle {
      throw ContainerBuilderManagementError.orphanedBundle
    }
    guard inspection.builder.isPresent else {
      throw ContainerBuilderManagementError.builderAbsent
    }
    guard inspection.builder.isTrustedBuilder else {
      throw ContainerBuilderManagementError.untrustedBuilder
    }
    guard inspection.builder.state != .stopping,
      inspection.builder.state != .unknown
    else {
      throw ContainerBuilderManagementError.builderStateUnavailable
    }
    return try ContainerBuilderManagementPlan(
      action: action,
      inspection: inspection
    )
  }

  func performBuilderAction(
    _ plan: ContainerBuilderManagementPlan,
    authorization: ContainerBuilderManagementAuthorization
  ) async throws -> ContainerBuilderManagementResult {
    if plan.action == .stop || plan.action == .forceStop {
      guard authorization.allowsInterruptRunningBuilder else {
        throw ContainerBuilderManagementError.interruptionRequiresConfirmation
      }
    }

    let runtimeMutationCoordinator = runtimeMutationCoordinator
    return try await buildExecutionCoordinator.perform { [self] in
      try await runtimeMutationCoordinator.perform { [self] in
        try await executeLocked(plan)
      }
    }
  }

  private func executeLocked(
    _ plan: ContainerBuilderManagementPlan
  ) async throws -> ContainerBuilderManagementResult {
    let context = try await contextLoader.load()
    guard
      context.applicationRoot.path(percentEncoded: false)
        == plan.runtimeApplicationRoot
    else {
      throw ContainerBuilderManagementError.staleReview
    }

    let inspection = try await inspector.inspect(context: context)
    try requireExactReviewedState(inspection, plan: plan)

    do {
      switch plan.action {
      case .stop:
        try await transport.stop(id: ContainerBuilderRecord.containerID)
      case .forceStop:
        try await transport.kill(id: ContainerBuilderRecord.containerID)
      case .deleteBuilderAndCache:
        try await transport.delete(id: ContainerBuilderRecord.containerID)
      }
    } catch {
      // Every mutation can commit before its XPC reply fails. Reconciliation
      // below is authoritative and intentionally runs outside caller cancellation.
    }

    return try await reconcile(plan: plan, context: context)
  }

  private func requireExactReviewedState(
    _ inspection: ContainerBuilderInspection,
    plan: ContainerBuilderManagementPlan
  ) throws {
    guard
      inspection.runtimeApplicationRoot == plan.runtimeApplicationRoot,
      inspection.builder.isTrustedBuilder,
      inspection.reviewedSnapshot == plan.reviewedSnapshot
    else {
      throw ContainerBuilderManagementError.staleReview
    }

    switch plan.action {
    case .stop, .forceStop:
      guard inspection.builder.state == .running else {
        throw ContainerBuilderManagementError.staleReview
      }
    case .deleteBuilderAndCache:
      guard inspection.builder.state == .stopped else {
        throw ContainerBuilderManagementError.staleReview
      }
    }
  }

  private func reconcile(
    plan: ContainerBuilderManagementPlan,
    context: ContainerBuilderRuntimeContext
  ) async throws -> ContainerBuilderManagementResult {
    let inspector = inspector
    let sleep = sleep
    return try await Task.detached(priority: .utility) {
      var lastFailure: String?

      for attempt in 0..<Self.reconciliationAttempts {
        do {
          let inspection = try await inspector.inspect(context: context)
          switch plan.action {
          case .stop, .forceStop:
            if inspection.builder.state == .stopped {
              guard Self.matchesReviewedIdentity(inspection, plan: plan) else {
                throw ContainerBuilderManagementError.staleReview
              }
              return ContainerBuilderManagementResult(
                action: plan.action,
                inspection: inspection
              )
            }
            guard inspection.builder.isPresent else {
              throw ContainerBuilderManagementError.staleReview
            }
            guard Self.matchesReviewedIdentity(inspection, plan: plan) else {
              throw ContainerBuilderManagementError.staleReview
            }
            if inspection.builder.state == .unknown {
              throw ContainerBuilderManagementError.builderStateUnavailable
            }
          case .deleteBuilderAndCache:
            if !inspection.builder.isPresent {
              guard !inspection.builder.bundlePresent else {
                throw ContainerBuilderManagementError.incompleteBundleCleanup
              }
              return ContainerBuilderManagementResult(
                action: plan.action,
                inspection: inspection
              )
            }
            guard Self.matchesReviewedIdentity(inspection, plan: plan) else {
              throw ContainerBuilderManagementError.staleReview
            }
            guard inspection.builder.state == .stopped else {
              throw ContainerBuilderManagementError.staleReview
            }
          }
        } catch let error as ContainerBuilderManagementError {
          throw error
        } catch {
          lastFailure = error.localizedDescription
        }

        if attempt + 1 < Self.reconciliationAttempts {
          try await sleep(Self.reconciliationDelay)
        }
      }

      if let lastFailure {
        throw ContainerBuilderManagementError.reconciliationFailed(lastFailure)
      }
      switch plan.action {
      case .stop, .forceStop:
        throw ContainerBuilderManagementError.stopFailed
      case .deleteBuilderAndCache:
        throw ContainerBuilderManagementError.deleteFailed
      }
    }.value
  }

  private nonisolated static func matchesReviewedIdentity(
    _ inspection: ContainerBuilderInspection,
    plan: ContainerBuilderManagementPlan
  ) -> Bool {
    guard
      inspection.runtimeApplicationRoot == plan.runtimeApplicationRoot,
      inspection.builder.isTrustedBuilder,
      let current = inspection.reviewedSnapshot
    else {
      return false
    }
    return
      current.creationDate == plan.reviewedSnapshot.creationDate
      && current.safety.identity == plan.reviewedSnapshot.safety.identity
      && current.safety.configuration == plan.reviewedSnapshot.safety.configuration
  }

}
