import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Foundation

struct AppleInfrastructureClient: Sendable {
  private static let serviceIdentifier = "com.apple.container.apiserver"

  let operationTimeout: Duration

  init(operationTimeout: Duration = .seconds(60)) {
    self.operationTimeout = operationTimeout
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
    let client = XPCClient(service: Self.serviceIdentifier)
    let watchdogState = XPCWatchdogState()
    let watchdog = Task {
      do {
        try await Task.sleep(for: operationTimeout)
        guard !Task.isCancelled else { return }
        watchdogState.markTimedOut()
        client.close()
      } catch {
        // Cancellation is the normal completion path for the watchdog.
      }
    }

    defer {
      watchdog.cancel()
      client.close()
    }

    do {
      return try await withTaskCancellationHandler {
        try await client.send(message)
      } onCancel: {
        client.close()
      }
    } catch {
      if watchdogState.didTimeOut {
        throw ResourceManagementError.operationTimedOut(operation)
      }
      try Task.checkCancellation()
      throw error
    }
  }
}

private final class XPCWatchdogState: @unchecked Sendable {
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
