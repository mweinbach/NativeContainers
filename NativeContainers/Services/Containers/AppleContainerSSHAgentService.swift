import Darwin
import Foundation

struct AppleContainerSSHAgentService: ContainerSSHAgentForwardingManaging {
  typealias EnvironmentProvider = @Sendable () -> [String: String]
  typealias SocketInspector =
    @Sendable (String) throws -> ContainerSSHAgentSourceIdentity

  private let environmentProvider: EnvironmentProvider
  private let socketInspector: SocketInspector

  init(
    environmentProvider: @escaping EnvironmentProvider = {
      ProcessInfo.processInfo.environment
    },
    socketInspector: @escaping SocketInspector = Self.inspectSocket
  ) {
    self.environmentProvider = environmentProvider
    self.socketInspector = socketInspector
  }

  func availability() -> ContainerSSHAgentAvailability {
    do {
      return .available(try currentConfiguration())
    } catch let error as ContainerSSHAgentError {
      switch error {
      case .unavailable(let reason):
        return .unavailable(reason)
      case .changedAfterReview:
        return .unavailable(.pathUnavailable)
      }
    } catch {
      return .unavailable(.pathUnavailable)
    }
  }

  func environment(
    for reviewedConfiguration: ContainerSSHAgentConfiguration
  ) throws -> [String: String] {
    let current = try currentConfiguration()
    guard current == reviewedConfiguration else {
      throw ContainerSSHAgentError.changedAfterReview
    }
    return ["SSH_AUTH_SOCK": current.socketPath]
  }

  func currentEnvironment() throws -> [String: String] {
    let current = try currentConfiguration()
    return ["SSH_AUTH_SOCK": current.socketPath]
  }

  private func currentConfiguration() throws -> ContainerSSHAgentConfiguration {
    guard
      let rawPath = environmentProvider()["SSH_AUTH_SOCK"],
      !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ContainerSSHAgentError.unavailable(.environmentMissing)
    }

    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw ContainerSSHAgentError.unavailable(.pathInvalid)
    }

    let identity = try socketInspector(path)
    return ContainerSSHAgentConfiguration(
      socketPath: path,
      sourceIdentity: identity
    )
  }

  private static func inspectSocket(
    _ path: String
  ) throws -> ContainerSSHAgentSourceIdentity {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw ContainerSSHAgentError.unavailable(.pathUnavailable)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
      throw ContainerSSHAgentError.unavailable(.notSocket)
    }
    return ContainerSSHAgentSourceIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }
}
