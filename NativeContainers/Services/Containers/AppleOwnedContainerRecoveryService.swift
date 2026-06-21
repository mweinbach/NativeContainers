import ContainerResource
import Foundation

enum AppleContainerOwnership {
  static let creationOperationLabel = "com.nativecontainers.creation-operation"
  static let hostDirectoryAttachmentLabel = "com.nativecontainers.host-directories"
}

protocol OwnedContainerRecovering: Sendable {
  func removeOwnedContainer(id: String, operationID: UUID) async throws
}

struct AppleOwnedContainerRecoveryService: OwnedContainerRecovering {
  private let cleanupClient: any AppleContainerCleanupTransport
  private let ownershipLabel: String

  init(
    cleanupClient: any AppleContainerCleanupTransport = AppleContainerCleanupClient(),
    ownershipLabel: String
  ) {
    self.cleanupClient = cleanupClient
    self.ownershipLabel = ownershipLabel
  }

  func removeOwnedContainer(id: String, operationID: UUID) async throws {
    let cleanupClient = self.cleanupClient
    let ownershipLabel = self.ownershipLabel
    try await Task.detached {
      var lastFailure = "The container remained present after force deletion."

      for attempt in 0..<3 {
        let snapshots: [ContainerSnapshot]
        do {
          snapshots = try await cleanupClient.list(id: id)
        } catch {
          lastFailure = "Ownership verification failed: \(error.localizedDescription)"
          if attempt < 2 {
            try await Task.sleep(for: .milliseconds(250))
          }
          continue
        }

        guard let snapshot = snapshots.first else {
          if attempt < 2 {
            try await Task.sleep(for: .milliseconds(150))
            continue
          }
          return
        }
        guard snapshot.configuration.labels[ownershipLabel] == operationID.uuidString else {
          return
        }

        if snapshot.status == .running {
          do {
            try await cleanupClient.kill(id: id)
          } catch {
            lastFailure = "KILL failed: \(error.localizedDescription)"
          }
        }

        do {
          try await cleanupClient.forceDelete(id: id)
        } catch {
          lastFailure = "Force deletion failed: \(error.localizedDescription)"
        }

        do {
          let remaining = try await cleanupClient.list(id: id)
          guard let current = remaining.first else { return }
          guard current.configuration.labels[ownershipLabel] == operationID.uuidString else {
            return
          }
          lastFailure = "The owned container still exists after force deletion."
        } catch {
          lastFailure = "Post-cleanup verification failed: \(error.localizedDescription)"
        }

        if attempt < 2 {
          try await Task.sleep(for: .milliseconds(250))
        }
      }

      throw OwnedContainerRecoveryError.exhausted(id: id, reason: lastFailure)
    }.value
  }
}

private enum OwnedContainerRecoveryError: LocalizedError {
  case exhausted(id: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .exhausted(let id, let reason):
      "Could not remove owned container “\(id)”. \(reason)"
    }
  }
}
