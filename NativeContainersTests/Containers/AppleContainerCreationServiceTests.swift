import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container creation service")
struct AppleContainerCreationServiceTests {
  @Test
  func queuedCancellationInvokesOwnedRecovery() async throws {
    let operationID = UUID()
    let coordinator = RuntimeMutationCoordinator()
    let gate = MutationGate()
    let recovery = CreationRecoveryDouble()
    let attachments = CreationAttachmentDouble()
    let service = AppleContainerCreationService(
      attachmentService: attachments,
      lifecycleService: EmptyContainerLifecycleService(),
      ownedContainerRecovery: recovery,
      runtimeMutationCoordinator: coordinator
    )
    let blocker = Task {
      try await coordinator.perform {
        await gate.hold()
      }
    }
    await gate.waitUntilEntered()
    let request = try ContainerCreationRequest(
      operationID: operationID,
      name: "cancelled-create",
      imageReference: "alpine:latest"
    )
    let creation = Task {
      try await service.createContainer(request: request) { _ in }
    }

    creation.cancel()
    await gate.release()
    try await blocker.value

    await #expect(throws: CancellationError.self) {
      try await creation.value
    }
    #expect(
      await recovery.calls == [
        CreationRecoveryCall(id: request.name, operationID: operationID)
      ]
    )
    #expect(await attachments.cleanedOperationIDs == [operationID])
  }

  @Test
  func cleanupFailurePreservesBothOperationAndRecoveryFailure() async throws {
    let coordinator = RuntimeMutationCoordinator()
    let gate = MutationGate()
    let recovery = CreationRecoveryDouble(shouldFail: true)
    let service = AppleContainerCreationService(
      attachmentService: CreationAttachmentDouble(),
      lifecycleService: EmptyContainerLifecycleService(),
      ownedContainerRecovery: recovery,
      runtimeMutationCoordinator: coordinator
    )
    let blocker = Task {
      try await coordinator.perform {
        await gate.hold()
      }
    }
    await gate.waitUntilEntered()
    let request = try ContainerCreationRequest(
      name: "cleanup-failure",
      imageReference: "alpine:latest"
    )
    let creation = Task {
      try await service.createContainer(request: request) { _ in }
    }

    creation.cancel()
    await gate.release()
    try await blocker.value

    do {
      try await creation.value
      Issue.record("Expected creation and cleanup to fail")
    } catch {
      #expect(error.localizedDescription.contains("Automatic KILL and force deletion"))
      #expect(error.localizedDescription.contains("simulated cleanup failure"))
    }
  }
}

private struct CreationRecoveryCall: Equatable, Sendable {
  let id: String
  let operationID: UUID
}

private enum CreationRecoveryTestError: LocalizedError {
  case failed

  var errorDescription: String? {
    "simulated cleanup failure"
  }
}

private actor CreationRecoveryDouble: OwnedContainerRecovering {
  private let shouldFail: Bool
  private(set) var calls: [CreationRecoveryCall] = []

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func removeOwnedContainer(id: String, operationID: UUID) async throws {
    calls.append(CreationRecoveryCall(id: id, operationID: operationID))
    if shouldFail {
      throw CreationRecoveryTestError.failed
    }
  }
}

private actor CreationAttachmentDouble: ContainerAttachmentManaging {
  private(set) var cleanedOperationIDs: [UUID] = []

  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment {
    ContainerAttachmentEnvironment(
      publishedSocketRootPath: "",
      hostAccess: .empty
    )
  }

  func resolveAttachments(
    _ selection: ContainerAttachmentSelection,
    operationID: UUID,
    containerID: String,
    dnsDomain: String?
  ) async throws -> ResolvedContainerAttachments {
    ResolvedContainerAttachments(
      mounts: [],
      networks: [],
      publishedSockets: []
    )
  }

  func validatePublishedSocketsBeforeStart(
    _ sockets: [PublishSocket],
    operationID: UUID
  ) async throws {}

  func cleanupPublishedSocketWorkspace(operationID: UUID) async {
    cleanedOperationIDs.append(operationID)
  }
}

private actor EmptyContainerLifecycleService: ContainerLifecycleManaging {
  func startContainer(id: String) async throws {}
  func stopContainer(id: String) async throws {}
  func restartContainer(id: String) async throws {}
  func forceStopContainer(id: String) async throws {}
  func deleteContainer(id: String) async throws {}
}

private actor MutationGate {
  private var hasEntered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func hold() async {
    hasEntered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
