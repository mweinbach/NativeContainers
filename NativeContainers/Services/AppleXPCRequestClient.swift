import ContainerXPC
import Foundation

protocol AppleXPCRequestSending: Sendable {
  func send(_ message: XPCMessage, operation: String) async throws -> XPCMessage
}

protocol AppleXPCConnection: Sendable {
  func send(_ message: XPCMessage) async throws -> XPCMessage
  func close()
}

struct LiveAppleXPCConnection: AppleXPCConnection {
  private let client: XPCClient

  init(serviceIdentifier: String = "com.apple.container.apiserver") {
    client = XPCClient(service: serviceIdentifier)
  }

  func send(_ message: XPCMessage) async throws -> XPCMessage {
    try await client.send(message)
  }

  func close() {
    client.close()
  }
}

struct AppleXPCRequestClient: AppleXPCRequestSending {
  typealias ConnectionFactory = @Sendable () -> any AppleXPCConnection
  typealias Sleeper = @Sendable (Duration) async throws -> Void

  let operationTimeout: Duration
  private let makeConnection: ConnectionFactory
  private let sleep: Sleeper

  init(
    serviceIdentifier: String = "com.apple.container.apiserver",
    operationTimeout: Duration = .seconds(60)
  ) {
    self.init(
      operationTimeout: operationTimeout,
      makeConnection: { LiveAppleXPCConnection(serviceIdentifier: serviceIdentifier) },
      sleep: { duration in try await Task.sleep(for: duration) }
    )
  }

  init(
    operationTimeout: Duration,
    makeConnection: @escaping ConnectionFactory,
    sleep: @escaping Sleeper
  ) {
    self.operationTimeout = operationTimeout
    self.makeConnection = makeConnection
    self.sleep = sleep
  }

  func send(_ message: XPCMessage, operation: String) async throws -> XPCMessage {
    let connection = makeConnection()
    let watchdogState = XPCRequestWatchdogState()
    let watchdog = Task {
      do {
        try await sleep(operationTimeout)
        guard !Task.isCancelled else { return }
        watchdogState.markTimedOut()
        connection.close()
      } catch {
        // Cancellation is the normal completion path for the watchdog.
      }
    }

    defer {
      watchdog.cancel()
      connection.close()
    }

    do {
      return try await withTaskCancellationHandler {
        try await connection.send(message)
      } onCancel: {
        connection.close()
      }
    } catch {
      try Task.checkCancellation()
      if watchdogState.didTimeOut {
        throw ResourceManagementError.operationTimedOut(operation)
      }
      throw error
    }
  }
}

private final class XPCRequestWatchdogState: @unchecked Sendable {
  private let lock = NSLock()
  private var timedOut = false

  var didTimeOut: Bool {
    lock.withLock { timedOut }
  }

  func markTimedOut() {
    lock.withLock {
      timedOut = true
    }
  }
}
