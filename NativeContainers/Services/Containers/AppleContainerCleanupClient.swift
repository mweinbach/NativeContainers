import ContainerResource
import ContainerXPC
import Foundation

protocol AppleContainerCleanupTransport: Sendable {
  func list(id: String) async throws -> [ContainerSnapshot]
  func kill(id: String) async throws
  func forceDelete(id: String) async throws
}

struct AppleContainerCleanupClient: AppleContainerCleanupTransport {
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
    try await requestSender.send(message, operation: "Clean up container")
  }
}
