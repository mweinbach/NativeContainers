import Foundation

protocol ComposePostconditionVerifying: Sendable {
  func verify(plan: ComposeProjectPlan, inventory: ContainerInventory) throws
}

struct ComposePostconditionVerifier: ComposePostconditionVerifying {
  private let attachmentVerifier: ComposeContainerAttachmentVerifier

  init(
    attachmentVerifier: ComposeContainerAttachmentVerifier =
      ComposeContainerAttachmentVerifier()
  ) {
    self.attachmentVerifier = attachmentVerifier
  }

  func verify(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    switch plan.options.action {
    case .up:
      try verifyUp(plan: plan, inventory: inventory)

    case .start:
      try requireActionContainers(
        actions: plan.containerActions,
        inventory: inventory,
        stateMatches: { $0 == .running }
      )

    case .stop:
      try requireActionContainers(
        actions: plan.containerActions,
        inventory: inventory,
        stateMatches: { $0 != .running && $0 != .stopping }
      )

    case .down:
      try verifyDown(plan: plan, inventory: inventory)
    }

    try verifyPreservedIdentities(plan: plan, inventory: inventory)
  }

  private func verifyDown(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    let remainingIDs = Set(inventory.containers.map(\.id))
    let removedContainerIDs = Set(
      plan.containerActions.filter(\.removesContainer).compactMap(\.existingContainerID)
    )
    guard remainingIDs.isDisjoint(with: removedContainerIDs) else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "One or more reviewed containers remained after Down."
      )
    }

    let remainingNetworkNames = Set(inventory.networks.map(\.name))
    let removedNetworkNames = Set(
      plan.networkActions.filter { $0.operation == .removeManaged }.map(\.runtimeName)
    )
    guard remainingNetworkNames.isDisjoint(with: removedNetworkNames) else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "One or more reviewed networks remained after Down."
      )
    }

    let remainingVolumeNames = Set(inventory.volumes.map(\.name))
    let removedVolumeNames = Set(
      plan.volumeActions.filter { $0.operation == .removeManaged }.map(\.runtimeName)
    )
    guard remainingVolumeNames.isDisjoint(with: removedVolumeNames) else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "One or more reviewed volumes remained after Down."
      )
    }
  }

  private func verifyUp(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    let projectContainers = inventory.containers.filter {
      $0.labels[ComposeLabelKey.project] == plan.options.projectName
    }
    let observedIDs = Set(plan.observedIdentity.containers.map(\.id))
    let createActions = plan.containerActions.filter { $0.operation == .create }
    let newContainers = projectContainers.filter { !observedIDs.contains($0.id) }

    guard newContainers.count == createActions.count else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Up produced an unexpected number of new project containers."
      )
    }
    for action in createActions {
      let matches = newContainers.filter {
        $0.labels[ComposeLabelKey.service] == action.serviceName
          && Int($0.labels[ComposeLabelKey.containerNumber] ?? "")
            == action.replicaNumber
          && $0.labels[ComposeLabelKey.oneOff]?.lowercased() != "true"
      }
      guard matches.count == 1 else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Up did not create exactly one reviewed \(action.serviceName) replica."
        )
      }
    }

    let imagesByReference = Dictionary(
      inventory.images.map { ($0.reference, $0.digest) },
      uniquingKeysWith: { first, _ in first }
    )
    for service in plan.desiredState.activeServices {
      guard service.replicaCount > 0 else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Service \(service.name) has an invalid reviewed replica count."
        )
      }
      let instances = projectContainers.filter {
        $0.labels[ComposeLabelKey.service] == service.name
          && $0.labels[ComposeLabelKey.oneOff]?.lowercased() != "true"
      }
      let expectedReplicas = Set(1...service.replicaCount)
      guard
        instances.count == service.replicaCount,
        Set(
          instances.compactMap {
            Int($0.labels[ComposeLabelKey.containerNumber] ?? "")
          }) == expectedReplicas,
        instances.allSatisfy({ $0.state == .running }),
        instances.allSatisfy({ $0.imageReference == service.imageReference }),
        instances.allSatisfy({
          $0.imageDigest != nil
            && $0.imageDigest == imagesByReference[service.imageReference]
        }),
        instances.allSatisfy({
          service.configurationHash == nil
            || $0.labels[ComposeLabelKey.configHash] == service.configurationHash
        }),
        instances.allSatisfy({
          attachmentVerifier.hasExactAttachments(
            containerID: $0.id,
            service: service,
            desiredState: plan.desiredState,
            inventory: inventory
          )
        })
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Service \(service.name) did not reach its exact reviewed running replica set."
        )
      }
    }

    try requireActionContainers(
      actions: plan.containerActions.filter { $0.operation == .converge },
      inventory: inventory,
      stateMatches: { $0 == .running }
    )
    try verifyUpVolumeActions(plan: plan, inventory: inventory)
    try verifyUpNetworkActions(plan: plan, inventory: inventory)
  }

  private func verifyUpVolumeActions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    var allowedProjectIDs = Set(
      plan.observedIdentity.volumes.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    for action in plan.volumeActions {
      let matches = inventory.volumes.filter { $0.name == action.runtimeName }
      guard matches.count == 1, let record = matches.first else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Volume \(action.runtimeName) did not reach its reviewed disposition."
        )
      }
      switch action.operation {
      case .createManaged:
        guard
          action.expectedIdentity == nil,
          record.labels[ComposeLabelKey.project] == plan.options.projectName,
          record.labels[ComposeLabelKey.volume] == action.logicalName
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Managed volume \(action.runtimeName) has unexpected ownership."
          )
        }
        allowedProjectIDs.insert(record.id)
      case .reuseManaged, .useExternal:
        guard let expected = action.expectedIdentity, expected.matches(record) else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Volume \(action.runtimeName) changed during Up."
          )
        }
      case .removeManaged:
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    let currentProjectIDs = Set(
      inventory.volumes.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard currentProjectIDs == allowedProjectIDs else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Unexpected project volumes appeared during Up."
      )
    }
  }

  private func verifyUpNetworkActions(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    var allowedProjectIDs = Set(
      plan.observedIdentity.networks.filter {
        $0.configuration.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    for action in plan.networkActions {
      let matches = inventory.networks.filter { $0.name == action.runtimeName }
      guard matches.count == 1, let record = matches.first else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Network \(action.runtimeName) did not reach its reviewed disposition."
        )
      }
      switch action.operation {
      case .createManaged:
        guard
          action.expectedIdentity == nil,
          record.labels[ComposeLabelKey.project] == plan.options.projectName,
          record.labels[ComposeLabelKey.network] == action.logicalName
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Managed network \(action.runtimeName) has unexpected ownership."
          )
        }
        allowedProjectIDs.insert(record.id)
      case .reuseManaged, .useExternal:
        guard let expected = action.expectedIdentity, expected.matches(record) else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Network \(action.runtimeName) changed during Up."
          )
        }
      case .removeManaged:
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    let currentProjectIDs = Set(
      inventory.networks.filter {
        $0.labels[ComposeLabelKey.project] == plan.options.projectName
      }.map(\.id)
    )
    guard currentProjectIDs == allowedProjectIDs else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Unexpected project networks appeared during Up."
      )
    }
  }

  private func requireActionContainers(
    actions: [ComposeProjectContainerAction],
    inventory: ContainerInventory,
    stateMatches: (RuntimeState) -> Bool
  ) throws {
    let recordsByID = Dictionary(
      uniqueKeysWithValues: inventory.containers.map { ($0.id, $0) }
    )
    for action in actions {
      guard let identity = action.expectedIdentity else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "A reviewed container action lost its exact identity."
        )
      }
      guard
        let record = recordsByID[identity.id],
        identity.matches(record),
        stateMatches(record.state)
      else {
        throw ComposeProjectLifecycleError.postconditionNotMet(
          "Container \(identity.id) did not reach the reviewed state."
        )
      }
    }
  }

  private func verifyPreservedIdentities(
    plan: ComposeProjectPlan,
    inventory: ContainerInventory
  ) throws {
    for resource in plan.preservedResources {
      switch resource {
      case .container(let identity):
        guard
          let record = inventory.containers.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved container \(identity.id) changed during the operation."
          )
        }
      case .volume(let identity):
        guard
          let record = inventory.volumes.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved volume \(identity.configuration.name) changed during the operation."
          )
        }
      case .network(let identity):
        guard
          let record = inventory.networks.first(where: { $0.id == identity.id }),
          identity.matches(record)
        else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved network \(identity.configuration.name) changed during the operation."
          )
        }
      case .external(let kind, let name), .absent(let kind, let name):
        let isPresent =
          switch kind {
          case .volume: inventory.volumes.contains { $0.name == name }
          case .network: inventory.networks.contains { $0.name == name }
          }
        guard !isPresent else {
          throw ComposeProjectLifecycleError.postconditionNotMet(
            "Preserved absent \(kind.rawValue) \(name) appeared during the operation."
          )
        }
      }
    }
  }
}
