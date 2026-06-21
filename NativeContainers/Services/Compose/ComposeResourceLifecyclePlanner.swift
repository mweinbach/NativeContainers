import Foundation

struct ComposeResourceLifecyclePlanner: Sendable {
  func planVolumes(
    _ resources: [ComposeDesiredResource],
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory,
    affectedContainerIDs: Set<String>,
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) -> [VolumeActionDraft] {
    var actions: [VolumeActionDraft] = []
    for resource in resources.sorted(by: ComposeLifecycleOrdering.resource) {
      let matches = inventory.volumes.filter { $0.name == resource.runtimeName }
      guard matches.count <= 1 else {
        issues.append(identityConflict(resource.runtimeName))
        continue
      }
      let match = matches.first
      let identity = match.map(ComposeProjectVolumeIdentity.init)

      if resource.isExternal {
        if options.action == .up, resource.isActive {
          guard let identity else {
            issues.append(missingExternal(resource))
            preservedResources.append(.external(kind: .volume, name: resource.runtimeName))
            continue
          }
          actions.append(
            VolumeActionDraft(
              operation: .useExternal,
              logicalName: resource.logicalName,
              runtimeName: resource.runtimeName,
              expectedIdentity: identity
            )
          )
          preservedResources.append(.volume(identity))
        } else {
          preserveVolume(identity, resource: resource, in: &preservedResources)
        }
        continue
      }

      if let match,
        !hasManagedOwnership(
          labels: match.labels,
          projectName: options.projectName,
          logicalName: resource.logicalName,
          logicalLabelKey: ComposeLabelKey.volume
        )
      {
        issues.append(foreignOwnership(resource.runtimeName))
        preservedResources.append(.volume(ComposeProjectVolumeIdentity(match)))
        continue
      }

      let shouldRemove = options.action == .down && options.removeVolumes
      if options.action == .up, resource.isActive {
        actions.append(
          VolumeActionDraft(
            operation: identity == nil ? .createManaged : .reuseManaged,
            logicalName: resource.logicalName,
            runtimeName: resource.runtimeName,
            expectedIdentity: identity
          )
        )
      } else if shouldRemove, let match, let identity {
        appendCrossConsumerIssue(
          resourceName: resource.runtimeName,
          consumers: match.usedByContainerIDs,
          affectedContainerIDs: affectedContainerIDs,
          issues: &issues
        )
        actions.append(
          VolumeActionDraft(
            operation: .removeManaged,
            logicalName: resource.logicalName,
            runtimeName: resource.runtimeName,
            expectedIdentity: identity
          )
        )
      } else {
        preserveVolume(identity, resource: resource, in: &preservedResources)
      }
    }
    return actions
  }

  func planNetworks(
    _ resources: [ComposeDesiredResource],
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory,
    affectedContainerIDs: Set<String>,
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) -> [NetworkActionDraft] {
    var actions: [NetworkActionDraft] = []
    for resource in resources.sorted(by: ComposeLifecycleOrdering.resource) {
      let matches = inventory.networks.filter { $0.name == resource.runtimeName }
      guard matches.count <= 1 else {
        issues.append(identityConflict(resource.runtimeName))
        continue
      }
      let match = matches.first
      let identity = match.map(ComposeProjectNetworkIdentity.init)

      if resource.isExternal {
        if options.action == .up, resource.isActive {
          guard let identity else {
            issues.append(missingExternal(resource))
            preservedResources.append(.external(kind: .network, name: resource.runtimeName))
            continue
          }
          actions.append(
            NetworkActionDraft(
              operation: .useExternal,
              logicalName: resource.logicalName,
              runtimeName: resource.runtimeName,
              expectedIdentity: identity
            )
          )
          preservedResources.append(.network(identity))
        } else {
          preserveNetwork(identity, resource: resource, in: &preservedResources)
        }
        continue
      }

      if let match,
        !hasManagedOwnership(
          labels: match.labels,
          projectName: options.projectName,
          logicalName: resource.logicalName,
          logicalLabelKey: ComposeLabelKey.network
        )
      {
        issues.append(foreignOwnership(resource.runtimeName))
        preservedResources.append(.network(ComposeProjectNetworkIdentity(match)))
        continue
      }

      if options.action == .up, resource.isActive {
        actions.append(
          NetworkActionDraft(
            operation: identity == nil ? .createManaged : .reuseManaged,
            logicalName: resource.logicalName,
            runtimeName: resource.runtimeName,
            expectedIdentity: identity
          )
        )
      } else if options.action == .down, let match, let identity {
        appendCrossConsumerIssue(
          resourceName: resource.runtimeName,
          consumers: match.usedByContainerIDs,
          affectedContainerIDs: affectedContainerIDs,
          issues: &issues
        )
        actions.append(
          NetworkActionDraft(
            operation: .removeManaged,
            logicalName: resource.logicalName,
            runtimeName: resource.runtimeName,
            expectedIdentity: identity
          )
        )
      } else {
        preserveNetwork(identity, resource: resource, in: &preservedResources)
      }
    }
    return actions
  }

