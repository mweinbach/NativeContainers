import ContainerResource
import Foundation
import Network

struct InventoryPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.warmInventory

  private let inventory: any ContainerInventoryLoading

  init(inventory: any ContainerInventoryLoading) {
    self.inventory = inventory
  }

  func perform() async throws -> Int64? {
    _ = try await inventory.loadInventory()
    return nil
  }
}

struct ContainerStartupBenchmarkObservation: Equatable, Sendable {
  let state: RuntimeState
  let startedAt: Date?
  let operationID: UUID?
  let imageReference: String
  let imageDigest: String
}

protocol ContainerStartupBenchmarkStateReading: Sendable {
  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation
  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation?
}

struct AppleContainerStartupBenchmarkStateReader:
  ContainerStartupBenchmarkStateReading
{
  private let snapshots: any ContainerSnapshotReading

  init(
    snapshots: any ContainerSnapshotReading = AppleContainerSnapshotReader()
  ) {
    self.snapshots = snapshots
  }

  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation {
    Self.observation(from: try await snapshots.get(id: id))
  }

  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation? {
    guard let snapshot = try await snapshots.list().first(where: { $0.id == id }) else {
      return nil
    }
    return Self.observation(from: snapshot)
  }

  private static func observation(
    from snapshot: ContainerSnapshot
  ) -> ContainerStartupBenchmarkObservation {
    ContainerStartupBenchmarkObservation(
      state: RuntimeState(rawValue: snapshot.status.rawValue) ?? .unknown,
      startedAt: snapshot.startedDate,
      operationID: snapshot.configuration.labels[
        AppleContainerOwnership.creationOperationLabel
      ].flatMap { UUID(uuidString: $0) },
      imageReference: snapshot.configuration.image.reference,
      imageDigest: snapshot.configuration.image.digest
    )
  }
}

