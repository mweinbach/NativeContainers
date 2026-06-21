import Foundation

protocol ComposeResourceActionExecuting: Sendable {
  func delete(_ action: ComposeProjectNetworkAction) async throws
  func delete(_ action: ComposeProjectVolumeAction) async throws
}

struct ComposeResourceActionService: ComposeResourceActionExecuting {
  private let infrastructure: any AppleInfrastructureTransport
  private let inventory: any ContainerInventoryLoading

  init(
    infrastructure: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    inventory: any ContainerInventoryLoading
  ) {
    self.infrastructure = infrastructure
    self.inventory = inventory
  }

  func delete(_ action: ComposeProjectNetworkAction) async throws {
    guard action.operation == .removeManaged, let expected = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let before = try await inventory.loadInventory()
    guard
      let record = before.networks.first(where: { $0.id == expected.id }),
      expected.matches(record),
      record.name == action.runtimeName,
      record.usedByContainerIDs.isEmpty,
      !record.isBuiltin
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await infrastructure.deleteNetwork(id: record.id)
    } catch {
      let reconciled = try await inventory.loadInventory()
      if !reconciled.networks.contains(where: { $0.id == expected.id }) {
        return
      }
      throw error
    }

    let confirmed = try await inventory.loadInventory()
    guard
      !confirmed.networks.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      })
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Network \(action.runtimeName) remained present after deletion."
      )
    }
  }

  func delete(_ action: ComposeProjectVolumeAction) async throws {
    guard action.operation == .removeManaged, let expected = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let before = try await inventory.loadInventory()
    guard
      let record = before.volumes.first(where: { $0.id == expected.id }),
      expected.matches(record),
      record.name == action.runtimeName,
      record.usedByContainerIDs.isEmpty
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await infrastructure.deleteVolume(name: record.name)
    } catch {
      let reconciled = try await inventory.loadInventory()
      if !reconciled.volumes.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      }) {
        return
      }
      throw error
    }

    let confirmed = try await inventory.loadInventory()
    guard
      !confirmed.volumes.contains(where: {
        $0.id == expected.id || $0.name == expected.configuration.name
      })
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Volume \(action.runtimeName) remained present after deletion."
      )
    }
  }
}
