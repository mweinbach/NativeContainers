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