actor ColdContainerStartupPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.coldContainerStartup

  private struct PreparedContainer: Sendable {
    let id: String
    let operationID: UUID
    var didCreate: Bool
  }

  private let containers: any ContainerCreating & ContainerLifecycleManaging
  private let stateReader: any ContainerStartupBenchmarkStateReading
  private let imageReference: String
  private let expectedImageDigest: String
  private let makeContainerID: @Sendable () -> String
  private var preparedContainer: PreparedContainer?

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-perf-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) {
    self.containers = containers
    self.stateReader = stateReader
    self.imageReference = imageReference
    self.expectedImageDigest = expectedImageDigest
    self.makeContainerID = makeContainerID
  }

  func prepareIteration() async throws {
    guard preparedContainer == nil else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }

    let id = makeContainerID()
    let operationID = UUID()
    preparedContainer = PreparedContainer(
      id: id,
      operationID: operationID,
      didCreate: false
    )
    let request = try ContainerCreationRequest(
      operationID: operationID,
      name: id,
      imageReference: imageReference,
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/sleep", "3600"],
      startAfterCreation: false,
      removeWhenStopped: false
    )
    try await containers.createContainer(request: request) { _ in }
    preparedContainer?.didCreate = true

    let observation = try await requireReviewedObservation(
      id: id,
      operationID: operationID
    )
    guard observation.state == .stopped, observation.startedAt == nil else {
      throw ColdContainerStartupBenchmarkError.containerWasNotPrepared(id)
    }
  }

  func perform() async throws -> Int64? {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }

    try await containers.startContainer(id: preparedContainer.id)
    let observation = try await requireReviewedObservation(
      id: preparedContainer.id,
      operationID: preparedContainer.operationID
    )
    guard observation.state == .running, observation.startedAt != nil else {
      throw ColdContainerStartupBenchmarkError.startNotConfirmed(
        preparedContainer.id
      )
    }
    return nil
  }

  func cleanUpIteration() async throws {
    guard let preparedContainer else { return }
    self.preparedContainer = nil
    guard preparedContainer.didCreate else { return }

    do {
      try await stopIfNeeded(preparedContainer)
      _ = try await requireOwnedObservation(
        id: preparedContainer.id,
        operationID: preparedContainer.operationID
      )
      try await containers.deleteContainer(id: preparedContainer.id)
      try await requireReviewedContainerAbsent(preparedContainer)
    } catch {
      let operation = error.localizedDescription
      do {
        try await forceDelete(preparedContainer)
      } catch {
        throw ColdContainerStartupBenchmarkError.cleanupFailed(
          id: preparedContainer.id,
          operation: operation,
          recovery: error.localizedDescription
        )
      }
      throw ColdContainerStartupBenchmarkError.cleanupRequiredRecovery(
        id: preparedContainer.id,
        operation: operation
      )
    }
  }

  private func stopIfNeeded(_ container: PreparedContainer) async throws {
    let observation = try await requireOwnedObservation(
      id: container.id,
      operationID: container.operationID
    )
    guard observation.state != .stopped else { return }

    do {
      try await containers.stopContainer(id: container.id)
      try await waitForStoppedContainer(container)
    } catch {
      _ = try await requireOwnedObservation(
        id: container.id,
        operationID: container.operationID
      )
      try await containers.forceStopContainer(id: container.id)
      try await waitForStoppedContainer(container)
    }
  }

  private func forceDelete(_ container: PreparedContainer) async throws {
    guard
      let observation = try await stateReader.listedObservation(
        forContainerID: container.id
      )
    else {
      return
    }
    guard observation.operationID == container.operationID else {
      throw ColdContainerStartupBenchmarkError.replacementPresent(container.id)
    }

    if observation.state != .stopped {
      try? await containers.forceStopContainer(id: container.id)
      try? await waitForStoppedContainer(container)
    }
    _ = try await requireOwnedObservation(
      id: container.id,
      operationID: container.operationID
    )
    try await containers.deleteContainer(id: container.id)
    try await requireReviewedContainerAbsent(container)
  }

  private func waitForStoppedContainer(
    _ container: PreparedContainer
  ) async throws {
    for _ in 0..<100 {
      let observation = try await requireOwnedObservation(
        id: container.id,
        operationID: container.operationID
      )
      if observation.state == .stopped {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ColdContainerStartupBenchmarkError.stopTimedOut(container.id)
  }

  private func requireOwnedObservation(
    id: String,
    operationID: UUID
  ) async throws -> ContainerStartupBenchmarkObservation {
    let observation = try await stateReader.observation(forContainerID: id)
    guard observation.operationID == operationID else {
      throw ColdContainerStartupBenchmarkError.identityChanged(id)
    }
    return observation
  }

  private func requireReviewedObservation(
    id: String,
    operationID: UUID
  ) async throws -> ContainerStartupBenchmarkObservation {
    let observation = try await requireOwnedObservation(
      id: id,
      operationID: operationID
    )
    guard
      observation.imageReference == imageReference,
      observation.imageDigest == expectedImageDigest
    else {
      throw ColdContainerStartupBenchmarkError.imageIdentityChanged(id)
    }
    return observation
  }

  private func requireReviewedContainerAbsent(
    _ container: PreparedContainer
  ) async throws {
    guard
      let remaining = try await stateReader.listedObservation(
        forContainerID: container.id
      )
    else {
      return
    }
    guard remaining.operationID == container.operationID else {
      throw ColdContainerStartupBenchmarkError.replacementPresent(container.id)
    }
    throw ColdContainerStartupBenchmarkError.deletionNotConfirmed(container.id)
  }
}

enum ColdContainerStartupBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidIterationState
  case containerWasNotPrepared(String)
  case startNotConfirmed(String)
  case identityChanged(String)
  case imageIdentityChanged(String)
  case replacementPresent(String)
  case stopTimedOut(String)
  case deletionNotConfirmed(String)
  case cleanupRequiredRecovery(id: String, operation: String)
  case cleanupFailed(id: String, operation: String, recovery: String)

  var errorDescription: String? {
    switch self {
    case .invalidIterationState:
      "The cold-start benchmark iteration is not in a valid state."
    case .containerWasNotPrepared(let id):
      "Benchmark container “\(id)” was not prepared in the stopped state."
    case .startNotConfirmed(let id):
      "Benchmark container “\(id)” did not reach an authoritative running state."
    case .identityChanged(let id):
      "Benchmark container “\(id)” changed after preparation."
    case .imageIdentityChanged(let id):
      "Benchmark container “\(id)” does not use the reviewed image identity."
    case .replacementPresent(let id):
      "A replacement named “\(id)” appeared during benchmark cleanup and was not modified."
    case .stopTimedOut(let id):
      "Benchmark container “\(id)” did not stop within five seconds."
    case .deletionNotConfirmed(let id):
      "Benchmark container “\(id)” remained after cleanup."
    case .cleanupRequiredRecovery(let id, let operation):
      "Benchmark container “\(id)” required force-cleanup after: \(operation)"
    case .cleanupFailed(let id, let operation, let recovery):
      "Benchmark container “\(id)” cleanup failed after “\(operation)”: \(recovery)"
    }
  }
}

struct PrivateDiskPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.privateDiskIO

  private static let chunk = Data(repeating: 0xA5, count: 1_048_576)

  private let workspaceDirectoryURL: URL
  private let payloadByteCount: Int

  init(
    workspaceDirectoryURL: URL,
    payloadByteCount: Int = 16 * 1_048_576
  ) {
    self.workspaceDirectoryURL = workspaceDirectoryURL
    self.payloadByteCount = max(1, payloadByteCount)
  }

  func perform() async throws -> Int64? {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: workspaceDirectoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw PerformanceBenchmarkError.privateDiskWorkspaceUnavailable
    }

    let fileURL = workspaceDirectoryURL.appending(
      path: "disk-\(UUID().uuidString.lowercased()).benchmark"
    )
    guard
      fileManager.createFile(
        atPath: fileURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw PerformanceBenchmarkError.privateDiskWriteFailed
    }
    defer { try? fileManager.removeItem(at: fileURL) }

    do {
      let writer = try FileHandle(forWritingTo: fileURL)
      defer { try? writer.close() }

      var remaining = payloadByteCount
      while remaining > 0 {
        try Task.checkCancellation()
        let count = min(remaining, Self.chunk.count)
        try writer.write(contentsOf: Self.chunk.prefix(count))
        remaining -= count
      }
      try writer.synchronize()
      try writer.close()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PerformanceBenchmarkError.privateDiskWriteFailed
    }

    do {
      let reader = try FileHandle(forReadingFrom: fileURL)
      defer { try? reader.close() }

      var readByteCount = 0
      while let data = try reader.read(upToCount: Self.chunk.count), !data.isEmpty {
        try Task.checkCancellation()
        readByteCount += data.count
      }
      guard readByteCount == payloadByteCount else {
        throw PerformanceBenchmarkError.privateDiskReadFailed
      }
      try reader.close()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as PerformanceBenchmarkError {
      throw error
    } catch {
      throw PerformanceBenchmarkError.privateDiskReadFailed
    }

    return Int64(payloadByteCount) * 2
  }
}

