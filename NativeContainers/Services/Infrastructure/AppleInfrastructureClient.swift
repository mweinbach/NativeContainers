import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Foundation
import XPC

protocol AppleInfrastructureTransport: Sendable {
  func createVolume(
    name: String,
    driver: String,
    driverOptions: [String: String],
    labels: [String: String]
  ) async throws -> VolumeConfiguration
  func deleteVolume(name: String) async throws
  func listVolumes() async throws -> [VolumeConfiguration]
  func volumeDiskUsage(name: String) async throws -> UInt64
  func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkResource
  func deleteNetwork(id: String) async throws
  func listNetworks() async throws -> [NetworkResource]
}

struct AppleInfrastructureClient: AppleInfrastructureTransport {
  private let requestSender: any AppleXPCRequestSending

  init(operationTimeout: Duration = .seconds(60)) {
    requestSender = AppleXPCRequestClient(operationTimeout: operationTimeout)
  }

  init(requestSender: any AppleXPCRequestSending) {
    self.requestSender = requestSender
  }

  func createVolume(
    name: String,
    driver: String = "local",
    driverOptions: [String: String],
    labels: [String: String]
  ) async throws -> VolumeConfiguration {
    let message = XPCMessage(route: .volumeCreate)
    message.set(key: .volumeName, value: name)
    message.set(key: .volumeDriver, value: driver)
    message.set(key: .volumeDriverOpts, value: try JSONEncoder().encode(driverOptions))
    message.set(key: .volumeLabels, value: try JSONEncoder().encode(labels))
    let response = try await send(message, operation: "Create volume \(name)")
    guard let data = response.dataNoCopy(key: .volume) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode(VolumeConfiguration.self, from: data)
  }

  func deleteVolume(name: String) async throws {
    let message = XPCMessage(route: .volumeDelete)
    message.set(key: .volumeName, value: name)
    _ = try await send(message, operation: "Delete volume \(name)")
  }

  func listVolumes() async throws -> [VolumeConfiguration] {
    let response = try await send(
      XPCMessage(route: .volumeList),
      operation: "List volumes"
    )
    guard let data = response.dataNoCopy(key: .volumes) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([VolumeConfiguration].self, from: data)
  }

  func volumeDiskUsage(name: String) async throws -> UInt64 {
    let message = XPCMessage(route: .volumeDiskUsage)
    message.set(key: .volumeName, value: name)
    let response = try await send(message, operation: "Inspect volume storage \(name)")
    let hasVolumeSize = XPCKeys.volumeSize.rawValue.withCString { key in
      guard let value = xpc_dictionary_get_value(response.underlying, key) else {
        return false
      }
      return xpc_get_type(value) == XPC_TYPE_UINT64
    }
    guard hasVolumeSize else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return response.uint64(key: .volumeSize)
  }

  func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkResource {
    let message = XPCMessage(route: .networkCreate)
    message.set(key: .networkId, value: configuration.id)
    message.set(key: .networkConfig, value: try JSONEncoder().encode(configuration))
    let response = try await send(
      message,
      operation: "Create network \(configuration.name)"
    )
    guard let data = response.dataNoCopy(key: .networkResource) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode(NetworkResource.self, from: data)
  }

  func deleteNetwork(id: String) async throws {
    let message = XPCMessage(route: .networkDelete)
    message.set(key: .networkId, value: id)
    _ = try await send(message, operation: "Delete network \(id)")
  }

  func listNetworks() async throws -> [NetworkResource] {
    let response = try await send(
      XPCMessage(route: .networkList),
      operation: "List networks"
    )
    guard let data = response.dataNoCopy(key: .networkResources) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([NetworkResource].self, from: data)
  }

  private func send(
    _ message: XPCMessage,
    operation: String
  ) async throws -> XPCMessage {
    try await requestSender.send(message, operation: operation)
  }
}
