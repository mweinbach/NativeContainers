import Foundation

struct ContainerCommandRequest: Equatable, Sendable {
  let executable: String
  let arguments: [String]
  let environment: [ContainerEnvironmentVariable]
  let workingDirectory: String?
  let timeoutSeconds: Int

  init(
    executable: String,
    arguments: [String] = [],
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    timeoutSeconds: Int = 30
  ) throws {
    let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executable.isEmpty else {
      throw ContainerToolValidationError.missingExecutable
    }
    guard (1...3_600).contains(timeoutSeconds) else {
      throw ContainerToolValidationError.invalidTimeout
    }
    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.hasPrefix("/") {
      throw ContainerToolValidationError.invalidContainerPath(workingDirectory)
    }
    guard Set(environment.map(\.key)).count == environment.count else {
      throw ContainerToolValidationError.duplicateEnvironmentKey
    }

    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    self.timeoutSeconds = timeoutSeconds
  }
}

struct ContainerCommandResult: Equatable, Sendable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String
  let outputWasTruncated: Bool
  let duration: Duration
}

enum ContainerFileTransferDirection: String, CaseIterable, Identifiable, Sendable {
  case intoContainer
  case fromContainer

  var id: Self { self }
}

struct ContainerFileTransferRequest: Equatable, Sendable {
  let direction: ContainerFileTransferDirection
  let localURL: URL
  let containerPath: String

  init(
    direction: ContainerFileTransferDirection,
    localURL: URL,
    containerPath: String
  ) throws {
    let containerPath = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard containerPath.hasPrefix("/"), containerPath != "/" else {
      throw ContainerToolValidationError.invalidContainerPath(containerPath)
    }
    guard localURL.isFileURL else {
      throw ContainerToolValidationError.invalidLocalURL
    }
    self.direction = direction
    self.localURL = localURL.standardizedFileURL
    self.containerPath = containerPath
  }
}

enum ContainerToolValidationError: LocalizedError, Equatable {
  case missingExecutable
  case invalidTimeout
  case invalidContainerPath(String)
  case invalidLocalURL
  case duplicateEnvironmentKey
  case containerNotRunning(String)
  case commandTimedOut(Int)

  var errorDescription: String? {
    switch self {
    case .missingExecutable:
      "Enter a command to run."
    case .invalidTimeout:
      "Timeout must be between 1 second and 1 hour."
    case .invalidContainerPath(let path):
      "“\(path)” must be an absolute path inside the container and cannot be the root directory."
    case .invalidLocalURL:
      "Choose a local file or folder."
    case .duplicateEnvironmentKey:
      "Each environment variable may appear only once."
    case .containerNotRunning(let id):
      "Container “\(id)” must be running."
    case .commandTimedOut(let seconds):
      "The command exceeded its \(seconds)-second timeout and was stopped."
    }
  }
}