struct LoopbackNetworkPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.loopbackNetwork

  private static let defaultPayloadByteCount = 16 * 1_048_576
  private static let defaultPayload = Data(
    repeating: 0x5A,
    count: defaultPayloadByteCount
  )

  private let payloadByteCount: Int
  private let timeout: Duration

  init(
    payloadByteCount: Int = defaultPayloadByteCount,
    timeout: Duration = .seconds(10)
  ) {
    self.payloadByteCount = max(1, payloadByteCount)
    self.timeout = timeout
  }

  func perform() async throws -> Int64? {
    let payload =
      payloadByteCount == Self.defaultPayloadByteCount
      ? Self.defaultPayload
      : Data(repeating: 0x5A, count: payloadByteCount)
    let transfer = NetworkFrameworkLoopbackTransfer(payload: payload)

    return try await withThrowingTaskGroup(of: Int64.self) { group in
      group.addTask {
        try await transfer.run()
        return Int64(payload.count)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw PerformanceBenchmarkError.loopbackTimedOut
      }

      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw PerformanceBenchmarkError.loopbackConnectionFailed
      }
      return result
    }
  }
}

private final class NetworkFrameworkLoopbackTransfer: @unchecked Sendable {
  private let payload: Data
  private let queue = DispatchQueue(
    label: "com.nativecontainers.performance.loopback",
    qos: .userInitiated
  )

  private var listener: NWListener?
  private var client: NWConnection?
  private var server: NWConnection?
  private var continuation: CheckedContinuation<Void, any Error>?
  private var receivedByteCount = 0
  private var didStartClientSend = false
  private var didStartServerReceive = false
  private var isFinished = false

  init(payload: Data) {
    self.payload = payload
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          self.start(continuation: continuation)
        }
      }
    } onCancel: {
      queue.async {
        self.finish(.failure(CancellationError()))
      }
    }
  }

  private func start(continuation: CheckedContinuation<Void, any Error>) {
    guard !isFinished else {
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation

    do {
      let listener = try NWListener(using: .tcp, on: .any)
      self.listener = listener
      listener.newConnectionLimit = 1
      listener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerState(state)
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: queue)
    } catch {
      finish(.failure(PerformanceBenchmarkError.loopbackListenerUnavailable))
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let port = listener?.port, client == nil else { return }
      let client = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: port,
        using: .tcp
      )
      self.client = client
      client.stateUpdateHandler = { [weak self] state in
        self?.handleClientState(state)
      }
      client.start(queue: queue)
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackListenerUnavailable))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    guard server == nil, !isFinished else {
      connection.cancel()
      return
    }
    server = connection
    connection.stateUpdateHandler = { [weak self] state in
      self?.handleServerState(state)
    }
    connection.start(queue: queue)
  }

  private func handleClientState(_ state: NWConnection.State) {
    switch state {
    case .ready:
      guard !didStartClientSend else { return }
      didStartClientSend = true
      client?.send(
        content: payload,
        contentContext: .defaultStream,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          guard error != nil else { return }
          self?.finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
        }
      )
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func handleServerState(_ state: NWConnection.State) {
    switch state {
    case .ready:
      guard !didStartServerReceive else { return }
      didStartServerReceive = true
      receiveNextChunk()
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func receiveNextChunk() {
    server?.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1_024
    ) { [weak self] data, _, isComplete, error in
      guard let self, !isFinished else { return }

      if let data {
        receivedByteCount += data.count
      }
      if error != nil {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      } else if receivedByteCount == payload.count {
        finish(.success(()))
      } else if receivedByteCount > payload.count || isComplete {
        finish(
          .failure(
            PerformanceBenchmarkError.loopbackTransferIncomplete(
              expected: payload.count,
              actual: receivedByteCount
            )
          )
        )
      } else {
        receiveNextChunk()
      }
    }
  }

  private func finish(_ result: Result<Void, any Error>) {
    guard !isFinished else { return }
    isFinished = true

    listener?.cancel()
    client?.cancel()
    server?.cancel()
    listener = nil
    client = nil
    server = nil

    let continuation = continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }
}
