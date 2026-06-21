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
    }.sorted(by: containerOrder)
    let observedContainers = projectContainers.map {
      ObservedComposeContainer(record: $0, identity: ComposeProjectContainerIdentity($0))
    }

    let containerDrafts = planContainerActions(
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

    let volumeDrafts = planVolumes(
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

    let networkDrafts = planNetworks(
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

    appendUpModeIssues(
      options: options,
      containerActions: containerActions,
      volumeActions: volumeActions,
      networkActions: networkActions,
      issues: &issues
    )

    preserveUndeclaredProjectResources(
      desired: desired,
      inventory: inventory,
      preservedResources: &preservedResources,
      issues: &issues
    )
    appendExecutionPolicyIssues(
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
      }.sorted(by: volumeOrder).map(ComposeProjectVolumeIdentity.init),
      networks: inventory.networks.filter {
        relevantNetworkNames.contains($0.name)
          || $0.labels[ComposeLabelKey.project] == desired.projectName
      }.sorted(by: networkOrder).map(ComposeProjectNetworkIdentity.init)
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
      issues: issues.sorted(by: issueOrder),
      containerActions: containerActions,
      volumeActions: volumeActions,
      networkActions: networkActions,
      orphanContainers: orphanContainers.sorted(by: identityOrder),
      preservedResources: uniquePreservedResources(preservedResources)
    )
  }

  private func planContainerActions(
    desired: ComposeDesiredState,
    options: ComposeProjectReviewOptions,
    observed: [ObservedComposeContainer],
    inventory: ContainerInventory,
    orphanContainers: inout [ComposeProjectContainerIdentity],
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) -> [ContainerActionDraft] {
    let declaredServices = Set(desired.declaredServiceNames)
    let activeServices = Dictionary(
      uniqueKeysWithValues: desired.activeServices.map { ($0.name, $0) }
    )
    var declaredByService: [String: [ObservedComposeContainer]] = [:]

    for container in observed {
      guard let serviceName = container.record.labels[ComposeLabelKey.service],
        !serviceName.isEmpty
      else {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: container.record.id,
            message: "A project-labeled container has no valid service identity."
          )
        )
        preservedResources.append(.container(container.identity))
        continue
      }

      let oneOff = parseBooleanLabel(container.record.labels[ComposeLabelKey.oneOff])
      guard oneOff != nil else {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: container.record.id,
            message: "A container has an invalid one-off label."
          )
        )
        preservedResources.append(.container(container.identity))
        continue
      }
      if oneOff == true {
        preservedResources.append(.container(container.identity))
        issues.append(
          warning(
            .observedProjectDrift,
            subject: container.record.id,
            message: "One-off containers are preserved by this lifecycle policy."
          )
        )
        continue
      }

      if declaredServices.contains(serviceName) {
        declaredByService[serviceName, default: []].append(container)
      } else {
        orphanContainers.append(container.identity)
        if !(options.action == .down && options.removeOrphans) {
          preservedResources.append(.container(container.identity))
          issues.append(
            warning(
              .observedProjectDrift,
              subject: container.record.id,
              message: "A true orphan is preserved unless Remove Orphans is reviewed."
            )
          )
        }
      }
    }

    var serviceOrder = topologicalServiceOrder(desired)
    if options.action == .stop || options.action == .down {
      serviceOrder.reverse()
    }

    let localDigests = Dictionary(
      inventory.images.map { ($0.reference, $0.digest) },
      uniquingKeysWith: { first, _ in first }
    )
    var drafts: [ContainerActionDraft] = []
    for serviceName in serviceOrder {
      let instances = declaredByService[serviceName, default: []]
      let isActive = activeServices[serviceName] != nil
      let isAffected =
        switch options.action {
        case .up, .start, .stop: isActive
        case .down: true
        }
      guard isAffected else {
        preservedResources.append(contentsOf: instances.map { .container($0.identity) })
        continue
      }

      let replicas = validatedReplicas(
        instances,
        serviceName: serviceName,
        issues: &issues
      )
      let orderedInstances = instances.sorted {
        let lhsReplica = replicas[$0.identity.id] ?? Int.max
        let rhsReplica = replicas[$1.identity.id] ?? Int.max
        if lhsReplica != rhsReplica { return lhsReplica < rhsReplica }
        return composeStringOrder($0.identity.id, $1.identity.id)
      }

      switch options.action {
      case .up:
        guard let service = activeServices[serviceName] else { continue }
        validateConvergenceReplicaSet(
          instances: orderedInstances,
          replicas: replicas,
          service: service,
          issues: &issues
        )
        for instance in orderedInstances {
          validateExistingContainer(
            instance.record,
            service: service,
            localDigest: localDigests[service.imageReference],
            context: "Up",
            requiresNativeStartSafety: false,
            issues: &issues
          )
          guard let replica = replicas[instance.identity.id] else { continue }
          drafts.append(
            ContainerActionDraft(
              operation: .converge,
              serviceName: serviceName,
              replicaNumber: replica,
              expectedIdentity: instance.identity
            )
          )
        }
        let existingReplicas = Set(replicas.values)
        for replica in 1...service.replicaCount where !existingReplicas.contains(replica) {
          drafts.append(
            ContainerActionDraft(
              operation: .create,
              serviceName: serviceName,
              replicaNumber: replica,
              expectedIdentity: nil
            )
          )
        }

      case .start:
        guard let service = activeServices[serviceName] else { continue }
        validateExactReplicaSet(
          instances: orderedInstances,
          replicas: replicas,
          service: service,
          actionName: "Start",
          issues: &issues
        )
        for instance in orderedInstances {
          validateExistingContainer(
            instance.record,
            service: service,
            localDigest: localDigests[service.imageReference],
            context: "Start",
            requiresNativeStartSafety: true,
            issues: &issues
          )
          guard let replica = replicas[instance.identity.id] else { continue }
          drafts.append(
            ContainerActionDraft(
              operation: .start,
              serviceName: serviceName,
              replicaNumber: replica,
              expectedIdentity: instance.identity
            )
          )
        }

      case .stop:
        if let service = activeServices[serviceName] {
          validateReplicaRange(
            replicas,
            service: service,
            actionName: "Stop",
            issues: &issues
          )
        }
        drafts.append(
          contentsOf: orderedInstances.compactMap { instance in
            guard let replica = replicas[instance.identity.id] else { return nil }
            return ContainerActionDraft(
              operation: .stop,
              serviceName: serviceName,
              replicaNumber: replica,
              expectedIdentity: instance.identity
            )
          })

      case .down:
        drafts.append(
          contentsOf: orderedInstances.compactMap { instance in
            guard let replica = replicas[instance.identity.id] else { return nil }
            return ContainerActionDraft(
              operation: .removeDeclared,
              serviceName: serviceName,
              replicaNumber: replica,
              expectedIdentity: instance.identity
            )
          })
      }
    }

    if options.action == .down, options.removeOrphans {
      for identity in orphanContainers.sorted(by: identityOrder) {
        drafts.append(
          ContainerActionDraft(
            operation: .removeOrphan,
            serviceName: identity.labels[ComposeLabelKey.service] ?? "unknown",
            replicaNumber: parsePositiveInteger(
              identity.labels[ComposeLabelKey.containerNumber]
            ),
            expectedIdentity: identity
          )
        )
      }
    }
    return drafts
  }

  private func planVolumes(
    _ resources: [ComposeDesiredResource],
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory,
    affectedContainerIDs: Set<String>,
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) -> [VolumeActionDraft] {
    var actions: [VolumeActionDraft] = []
    for resource in resources.sorted(by: resourceOrder) {
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

  private func planNetworks(
    _ resources: [ComposeDesiredResource],
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory,
    affectedContainerIDs: Set<String>,
    preservedResources: inout [ComposeProjectPreservedResource],
    issues: inout [ComposeProjectReviewIssue]
  ) -> [NetworkActionDraft] {
    var actions: [NetworkActionDraft] = []
    for resource in resources.sorted(by: resourceOrder) {
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

  private func validatedReplicas(
    _ instances: [ObservedComposeContainer],
    serviceName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) -> [String: Int] {
    var result: [String: Int] = [:]
    var ownersByReplica: [Int: [String]] = [:]
    for instance in instances {
      guard
        let replica = parsePositiveInteger(
          instance.record.labels[ComposeLabelKey.containerNumber]
        )
      else {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: instance.record.id,
            message: "An executable declared container needs a positive replica-number label."
          )
        )
        continue
      }
      result[instance.record.id] = replica
      ownersByReplica[replica, default: []].append(instance.record.id)
    }
    for (replica, owners) in ownersByReplica where owners.count > 1 {
      issues.append(
        blocker(
          .observedProjectDrift,
          subject: serviceName,
          message: "Replica \(replica) is claimed by more than one reviewed container."
        )
      )
    }
    return result
  }

  private func validateConvergenceReplicaSet(
    instances: [ObservedComposeContainer],
    replicas: [String: Int],
    service: ComposeDesiredService,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    if instances.count > service.replicaCount {
      issues.append(
        blocker(
          .executionPolicy,
          subject: service.name,
          message: "Up will not remove extra replicas; review Down before converging this service."
        )
      )
    }
    validateReplicaRange(
      replicas,
      service: service,
      actionName: "Up",
      issues: &issues
    )
  }

  private func validateExactReplicaSet(
    instances: [ObservedComposeContainer],
    replicas: [String: Int],
    service: ComposeDesiredService,
    actionName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    let expected = Set(1...service.replicaCount)
    if instances.count != service.replicaCount || Set(replicas.values) != expected {
      issues.append(
        blocker(
          .executionPolicy,
          subject: service.name,
          message:
            "\(actionName) requires the exact reviewed replica set 1...\(service.replicaCount)."
        )
      )
    }
  }

  private func validateReplicaRange(
    _ replicas: [String: Int],
    service: ComposeDesiredService,
    actionName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    if replicas.values.contains(where: { $0 > service.replicaCount }) {
      issues.append(
        blocker(
          .executionPolicy,
          subject: service.name,
          message:
            "\(actionName) found a replica number above the reviewed count of \(service.replicaCount)."
        )
      )
    }
  }

  private func validateExistingContainer(
    _ container: ContainerRecord,
    service: ComposeDesiredService,
    localDigest: String?,
    context: String,
    requiresNativeStartSafety: Bool,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    if container.imageReference != service.imageReference {
      issues.append(
        blocker(
          .executionPolicy,
          subject: container.id,
          message: "The existing container image does not match the reviewed service image."
        )
      )
    }
    guard let imageDigest = container.imageDigest, localDigest == imageDigest else {
      issues.append(
        blocker(
          .executionPolicy,
          subject: container.id,
          message:
            "\(context) requires the existing container and local image reference to share an exact digest."
        )
      )
      return
    }
    if let expectedHash = service.configurationHash,
      container.labels[ComposeLabelKey.configHash] != expectedHash
    {
      issues.append(
        blocker(
          .executionPolicy,
          subject: container.id,
          message: "The existing container does not match the reviewed service configuration hash."
        )
      )
    }
    if requiresNativeStartSafety, !container.ports.isEmpty {
      issues.append(
        blocker(
          .executionPolicy,
          subject: container.id,
          message:
            "Native exact-ID Start is not enabled for containers with published ports until their socket workspace has verifiable ownership."
        )
      )
    }
  }

  private func appendExecutionPolicyIssues(
    options: ComposeProjectReviewOptions,
    desired: ComposeDesiredState,
    inventory: ContainerInventory,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    if options.action != .down, options.removeVolumes {
      issues.append(
        blocker(
          .executionPolicy,
          subject: desired.projectName,
          message: "Managed volume removal is only available for Down."
        )
      )
    }
    if options.action != .down, options.removeOrphans {
      issues.append(
        blocker(
          .executionPolicy,
          subject: desired.projectName,
          message: "Orphan removal is only available for Down."
        )
      )
    }
    guard options.action == .up else { return }
    if desired.activeServices.isEmpty {
      issues.append(
        blocker(
          .executionPolicy,
          subject: desired.projectName,
          message: "Up requires at least one active service."
        )
      )
    }
    if options.pullPolicy == .never {
      let localReferences = Set(inventory.images.map(\.reference))
      for service in desired.activeServices
      where !localReferences.contains(service.imageReference) {
        issues.append(
          blocker(
            .executionPolicy,
            subject: service.name,
            message:
              "Pull policy Never requires the reviewed image reference to exist in the local Apple image store."
          )
        )
      }
    }
  }

  private func appendUpModeIssues(
    options: ComposeProjectReviewOptions,
    containerActions: [ComposeProjectContainerAction],
    volumeActions: [ComposeProjectVolumeAction],
    networkActions: [ComposeProjectNetworkAction],
    issues: inout [ComposeProjectReviewIssue]
  ) {
    guard options.action == .up else { return }
    let hasExistingContainers = containerActions.contains {
      $0.operation == .converge
    }
    let createsContainers = containerActions.contains { $0.operation == .create }
    let reusesManagedResources =
      volumeActions.contains {
        $0.operation == .reuseManaged
      }
      || networkActions.contains {
        $0.operation == .reuseManaged
      }
    let createsManagedResources =
      volumeActions.contains {
        $0.operation == .createManaged
      }
      || networkActions.contains {
        $0.operation == .createManaged
      }

    if hasExistingContainers, createsContainers {
      issues.append(
        blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Create-missing Up remains disabled because the pinned compatibility bridge cannot safely rename a replacement after partial reconciliation."
        )
      )
    }
    if hasExistingContainers, createsManagedResources {
      issues.append(
        blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Native existing-project Up requires every active managed network and volume to already exist with its reviewed identity."
        )
      )
    }
    if !hasExistingContainers, reusesManagedResources {
      issues.append(
        blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Command-based fresh Up will not reconcile a pre-existing managed network or volume without a frozen desired configuration identity."
        )
      )
    }
  }

  private func preserveUndeclaredProjectResources(
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
        warning(
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
        warning(
          .observedProjectDrift,
          subject: network.name,
          message: "An observed project network is absent from the reviewed full model."
        )
      )
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
        blocker(
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

  private func uniquePreservedResources(
    _ resources: [ComposeProjectPreservedResource]
  ) -> [ComposeProjectPreservedResource] {
    var seen: Set<String> = []
    return resources.sorted { composeStringOrder($0.id, $1.id) }.filter {
      seen.insert($0.id).inserted
    }
  }

  private func identityConflict(_ name: String) -> ComposeProjectReviewIssue {
    blocker(
      .resourceIdentityConflict,
      subject: name,
      message: "More than one runtime resource has the reviewed name."
    )
  }

  private func foreignOwnership(_ name: String) -> ComposeProjectReviewIssue {
    blocker(
      .resourceIdentityConflict,
      subject: name,
      message: "An existing resource with this name has foreign ownership evidence."
    )
  }

  private func missingExternal(
    _ resource: ComposeDesiredResource
  ) -> ComposeProjectReviewIssue {
    blocker(
      .externalResourceMissing,
      subject: resource.runtimeName,
      message: "The active external \(resource.kind.rawValue) does not exist."
    )
  }

  private func parseBooleanLabel(_ value: String?) -> Bool? {
    guard let value else { return false }
    switch value.lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  private func parsePositiveInteger(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), parsed > 0 else { return nil }
    return parsed
  }

  private func topologicalServiceOrder(_ desired: ComposeDesiredState) -> [String] {
    var visited: Set<String> = []
    var order: [String] = []

    func visit(_ service: String) {
      guard visited.insert(service).inserted else { return }
      for dependency in desired.serviceDependencies[service, default: []].sorted(
        by: composeStringOrder
      ) {
        visit(dependency)
      }
      order.append(service)
    }

    for service in desired.declaredServiceNames.sorted(by: composeStringOrder) {
      visit(service)
    }
    return order
  }

  private func blocker(
    _ code: ComposeProjectReviewIssueCode,
    subject: String,
    message: String
  ) -> ComposeProjectReviewIssue {
    ComposeProjectReviewIssue(
      severity: .blocker,
      code: code,
      subject: subject,
      message: message
    )
  }

  private func warning(
    _ code: ComposeProjectReviewIssueCode,
    subject: String,
    message: String
  ) -> ComposeProjectReviewIssue {
    ComposeProjectReviewIssue(
      severity: .warning,
      code: code,
      subject: subject,
      message: message
    )
  }

  private func issueOrder(
    _ lhs: ComposeProjectReviewIssue,
    _ rhs: ComposeProjectReviewIssue
  ) -> Bool {
    if lhs.severity != rhs.severity {
      return lhs.severity.rawValue > rhs.severity.rawValue
    }
    if lhs.subject != rhs.subject {
      return composeStringOrder(lhs.subject, rhs.subject)
    }
    return composeStringOrder(lhs.message, rhs.message)
  }

  private func containerOrder(_ lhs: ContainerRecord, _ rhs: ContainerRecord) -> Bool {
    composeStringOrder(lhs.id, rhs.id)
  }

  private func volumeOrder(_ lhs: VolumeRecord, _ rhs: VolumeRecord) -> Bool {
    composeStringOrder(lhs.name, rhs.name)
  }

  private func networkOrder(_ lhs: NetworkRecord, _ rhs: NetworkRecord) -> Bool {
    composeStringOrder(lhs.name, rhs.name)
  }

  private func identityOrder(
    _ lhs: ComposeProjectContainerIdentity,
    _ rhs: ComposeProjectContainerIdentity
  ) -> Bool {
    composeStringOrder(lhs.id, rhs.id)
  }

  private func resourceOrder(
    _ lhs: ComposeDesiredResource,
    _ rhs: ComposeDesiredResource
  ) -> Bool {
    if lhs.logicalName != rhs.logicalName {
      return composeStringOrder(lhs.logicalName, rhs.logicalName)
    }
    return composeStringOrder(lhs.runtimeName, rhs.runtimeName)
  }
}

private struct ObservedComposeContainer {
  let record: ContainerRecord
  let identity: ComposeProjectContainerIdentity
}

private struct ContainerActionDraft {
  let operation: ComposeProjectContainerOperation
  let serviceName: String
  let replicaNumber: Int?
  let expectedIdentity: ComposeProjectContainerIdentity?
}

private struct VolumeActionDraft {
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectVolumeIdentity?
}

private struct NetworkActionDraft {
  let operation: ComposeProjectResourceOperation
  let logicalName: String
  let runtimeName: String
  let expectedIdentity: ComposeProjectNetworkIdentity?
}