  func preserveUndeclaredProjectResources(
    desired: ComposeDesiredState,
    inventory: ContainerInventory,
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) {
    let volumeNames = Set(desired.volumes.map(\.runtimeName))
    let networkNames = Set(desired.networks.map(\.runtimeName))
    for volume in inventory.volumes
    where volume.labels[ComposeLabelKey.project] == desired.projectName
      && !volumeNames.contains(volume.name)
    {
      preservedResources.append(.volume(ComposeProjectVolumeIdentity(volume)))
      issues.append(
        ComposeLifecycleIssue.warning(
          .observedProjectDrift,
          subject: volume.name,
          message: "An observed project volume is absent from the reviewed full model."
        )
      )
    }
    for network in inventory.networks
    where network.labels[ComposeLabelKey.project] == desired.projectName
      && !networkNames.contains(network.name)
    {
      preservedResources.append(.network(ComposeProjectNetworkIdentity(network)))
      issues.append(
        ComposeLifecycleIssue.warning(
          .observedProjectDrift,
          subject: network.name,
          message: "An observed project network is absent from the reviewed full model."
        )
      )
    }
  }

  func uniquePreservedResources(
    _ resources: [ComposeProjectPreservedResource]
  ) -> [ComposeProjectPreservedResource] {
    var seen: Set<String> = []
    return resources.sorted { composeStringOrder($0.id, $1.id) }.filter {
      seen.insert($0.id).inserted
    }
  }

  private func appendCrossConsumerIssue(
    resourceName: String,
    consumers: [String],
    affectedContainerIDs: Set<String>,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    let foreignConsumers = Set(consumers).subtracting(affectedContainerIDs)
    if !foreignConsumers.isEmpty {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .crossProjectConsumer,
          subject: resourceName,
          message: "A consumer outside the reviewed container actions still uses this resource."
        )
      )
    }
  }

  private func hasManagedOwnership(
    labels: [String: String],
    projectName: String,
    logicalName: String,
    logicalLabelKey: String
  ) -> Bool {
    labels[ComposeLabelKey.project] == projectName
      && labels[logicalLabelKey] == logicalName
  }

  private func preserveVolume(
    _ identity: ComposeProjectVolumeIdentity?,
    resource: ComposeDesiredResource,
    in preservedResources: inout [ComposeProjectPreservedResource]
  ) {
    if let identity {
      preservedResources.append(.volume(identity))
    } else {
      preservedResources.append(.absent(kind: .volume, name: resource.runtimeName))
    }
  }

  private func preserveNetwork(
    _ identity: ComposeProjectNetworkIdentity?,
    resource: ComposeDesiredResource,
    in preservedResources: inout [ComposeProjectPreservedResource]
  ) {
    if let identity {
      preservedResources.append(.network(identity))
    } else {
      preservedResources.append(.absent(kind: .network, name: resource.runtimeName))
    }
  }

  private func identityConflict(_ name: String) -> ComposeProjectReviewIssue {
    ComposeLifecycleIssue.blocker(
      .resourceIdentityConflict,
      subject: name,
      message: "More than one runtime resource has the reviewed name."
    )
  }

  private func foreignOwnership(_ name: String) -> ComposeProjectReviewIssue {
    ComposeLifecycleIssue.blocker(
      .resourceIdentityConflict,
      subject: name,
      message: "An existing resource with this name has foreign ownership evidence."
    )
  }

  private func missingExternal(
    _ resource: ComposeDesiredResource
  ) -> ComposeProjectReviewIssue {
    ComposeLifecycleIssue.blocker(
      .externalResourceMissing,
      subject: resource.runtimeName,
      message: "The active external \(resource.kind.rawValue) does not exist."
    )
  }
}

struct VolumeActionDraft: Sendable {
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectVolumeIdentity?
}

struct NetworkActionDraft: Sendable {
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectNetworkIdentity?
}
