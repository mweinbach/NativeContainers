import Foundation

struct ContainerTerminalTargetIdentity: Codable, Equatable, Hashable, Sendable {
  let id: String
  let createdAt: Date

  init(container: ContainerRecord) {
    id = container.id
    createdAt = container.createdAt
  }

  func matches(_ container: ContainerRecord) -> Bool {
    id == container.id && createdAt == container.createdAt
  }
}

enum TerminalTargetIdentity: Codable, Equatable, Hashable, Sendable {
  case container(ContainerTerminalTargetIdentity)
  case linuxMachine(LinuxMachineIdentity)

  var id: String {
    switch self {
    case .container(let identity):
      identity.id
    case .linuxMachine(let identity):
      identity.id
    }
  }

  var supportsContainerPresets: Bool {
    if case .container = self {
      return true
    }
    return false
  }
}

struct TerminalWindowRequest: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  let target: TerminalTargetIdentity

  init(id: UUID = UUID(), target: TerminalTargetIdentity) {
    self.id = id
    self.target = target
  }
}

struct TerminalPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
  static let maximumNameLength = 80
  static let maximumPathLength = 4_096

  let id: UUID
  let name: String
  let program: ContainerTerminalProgram
  let launchesAsLoginShell: Bool
  let workingDirectory: String?

  init(
    id: UUID = UUID(),
    name: String,
    program: ContainerTerminalProgram = .preferredShell,
    launchesAsLoginShell: Bool = true,
    workingDirectory: String? = nil
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= Self.maximumNameLength else {
      throw TerminalWorkspaceError.invalidPresetName
    }

    let normalizedProgram: ContainerTerminalProgram
    switch program {
    case .preferredShell:
      normalizedProgram = .preferredShell
    case .executable(let executable):
      let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !executable.isEmpty, executable.count <= Self.maximumPathLength else {
        throw TerminalWorkspaceError.invalidPresetExecutable
      }
      normalizedProgram = .executable(executable)
    }

    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty {
      guard workingDirectory.hasPrefix("/"), workingDirectory.count <= Self.maximumPathLength else {
        throw TerminalWorkspaceError.invalidPresetWorkingDirectory
      }
    }

    self.id = id
    self.name = name
    self.program = normalizedProgram
    self.launchesAsLoginShell = launchesAsLoginShell
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
  }

  func makeRequest(initialSize: ContainerTerminalSize = .standard) throws
    -> ContainerTerminalRequest
  {
    try ContainerTerminalRequest(
      program: program,
      arguments: launchesAsLoginShell ? ["-l"] : [],
      workingDirectory: workingDirectory,
      initialSize: initialSize
    )
  }
}

struct TerminalTabDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  let presetID: UUID?

  init(id: UUID = UUID(), presetID: UUID? = nil) {
    self.id = id
    self.presetID = presetID
  }
}

struct TerminalWorkspaceSnapshot: Codable, Equatable, Sendable {
  static let maximumTabCount = 12

  let workspaceID: UUID
  let tabs: [TerminalTabDescriptor]
  let selectedTabID: UUID?
}

struct TerminalWorkspaceSnapshotCodec: Sendable {
  static let maximumEncodedBytes = 64 * 1_024

  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
  }

  func encode(_ snapshot: TerminalWorkspaceSnapshot) throws -> Data {
    let data = try encoder.encode(snapshot)
    guard data.count <= Self.maximumEncodedBytes else {
      throw TerminalWorkspaceError.invalidRestorationState
    }
    return data
  }

  func decode(_ data: Data, workspaceID: UUID) throws -> TerminalWorkspaceSnapshot {
    guard data.count <= Self.maximumEncodedBytes else {
      throw TerminalWorkspaceError.invalidRestorationState
    }
    let snapshot = try decoder.decode(TerminalWorkspaceSnapshot.self, from: data)
    guard snapshot.workspaceID == workspaceID else {
      throw TerminalWorkspaceError.invalidRestorationState
    }
    return snapshot
  }
}

enum TerminalWorkspaceError: LocalizedError, Equatable, Sendable {
  case invalidPresetName
  case invalidPresetExecutable
  case invalidPresetWorkingDirectory
  case duplicatePresetName(String)
  case presetLimitExceeded
  case invalidRestorationState
  case containerUnavailable(String)
  case containerIdentityChanged(String)
  case linuxMachineUnavailable(String)
  case linuxMachineIdentityChanged(String)
  case terminalServiceUnavailable
  case persistenceFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPresetName:
      "Preset names must contain between 1 and 80 characters."
    case .invalidPresetExecutable:
      "Choose the preferred shell or enter a valid executable."
    case .invalidPresetWorkingDirectory:
      "A preset working directory must be an absolute path inside the container."
    case .duplicatePresetName(let name):
      "A terminal preset named “\(name)” already exists."
    case .presetLimitExceeded:
      "Terminal presets are limited to 64 entries."
    case .invalidRestorationState:
      "The saved terminal workspace could not be restored safely."
    case .containerUnavailable(let id):
      "Container “\(id)” is no longer available."
    case .containerIdentityChanged(let id):
      "Container “\(id)” was replaced after this terminal window was opened."
    case .linuxMachineUnavailable(let id):
      "Linux machine “\(id)” is no longer available."
    case .linuxMachineIdentityChanged(let id):
      "Linux machine “\(id)” was replaced after this terminal window was opened."
    case .terminalServiceUnavailable:
      "The restorable terminal service is unavailable."
    case .persistenceFailed(let message):
      "Terminal presets could not be read or saved: \(message)"
    }
  }
}
