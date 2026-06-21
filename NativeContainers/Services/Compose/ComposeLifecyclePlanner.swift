import Foundation

protocol ComposeLifecyclePlanning: Sendable {
  func plan(
    source: ComposeProjectSourceSummary,
    rendered: ComposeRenderedConfiguration,
    review: ComposeDesiredStateReview,
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory
  ) -> ComposeProjectPlan
}

struct ComposeLifecyclePlanner: ComposeLifecyclePlanning {
  private let containerPlanner = ComposeContainerLifecyclePlanner()
  private let resourcePlanner = ComposeResourceLifecyclePlanner()
  private let policyValidator = ComposeLifecyclePolicyValidator()

  func plan(
    source: ComposeProjectSourceSummary,
    rendered: ComposeRenderedConfiguration,
    review: ComposeDesiredStateReview,
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory
  ) -> ComposeProjectPlan {
    let desired = review.desiredState
    var issues = review.issues
    var preservedResources: [ComposeProjectPreservedResource] = []
    var orphanContainers: [ComposeProjectContainerIdentity] = []

    let projectContainers = inventory.containers.filter {
      $0.labels[ComposeLabelKey.project] == desired.projectName
    }.sorted(by: ComposeLifecycleOrdering.container)
    let observedContainers = projectContainers.map {
      ObservedComposeContainer(record: $0, identity: ComposeProjectContainerIdentity($0))
    }

    let containerDrafts = containerPlanner.planActions(
      desired: desired,
      options: options,
      observed: observedContainers,
      inventory: inventory,
      orphanContainers: &orphanContainers,
      preservedResources: &preservedResources,
      issues: &issues
    )
    let containerActions = containerDrafts.enumerated().map { offset, draft in
      ComposeProjectContainerAction(
        stepID: .container(offset + 1),
        operation: draft.operation,
        serviceName: draft.serviceName,
        replicaNumber: draft.replicaNumber,
        expectedIdentity: draft.expectedIdentity
      )
    }
    let affectedContainerIDs = Set(containerActions.compactMap(\.existingContainerID))

    let volumeDrafts = resourcePlanner.planVolumes(
      desired.volumes,
      options: options,
      inventory: inventory,
      affectedContainerIDs: affectedContainerIDs,
      preservedResources: &preservedResources,
      issues: &issues
    )
    let volumeActions = volumeDrafts.enumerated().map { offset, draft in
      ComposeProjectVolumeAction(
        stepID: .volume(offset + 1),
        operation: draft.operation,
        logicalName: draft.logicalName,
        runtimeName: draft.runtimeName,
        expectedIdentity: draft.expectedIdentity
      )
    }

    let networkDrafts = resourcePlanner.planNetworks(
      desired.networks,
      options: options,
      inventory: inventory,
      affectedContainerIDs: affectedContainerIDs,
      preservedResources: &preservedResources,
      issues: &issues
    )
    let networkActions = networkDrafts.enumerated().map { offset, draft in
      ComposeProjectNetworkAction(
        stepID: .network(offset + 1),
        operation: draft.operation,
        logicalName: draft.logicalName,
        runtimeName: draft.runtimeName,
        expectedIdentity: draft.expectedIdentity
      )
    }

    resourcePlanner.preserveUndeclaredProjectResources(
      desired: desired,
      inventory: inventory,
      preservedResources: &preservedResources,
      issues: &issues
    )
    policyValidator.appendExecutionPolicyIssues(
      options: options,
      desired: desired,
      inventory: inventory,
      issues: &issues
    )

    let relevantVolumeNames = Set(desired.volumes.map(\.runtimeName))
    let relevantNetworkNames = Set(desired.networks.map(\.runtimeName))
    let observedIdentity = ComposeProjectInventoryIdentity(
      containers: observedContainers.map(\.identity),
      volumes: inventory.volumes.filter {
        relevantVolumeNames.contains($0.name)
          || $0.labels[ComposeLabelKey.project] == desired.projectName
      }.sorted(by: ComposeLifecycleOrdering.volume).map(ComposeProjectVolumeIdentity.init),
      networks: inventory.networks.filter {
        relevantNetworkNames.contains($0.name)
          || $0.labels[ComposeLabelKey.project] == desired.projectName
      }.sorted(by: ComposeLifecycleOrdering.network).map(ComposeProjectNetworkIdentity.init)
    )

    return ComposeProjectPlan(
      id: UUID(),
      generatedAt: Date(),
      options: options,
      source: source,
      desiredState: desired,
      fullConfigurationSHA256: rendered.fullConfigurationSHA256,
      activeConfigurationSHA256: rendered.activeConfigurationSHA256,
      composeReleaseVersion: rendered.composeReleaseVersion,
      composeBinarySHA256: rendered.composeBinarySHA256,
      composeSourceRevision: rendered.composeSourceRevision,
      environmentSHA256: rendered.environmentSHA256,
      serviceConfigurationHashes: rendered.serviceConfigurationHashes,
      observedIdentity: observedIdentity,
      issues: issues.sorted(by: ComposeLifecycleOrdering.issue),
      containerActions: containerActions,
      volumeActions: volumeActions,
      networkActions: networkActions,
      orphanContainers: orphanContainers.sorted(by: ComposeLifecycleOrdering.containerIdentity),
      preservedResources: resourcePlanner.uniquePreservedResources(preservedResources)
    )
  }
}
