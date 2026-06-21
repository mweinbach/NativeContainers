import Foundation

struct ContainerSSHAgentSourceIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
}

struct ContainerSSHAgentConfiguration: Equatable, Sendable {
  let socketPath: String
  let sourceIdentity: ContainerSSHAgentSourceIdentity
}

enum ContainerSSHAgentUnavailableReason: Equatable, Sendable {
  case environmentMissing
  case pathInvalid
  case pathUnavailable
  case notSocket
}

enum ContainerSSHAgentAvailability: Equatable, Sendable {
  case available(ContainerSSHAgentConfiguration)
  case unavailable(ContainerSSHAgentUnavailableReason)

  var configuration: ContainerSSHAgentConfiguration? {
    guard case .available(let configuration) = self else { return nil }
    return configuration
  }
}

enum ContainerSSHAgentError: LocalizedError, Equatable, Sendable {
  case unavailable(ContainerSSHAgentUnavailableReason)
  case changedAfterReview

  var errorDescription: String? {
    switch self {
    case .unavailable(.environmentMissing):
      "SSH_AUTH_SOCK is not set. Start an SSH agent before enabling forwarding."
    case .unavailable(.pathInvalid):
      "SSH_AUTH_SOCK must point to an absolute local path."
    case .unavailable(.pathUnavailable):
      "The SSH agent socket is no longer available."
    case .unavailable(.notSocket):
      "SSH_AUTH_SOCK does not point to a Unix-domain socket."
    case .changedAfterReview:
      "The SSH agent socket changed after review. Refresh the form and try again."
    }
  }
}
