import Foundation
import Testing

@testable import NativeContainers

@Suite("Container SSH agent service")
struct ContainerSSHAgentServiceTests {
  @Test
  func returnsOnlyTheReviewedUnixSocket() throws {
    let path = "/private/tmp/agent.sock"
    let identity = ContainerSSHAgentSourceIdentity(device: 7, inode: 11)
    let service = AppleContainerSSHAgentService(
      environmentProvider: { ["SSH_AUTH_SOCK": path] },
      socketInspector: { inspectedPath in
        #expect(inspectedPath == path)
        return identity
      }
    )
    let configuration = try #require(service.availability().configuration)

    #expect(
      configuration
        == ContainerSSHAgentConfiguration(
          socketPath: path,
          sourceIdentity: identity
        )
    )
    #expect(
      try service.environment(for: configuration)
        == ["SSH_AUTH_SOCK": path]
    )
    #expect(try service.currentEnvironment() == ["SSH_AUTH_SOCK": path])
  }

  @Test
  func failsClosedWhenTheSocketChangesAfterReview() throws {
    let reviewed = ContainerSSHAgentConfiguration(
      socketPath: "/private/tmp/agent.sock",
      sourceIdentity: ContainerSSHAgentSourceIdentity(device: 1, inode: 2)
    )
    let service = AppleContainerSSHAgentService(
      environmentProvider: { ["SSH_AUTH_SOCK": reviewed.socketPath] },
      socketInspector: { _ in
        ContainerSSHAgentSourceIdentity(device: 1, inode: 3)
      }
    )

    #expect(throws: ContainerSSHAgentError.changedAfterReview) {
      _ = try service.environment(for: reviewed)
    }
  }

  @Test
  func describesMissingAndInvalidEnvironment() {
    let missing = AppleContainerSSHAgentService(
      environmentProvider: { [:] },
      socketInspector: { _ in
        Issue.record("The inspector should not run without SSH_AUTH_SOCK")
        return ContainerSSHAgentSourceIdentity(device: 0, inode: 0)
      }
    )
    let relative = AppleContainerSSHAgentService(
      environmentProvider: { ["SSH_AUTH_SOCK": "agent.sock"] },
      socketInspector: { _ in
        Issue.record("The inspector should not run for a relative path")
        return ContainerSSHAgentSourceIdentity(device: 0, inode: 0)
      }
    )

    #expect(missing.availability() == .unavailable(.environmentMissing))
    #expect(relative.availability() == .unavailable(.pathInvalid))
  }
}
