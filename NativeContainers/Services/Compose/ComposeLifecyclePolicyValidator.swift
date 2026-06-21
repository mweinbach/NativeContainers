import Foundation

struct ComposeLifecyclePolicyValidator: Sendable {
  func appendExecutionPolicyIssues(
    options: ComposeProjectReviewOptions,
    desired: ComposeDesiredState,
    inventory: ContainerInventory,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    if options.action != .down, options.removeVolumes {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: desired.projectName,
          message: "Managed volume removal is only available for Down."
        )
      )
    }
    if options.action != .down, options.removeOrphans {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: desired.projectName,
          message: "Orphan removal is only available for Down."
        )
      )
    }
    guard options.action == .up else { return }
    if desired.activeServices.isEmpty {
      issues.append(
        ComposeLifecycleIssue.blocker(
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
          ComposeLifecycleIssue.blocker(
            .executionPolicy,
            subject: service.name,
            message:
              "Pull policy Never requires the reviewed image reference to exist in the local Apple image store."
          )
        )
      }
    }
  }

  func appendUpModeIssues(
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
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Create-missing Up remains disabled because the pinned compatibility bridge cannot safely rename a replacement after partial reconciliation."
        )
      )
    }
    if hasExistingContainers, createsManagedResources {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Native existing-project Up requires every active managed network and volume to already exist with its reviewed identity."
        )
      )
    }
    if !hasExistingContainers, reusesManagedResources {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: options.projectName,
          message:
            "Command-based fresh Up will not reconcile a pre-existing managed network or volume without a frozen desired configuration identity."
        )
      )
    }
  }
}

enum ComposeLifecycleIssue {
  static func blocker(
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

  static func warning(
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
}

enum ComposeLifecycleOrdering {
  static func issue(
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

  static func container(_ lhs: ContainerRecord, _ rhs: ContainerRecord) -> Bool {
    composeStringOrder(lhs.id, rhs.id)
  }

  static func volume(_ lhs: VolumeRecord, _ rhs: VolumeRecord) -> Bool {
    composeStringOrder(lhs.name, rhs.name)
  }

  static func network(_ lhs: NetworkRecord, _ rhs: NetworkRecord) -> Bool {
    composeStringOrder(lhs.name, rhs.name)
  }

  static func containerIdentity(
    _ lhs: ComposeProjectContainerIdentity,
    _ rhs: ComposeProjectContainerIdentity
  ) -> Bool {
    composeStringOrder(lhs.id, rhs.id)
  }

  static func resource(
    _ lhs: ComposeDesiredResource,
    _ rhs: ComposeDesiredResource
  ) -> Bool {
    if lhs.logicalName != rhs.logicalName {
      return composeStringOrder(lhs.logicalName, rhs.logicalName)
    }
    return composeStringOrder(lhs.runtimeName, rhs.runtimeName)
  }
}
