import Foundation

struct LinuxMachineCommandRequest: Equatable, Sendable {
  let command: String
  let environment: [ContainerEnvironmentVariable]
  let workingDirectory: String?
  let timeoutSeconds: Int

  init(
    command: String,
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    timeoutSeconds: Int = 30
  ) throws {
    let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      throw LinuxMachineToolError.missingCommand
    }
    guard (1...3_600).contains(timeoutSeconds) else {
      throw LinuxMachineToolError.invalidTimeout
    }

    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.hasPrefix("/") {
      throw LinuxMachineToolError.invalidWorkingDirectory(workingDirectory)
    }
    guard Set(environment.map(\.key)).count == environment.count else {
      throw LinuxMachineToolError.duplicateEnvironmentKey
    }

    self.command = command
    self.environment = environment
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    self.timeoutSeconds = timeoutSeconds
  }
}

struct LinuxMachineTerminalRequest: Equatable, Sendable {
  let environment: [ContainerEnvironmentVariable]
  let workingDirectory: String?
  let initialSize: ContainerTerminalSize
  let maximumRetainedOutputBytes: Int

  init(
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    initialSize: ContainerTerminalSize = .standard,
    maximumRetainedOutputBytes: Int = 1_024 * 1_024
  ) throws {
    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.hasPrefix("/") {
      throw LinuxMachineToolError.invalidWorkingDirectory(workingDirectory)
    }
    guard Set(environment.map(\.key)).count == environment.count else {
      throw LinuxMachineToolError.duplicateEnvironmentKey
    }
    guard
      (1...ContainerTerminalRequest.maximumRetentionLimit).contains(
        maximumRetainedOutputBytes
      )
    else {
      throw ContainerTerminalError.invalidRetentionLimit
    }

    self.environment = environment
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    self.initialSize = initialSize
    self.maximumRetainedOutputBytes = maximumRetainedOutputBytes
  }

  init(containerRequest: ContainerTerminalRequest) throws {
    try self.init(
      environment: containerRequest.environment,
      workingDirectory: containerRequest.workingDirectory,
      initialSize: containerRequest.initialSize,
      maximumRetainedOutputBytes: containerRequest.maximumRetainedOutputBytes
    )
  }
}

enum LinuxMachineToolError: LocalizedError, Equatable, Sendable {
  case missingCommand
  case invalidTimeout
  case invalidWorkingDirectory(String)
  case duplicateEnvironmentKey
  case unavailable

  var errorDescription: String? {
    switch self {
    case .missingCommand:
      "Enter a shell command to run."
    case .invalidTimeout:
      "Timeout must be between 1 second and 1 hour."
    case .invalidWorkingDirectory(let path):
      "“\(path)” must be an absolute working directory inside the Linux machine."
    case .duplicateEnvironmentKey:
      "Each environment variable may appear only once."
    case .unavailable:
      "Linux machine command and terminal services are unavailable."
    }
  }
}
