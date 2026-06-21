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
    for service in desired.activeServices where service.replicaCount == 0 {
      issues.append(
        ComposeLifecycleIssue.blocker(
          .executionPolicy,
          subject: service.name,
          message: "Up does not execute zero-replica services."
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
