import ContainerResource
import ContainerXPC
import Foundation

struct AppleContainerCleanupClient: Sendable {
  private static let serviceIdentifier = "com.apple.container.apiserver"

  let operationTimeout: Duration

  init(operationTimeout: Duration = .seconds(15)) {
    self.operationTimeout = operationTimeout
  }

  func list(id: String) async throws -> [ContainerSnapshot] {
    let message = XPCMessage(route: .containerList)
    message.set(
      key: .listFilters,
      value: try JSONEncoder().encode(ContainerListFilters(ids: [id]))
    )
    let response = try await send(message)
    guard let data = response.dataNoCopy(key: .containers) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
  }

  func kill(id: String) async throws {
    let message = XPCMessage(route: .containerKill)
    message.set(key: .id, value: id)
    message.set(key: .processIdentifier, value: id)
    message.set(key: .signal, value: "KILL")
    _ = try await send(message)
  }

  func forceDelete(id: String) async throws {
    let message = XPCMessage(route: .containerDelete)
    message.set(key: .id, value: id)
    message.set(key: .forceDelete, value: true)
    _ = try await send(message)
  }

  private func send(_ message: XPCMessage) async throws -> XPCMessage {
    let client = XPCClient(service: Self.serviceIdentifier)
    defer { client.close() }

    return try await withTaskCancellationHandler {
      try await client.send(message, responseTimeout: operationTimeout)
    } onCancel: {
      client.close()
    }
  }
}
