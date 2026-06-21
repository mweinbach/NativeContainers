import Foundation

struct ComposeContainerLifecyclePlanner: Sendable {
  func planActions(
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
          ComposeLifecycleIssue.blocker(
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
          ComposeLifecycleIssue.blocker(
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
          ComposeLifecycleIssue.warning(
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
            ComposeLifecycleIssue.warning(
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
      for identity in orphanContainers.sorted(by: ComposeLifecycleOrdering.containerIdentity) {
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
          ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: container.id,
          message: "The existing container image does not match the reviewed service image."
        )
      )
    }
    guard let imageDigest = container.imageDigest, localDigest == imageDigest else {
      issues.append(
        ComposeLifecycleIssue.blocker(
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
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: container.id,
          message: "The existing container does not match the reviewed service configuration hash."
        )
      )
    }
    if requiresNativeStartSafety, !container.ports.isEmpty {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: container.id,
          message:
            "Native exact-ID Start is not enabled for containers with published ports until their socket workspace has verifiable ownership."
        )
      )
    }
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
}

struct ObservedComposeContainer: Sendable {
  let record: ContainerRecord
  let identity: ComposeProjectContainerIdentity
}

struct ContainerActionDraft: Sendable {
  let operation: ComposeProjectContainerOperation
  let serviceName: String
  let replicaNumber: Int?
  let expectedIdentity: ComposeProjectContainerIdentity?
}
