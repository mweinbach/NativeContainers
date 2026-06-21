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
        if options.action == .down || activeServices.contains(serviceName) {
          affectedContainerIDs.append(container.id)
        } else {
          preservedResourceNames.append(container.id)
        }
      } else {
        orphanContainerIDs.append(container.id)
        if options.removeOrphans {
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

    issues.append(
      blocker(
        .executionPolicy,
        subject: desired.projectName,
        message:
          "Execution remains disabled until exact-ID mutation, source revalidation, and crash-safe operation journaling are available."
      )
    )

    let relevantVolumeNames = Set(desired.volumes.map(\.runtimeName))
    let relevantNetworkNames = Set(desired.networks.map(\.runtimeName))
    let observedIdentity = ComposeProjectInventoryIdentity(
      containers: projectContainers.sorted(by: containerOrder).map(
        ComposeProjectContainerIdentity.init
      ),
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
