import ContainerPersistence
import ContainerResource
import ContainerXPC
import Foundation
import MachineAPIClient

protocol AppleMachineTransport: Sendable {
  func list() async throws -> [MachineSnapshot]
  func inspect(id: String) async throws -> MachineSnapshot
  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) async throws
  func boot(id: String, dynamicEnvironment: [String: String]) async throws -> MachineSnapshot
  func stop(id: String) async throws
  func delete(id: String) async throws
}

struct AppleMachineXPCTransport: AppleMachineTransport {
  private let requestSender: any AppleXPCRequestSending

  init(operationTimeout: Duration = .seconds(35)) {
    requestSender = AppleXPCRequestClient(
      serviceIdentifier: MachineClient.serviceIdentifier,
      operationTimeout: operationTimeout
    )
  }

  init(requestSender: any AppleXPCRequestSending) {
    self.requestSender = requestSender
  }

  func list() async throws -> [MachineSnapshot] {
    let response = try await send(
      XPCMessage(route: MachineRoutes.listMachine.rawValue),
      operation: "List Linux machines"
    )
    guard let data = response.dataNoCopy(key: MachineKeys.machines.rawValue) else {
      return []
    }
    return try JSONDecoder().decode([MachineSnapshot].self, from: data)
  }

  func inspect(id: String) async throws -> MachineSnapshot {
    let message = XPCMessage(route: MachineRoutes.inspectMachine.rawValue)
    message.set(key: MachineKeys.id.rawValue, value: id)
    let response = try await send(message, operation: "Inspect Linux machine \(id)")
    guard let data = response.dataNoCopy(key: MachineKeys.snapshot.rawValue) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode(MachineSnapshot.self, from: data)
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) async throws {
    let message = XPCMessage(route: MachineRoutes.createMachine.rawValue)
    message.set(
      key: MachineKeys.machineConfig.rawValue,
      value: try JSONEncoder().encode(configuration)
    )
    if let resources {
      message.set(
        key: MachineKeys.machineResources.rawValue,
        value: try JSONEncoder().encode(resources)
      )
    }
    message.set(
      key: MachineKeys.bootConfig.rawValue,
      value: try JSONEncoder().encode(bootConfig)
    )
    _ = try await send(message, operation: "Create Linux machine \(configuration.id)")
  }

  func boot(
    id: String,
    dynamicEnvironment: [String: String]
  ) async throws -> MachineSnapshot {
    let message = XPCMessage(route: MachineRoutes.bootMachine.rawValue)
    message.set(key: MachineKeys.id.rawValue, value: id)
    message.set(
      key: MachineKeys.dynamicEnv.rawValue,
      value: try JSONEncoder().encode(dynamicEnvironment)
    )
    let response = try await send(message, operation: "Start Linux machine \(id)")
    guard let data = response.dataNoCopy(key: MachineKeys.snapshot.rawValue) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode(MachineSnapshot.self, from: data)
  }

  func stop(id: String) async throws {
    let message = XPCMessage(route: MachineRoutes.stopMachine.rawValue)
    message.set(key: MachineKeys.id.rawValue, value: id)
    _ = try await send(message, operation: "Stop Linux machine \(id)")
  }

  func delete(id: String) async throws {
    let message = XPCMessage(route: MachineRoutes.deleteMachine.rawValue)
    message.set(key: MachineKeys.id.rawValue, value: id)
    _ = try await send(message, operation: "Delete Linux machine \(id)")
  }

  private func send(
    _ message: XPCMessage,
    operation: String
  ) async throws -> XPCMessage {
    try await requestSender.send(message, operation: operation)
  }
}
