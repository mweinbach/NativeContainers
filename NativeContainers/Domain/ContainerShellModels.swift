import Foundation

struct ContainerShell: Equatable, Sendable {
  let executable: String
  let source: ContainerShellSource
}

enum ContainerShellSource: Equatable, Sendable {
  case environment
  case containerProcess
  case fallback
}

enum ContainerShellDiscoveryError: LocalizedError, Equatable, Sendable {
  case invalidContainerIdentifier
  case containerNotRunning(String)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidContainerIdentifier:
      "Choose a valid container before detecting its shell."
    case .containerNotRunning(let id):
      "Container “\(id)” must be running before detecting its shell."
    case .unavailable(let id):
      "No supported interactive shell was found in container “\(id)”."
    }
  }
}
