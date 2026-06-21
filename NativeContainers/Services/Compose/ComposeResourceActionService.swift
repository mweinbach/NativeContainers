import ContainerResource
import ContainerizationExtras
import Foundation

struct ComposeResourceCreationContext: Equatable, Sendable {
  let projectName: String
  let composeVersion: String
  let operationID: UUID
}

protocol ComposeResourceActionExecuting: Sendable {
  func create(
    _ action: ComposeProjectNetworkAction,
    context: ComposeResourceCreationContext
  ) async throws
  func create(
    _ action: ComposeProjectVolumeAction,
    context: ComposeResourceCreationContext
  ) async throws
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

  func create(
    _ action: ComposeProjectNetworkAction,
    context: ComposeResourceCreationContext
  ) async throws {
    guard action.operation == .createManaged, action.expectedIdentity == nil else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let labels = managedLabels(
      logicalName: action.logicalName,
      logicalLabelKey: ComposeLabelKey.network,
      context: context
    )
    let before = try await inventory.loadInventory()
    guard !before.networks.contains(where: { $0.name == action.runtimeName }) else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    try Task.checkCancellation()

    let configuration = try NetworkConfiguration(
      name: action.runtimeName,
      mode: .nat,
      labels: ResourceLabels(labels),
      plugin: "container-network-vmnet"
    )
    do {
      _ = try await infrastructure.createNetwork(configuration: configuration)
    } catch {
      let reconciled = try await inventory.loadInventory()
      guard network(action, labels: labels, existsIn: reconciled) else {
        throw error
      }
      return
    }
    try Task.checkCancellation()
    let confirmed = try await inventory.loadInventory()
    guard network(action, labels: labels, existsIn: confirmed) else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Network \(action.runtimeName) did not reach its reviewed native configuration."
      )
    }
  }

  func create(
    _ action: ComposeProjectVolumeAction,
    context: ComposeResourceCreationContext
  ) async throws {
    guard action.operation == .createManaged, action.expectedIdentity == nil else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    let labels = managedLabels(
      logicalName: action.logicalName,
      logicalLabelKey: ComposeLabelKey.volume,
      context: context
    )
    let before = try await inventory.loadInventory()
    guard !before.volumes.contains(where: { $0.name == action.runtimeName }) else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    try Task.checkCancellation()

    do {
      _ = try await infrastructure.createVolume(
        name: action.runtimeName,
        driver: "local",
        driverOptions: [:],
        labels: labels
      )
    } catch {
      let reconciled = try await inventory.loadInventory()
      guard volume(action, labels: labels, existsIn: reconciled) else {
        throw error
      }
      return
    }
    try Task.checkCancellation()
    let confirmed = try await inventory.loadInventory()
    guard volume(action, labels: labels, existsIn: confirmed) else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Volume \(action.runtimeName) did not reach its reviewed native configuration."
      )
    }
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

  private func managedLabels(
    logicalName: String,
    logicalLabelKey: String,
    context: ComposeResourceCreationContext
  ) -> [String: String] {
    [
      ComposeLabelKey.project: context.projectName,
      ComposeLabelKey.version: context.composeVersion,
      logicalLabelKey: logicalName,
      ResourceOperationLabel.key: context.operationID.uuidString,
    ]
  }

  private func network(
    _ action: ComposeProjectNetworkAction,
    labels: [String: String],
    existsIn inventory: ContainerInventory
  ) -> Bool {
    let matches = inventory.networks.filter { $0.name == action.runtimeName }
    guard matches.count == 1, let record = matches.first else { return false }
    return record.id == action.runtimeName
      && record.mode == .nat
      && record.configuredIPv4Subnet == nil
      && record.configuredIPv6Subnet == nil
      && record.labels == labels
      && record.plugin == "container-network-vmnet"
      && record.options.isEmpty
      && !record.isBuiltin
      && record.usedByContainerIDs.isEmpty
  }

  private func volume(
    _ action: ComposeProjectVolumeAction,
    labels: [String: String],
    existsIn inventory: ContainerInventory
  ) -> Bool {
    let matches = inventory.volumes.filter { $0.name == action.runtimeName }
    guard matches.count == 1, let record = matches.first else { return false }
    return record.driver == "local"
      && record.format == "ext4"
      && record.labels == labels
      && record.options.isEmpty
      && !record.isAnonymous
      && record.usedByContainerIDs.isEmpty
  }
}
