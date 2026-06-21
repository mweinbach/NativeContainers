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
    var affectedContainerIDs: [String] = []
    var orphanContainerIDs: [String] = []
    var preservedResourceNames: [String] = []
    let declaredServices = Set(desired.declaredServiceNames)
    let activeServices = Set(desired.activeServiceNames)

    let projectContainers = inventory.containers.filter {
      $0.labels[ComposeLabelKey.project] == desired.projectName
    }
    for container in projectContainers.sorted(by: containerOrder) {
      guard let serviceName = container.labels[ComposeLabelKey.service],
        !serviceName.isEmpty
      else {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: container.id,
            message: "A project-labeled container has no valid service identity."
          )
        )
        continue
      }

      let oneOff = parseBooleanLabel(container.labels[ComposeLabelKey.oneOff])
      if oneOff == nil, container.labels[ComposeLabelKey.oneOff] != nil {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: container.id,
            message: "A container has an invalid one-off label."
          )
        )
        continue
      }
      if oneOff == true {
        preservedResourceNames.append(container.id)
        issues.append(
          warning(
            .observedProjectDrift,
            subject: container.id,
            message: "One-off containers are preserved by this initial lifecycle policy."
          )
        )
        continue
      }

      if let replica = container.labels[ComposeLabelKey.containerNumber],
        Int(replica).map({ $0 > 0 }) != true
      {
        issues.append(
          blocker(
            .observedProjectDrift,
            subject: container.id,
            message: "A container has an invalid replica-number label."
          )
        )
        continue
      }

      if declaredServices.contains(serviceName) {
        let isAffected =
          switch options.action {
          case .up:
            false
          case .start, .stop:
            activeServices.contains(serviceName)
          case .down:
            true
          }
        if isAffected {
          affectedContainerIDs.append(container.id)
        } else {
          preservedResourceNames.append(container.id)
        }
      } else {
        orphanContainerIDs.append(container.id)
        if options.action == .down, options.removeOrphans {
          affectedContainerIDs.append(container.id)
        } else {
          preservedResourceNames.append(container.id)
          issues.append(
            warning(
              .observedProjectDrift,
              subject: container.id,
              message: "A true orphan is preserved unless Remove Orphans is reviewed."
            )
          )
        }
      }
    }

    var affectedVolumeNames: [String] = []
    var affectedNetworkNames: [String] = []
    inspectResources(
      desired.volumes,
      options: options,
      inventory: inventory,
      affectedContainerIDs: Set(affectedContainerIDs),
      affectedNames: &affectedVolumeNames,
      preservedNames: &preservedResourceNames,
      issues: &issues
    )
    inspectResources(
      desired.networks,
      options: options,
      inventory: inventory,
      affectedContainerIDs: Set(affectedContainerIDs),
      affectedNames: &affectedNetworkNames,
      preservedNames: &preservedResourceNames,
      issues: &issues
    )
    inspectUndeclaredProjectResources(
      desired: desired,
      inventory: inventory,
      issues: &issues
    )

    appendExecutionPolicyIssues(
      options: options,
      desired: desired,
      projectContainers: projectContainers,
      inventory: inventory,
      issues: &issues
    )

    let relevantVolumeNames = Set(desired.volumes.map(\.runtimeName))
    let relevantNetworkNames = Set(desired.networks.map(\.runtimeName))
    let imageDigestsByReference = Dictionary(
      inventory.images.map { ($0.reference, $0.digest) },
      uniquingKeysWith: { first, _ in first }
    )
    let observedIdentity = ComposeProjectInventoryIdentity(
      containers: projectContainers.sorted(by: containerOrder).map {
        ComposeProjectContainerIdentity(
          $0,
          imageDigest: imageDigestsByReference[$0.imageReference]
        )
      },
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
      affectedContainerIDs: Array(Set(affectedContainerIDs)).sorted(by: composeStringOrder),
      affectedVolumeNames: Array(Set(affectedVolumeNames)).sorted(by: composeStringOrder),
      affectedNetworkNames: Array(Set(affectedNetworkNames)).sorted(by: composeStringOrder),
      orphanContainerIDs: Array(Set(orphanContainerIDs)).sorted(by: composeStringOrder),
      preservedResourceNames: Array(Set(preservedResourceNames)).sorted(
        by: composeStringOrder
      )
    )
  }

  private func inspectResources(
    _ resources: [ComposeDesiredResource],
    options: ComposeProjectReviewOptions,
    inventory: ContainerInventory,
    affectedContainerIDs: Set<String>,
    affectedNames: inout [String],
    preservedNames: inout [String],
    issues: inout [ComposeProjectReviewIssue]
  ) {
    for resource in resources {
      let matches: [(labels: [String: String], consumers: [String])] =
        switch resource.kind {
        case .volume:
          inventory.volumes.filter { $0.name == resource.runtimeName }.map {
            ($0.labels, $0.usedByContainerIDs)
          }
        case .network:
          inventory.networks.filter { $0.name == resource.runtimeName }.map {
            ($0.labels, $0.usedByContainerIDs)
          }
        }

      if matches.count > 1 {
        issues.append(
          blocker(
            .resourceIdentityConflict,
            subject: resource.runtimeName,
            message: "More than one runtime resource has the reviewed name."
          )
        )
        continue
      }

      if resource.isExternal {
        preservedNames.append(resource.runtimeName)
        if options.action == .up, resource.isActive, matches.isEmpty {
          issues.append(
            blocker(
              .externalResourceMissing,
              subject: resource.runtimeName,
              message: "The active external \(resource.kind.rawValue) does not exist."
            )
          )
        }
        continue
      }

      if let match = matches.first {
        let logicalLabelKey =
          resource.kind == .volume ? ComposeLabelKey.volume : ComposeLabelKey.network
        guard
          match.labels[ComposeLabelKey.project] == options.projectName,
          match.labels[logicalLabelKey] == resource.logicalName
        else {
          issues.append(
            blocker(
              .resourceIdentityConflict,
              subject: resource.runtimeName,
              message: "An existing resource with this name has foreign ownership evidence."
            )
          )
          continue
        }
      }

      let isAffected: Bool =
        switch options.action {
        case .up:
          resource.isActive
        case .start, .stop:
          false
        case .down:
          resource.kind == .network || options.removeVolumes
        }
      if isAffected {
        affectedNames.append(resource.runtimeName)
      } else {
        preservedNames.append(resource.runtimeName)
      }

      if options.action == .down,
        isAffected,
        let match = matches.first
      {
        let foreignConsumers = Set(match.consumers).subtracting(affectedContainerIDs)
        if !foreignConsumers.isEmpty {
          issues.append(
            blocker(
              .crossProjectConsumer,
              subject: resource.runtimeName,
              message: "A consumer outside the reviewed container set still uses this resource."
            )
          )
        }
      }
    }
  }

  private func appendExecutionPolicyIssues(
    options: ComposeProjectReviewOptions,
    desired: ComposeDesiredState,
    projectContainers: [ContainerRecord],
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
    if options.action == .down, options.removeVolumes {
      issues.append(
        blocker(
          .executionPolicy,
          subject: desired.projectName,
          message:
            "Named-volume deletion remains review-only until every volume action has an independently typed exact-identity contract."
        )
      )
    }
    if options.action == .down, options.removeOrphans {
      issues.append(
        blocker(
          .executionPolicy,
          subject: desired.projectName,
          message:
            "Orphan deletion remains review-only until orphan actions are represented separately from declared services."
        )
      )
    }

    switch options.action {
    case .up:
      guard !desired.activeServices.isEmpty else {
        issues.append(
          blocker(
            .executionPolicy,
            subject: desired.projectName,
            message: "Fresh Up requires at least one active service."
          )
        )
        return
      }
      let hasManagedProjectResources =
        !projectContainers.isEmpty
        || inventory.volumes.contains {
          $0.labels[ComposeLabelKey.project] == desired.projectName
        }
        || inventory.networks.contains {
          $0.labels[ComposeLabelKey.project] == desired.projectName
        }
      if hasManagedProjectResources {
        issues.append(
          blocker(
            .executionPolicy,
            subject: desired.projectName,
            message:
              "Up currently supports fresh projects only; existing project resources require reviewed convergence and recreation support."
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

    case .start:
      let regularContainers = projectContainers.filter {
        parseBooleanLabel($0.labels[ComposeLabelKey.oneOff]) != true
      }
      let localImageReferences = Set(inventory.images.map(\.reference))
      for service in desired.activeServices {
        let instances = regularContainers.filter {
          $0.labels[ComposeLabelKey.service] == service.name
        }
        if instances.count != service.replicaCount {
          issues.append(
            blocker(
              .executionPolicy,
              subject: service.name,
              message:
                "Start requires exactly \(service.replicaCount) reviewed existing replica(s); use fresh Up or a later convergence workflow to create missing replicas."
            )
          )
        }
        for container in instances {
          if container.imageReference != service.imageReference {
            issues.append(
              blocker(
                .executionPolicy,
                subject: container.id,
                message: "The existing container image does not match the reviewed service image."
              )
            )
          }
          if !localImageReferences.contains(container.imageReference) {
            issues.append(
              blocker(
                .executionPolicy,
                subject: container.id,
                message:
                  "Native exact-ID Start requires pinned local image digest evidence for the existing container."
              )
            )
          }
          if !container.ports.isEmpty {
            issues.append(
              blocker(
                .executionPolicy,
                subject: container.id,
                message:
                  "Native exact-ID Start is not enabled for containers with published ports until their socket workspace has verifiable ownership."
              )
            )
          }
          if let expectedHash = service.configurationHash,
            container.labels[ComposeLabelKey.configHash] != expectedHash
          {
            issues.append(
              blocker(
                .executionPolicy,
                subject: container.id,
                message:
                  "The stopped container does not match the reviewed service configuration hash."
              )
            )
          }
        }
      }

    case .stop, .down:
      break
    }
  }

  private func inspectUndeclaredProjectResources(
    desired: ComposeDesiredState,
    inventory: ContainerInventory,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    let volumeNames = Set(desired.volumes.map(\.runtimeName))
    let networkNames = Set(desired.networks.map(\.runtimeName))

    for volume in inventory.volumes
    where volume.labels[ComposeLabelKey.project] == desired.projectName
      && !volumeNames.contains(volume.name)
    {
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
      issues.append(
        warning(
          .observedProjectDrift,
          subject: network.name,
          message: "An observed project network is absent from the reviewed full model."
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
}
