import ContainerXPC
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple XPC request client")
struct AppleXPCRequestClientTests {
  @Test
  func callerCancellationClosesConnectionAndSurfacesCancellation() async {
    let connection = BlockingXPCConnection()
    let client = AppleXPCRequestClient(
      operationTimeout: .seconds(60),
      makeConnection: { connection },
      sleep: { duration in try await Task.sleep(for: duration) }
    )
    let operation = Task {
      try await client.send(
        XPCMessage(route: .volumeList),
        operation: "List volumes"
      )
    }
    while !connection.hasStarted {
      await Task.yield()
    }

    operation.cancel()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
    #expect(connection.closeCount >= 1)
  }

  @Test
  func watchdogExpiryClosesConnectionAndReportsTimeout() async {
    let connection = BlockingXPCConnection()
    let client = AppleXPCRequestClient(
      operationTimeout: .milliseconds(1),
      makeConnection: { connection },
      sleep: { _ in }
    )

    await #expect(
      throws: ResourceManagementError.operationTimedOut("Probe infrastructure")
    ) {
      try await client.send(
        XPCMessage(route: .volumeList),
        operation: "Probe infrastructure"
      )
    }
    #expect(connection.closeCount >= 1)
  }
}

private enum BlockingConnectionError: Error {
  case closed
}

private final class BlockingXPCConnection: AppleXPCConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<XPCMessage, any Error>?
  private var closed = false
  private var started = false
  private var closes = 0

  var hasStarted: Bool {
    lock.withLock { started }
  }

  var closeCount: Int {
    lock.withLock { closes }
  }

  func send(_ message: XPCMessage) async throws -> XPCMessage {
    try await withCheckedThrowingContinuation { continuation in
      let shouldFail = lock.withLock {
        started = true
        if closed {
          return true
        }
        self.continuation = continuation
        return false
      }
      if shouldFail {
        continuation.resume(throwing: BlockingConnectionError.closed)
      }
    }
  }

  func close() {
    let pending = lock.withLock {
      closes += 1
      closed = true
      let pending = continuation
      continuation = nil
      return pending
    }
    pending?.resume(throwing: BlockingConnectionError.closed)
  }
}
