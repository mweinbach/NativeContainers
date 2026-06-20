import Foundation

struct ContainerTerminalSize: Equatable, Sendable {
  static let standard = ContainerTerminalSize(columns: 120, rows: 40, validated: ())

  let columns: UInt16
  let rows: UInt16

  init(columns: Int, rows: Int) throws {
    guard
      (1...Int(UInt16.max)).contains(columns),
      (1...Int(UInt16.max)).contains(rows)
    else {
      throw ContainerTerminalError.invalidSize(columns: columns, rows: rows)
    }
    self.init(columns: UInt16(columns), rows: UInt16(rows), validated: ())
  }

  private init(columns: UInt16, rows: UInt16, validated: Void) {
    self.columns = columns
    self.rows = rows
  }
}

struct ContainerTerminalRequest: Equatable, Sendable {
  static let maximumRetentionLimit = 16 * 1_024 * 1_024

  let executable: String
  let arguments: [String]
  let environment: [ContainerEnvironmentVariable]
  let workingDirectory: String?
  let initialSize: ContainerTerminalSize
  let maximumRetainedOutputBytes: Int

  init(
    executable: String = "/bin/sh",
    arguments: [String] = [],
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    initialSize: ContainerTerminalSize = .standard,
    maximumRetainedOutputBytes: Int = 1_024 * 1_024
  ) throws {
    let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executable.isEmpty else {
      throw ContainerTerminalError.missingExecutable
    }

    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.hasPrefix("/") {
      throw ContainerTerminalError.invalidWorkingDirectory(workingDirectory)
    }
    guard Set(environment.map(\.key)).count == environment.count else {
      throw ContainerTerminalError.duplicateEnvironmentKey
    }
    guard (1...Self.maximumRetentionLimit).contains(maximumRetainedOutputBytes) else {
      throw ContainerTerminalError.invalidRetentionLimit
    }

    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    self.initialSize = initialSize
    self.maximumRetainedOutputBytes = maximumRetainedOutputBytes
  }
}

enum ContainerTerminalSignal: Int32, CaseIterable, Sendable {
  case hangup = 1
  case interrupt = 2
  case quit = 3
  case kill = 9
  case terminate = 15
}

enum ContainerTerminalLifecycle: Equatable, Sendable {
  case starting
  case running
  case exited(Int32)
  case closed
  case failed(String)
}

struct ContainerTerminalSnapshot: Equatable, Sendable {
  let lifecycle: ContainerTerminalLifecycle
  let retainedOutput: Data
  let outputWasTruncated: Bool

  var retainedText: String {
    String(decoding: retainedOutput, as: UTF8.self)
  }
}

protocol ContainerTerminalSession: Sendable {
  var output: AsyncStream<Data> { get }

  func sendInput(_ data: Data) async throws
  func resize(to size: ContainerTerminalSize) async throws
  func sendSignal(_ signal: ContainerTerminalSignal) async throws
  func snapshot() async -> ContainerTerminalSnapshot
  func wait() async throws -> Int32
  func close() async
}

enum ContainerTerminalError: LocalizedError, Equatable, Sendable {
  case unsupported
  case invalidContainerIdentifier
  case missingExecutable
  case invalidWorkingDirectory(String)
  case duplicateEnvironmentKey
  case invalidSize(columns: Int, rows: Int)
  case invalidRetentionLimit
  case containerNotRunning(String)
  case sessionNotRunning
  case sessionFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "Interactive terminal sessions are unavailable from this container service."
    case .invalidContainerIdentifier:
      "Choose a valid container before opening a terminal."
    case .missingExecutable:
      "Enter a terminal command to run."
    case .invalidWorkingDirectory(let path):
      "“\(path)” must be an absolute working directory inside the container."
    case .duplicateEnvironmentKey:
      "Each terminal environment variable may appear only once."
    case .invalidSize(let columns, let rows):
      "Terminal size \(columns)×\(rows) is invalid."
    case .invalidRetentionLimit:
      "Retained terminal output must be between 1 byte and 16 MiB."
    case .containerNotRunning(let id):
      "Container “\(id)” must be running before opening a terminal."
    case .sessionNotRunning:
      "The terminal session is no longer running."
    case .sessionFailed(let message):
      "The terminal session failed: \(message)"
    }
  }
}
