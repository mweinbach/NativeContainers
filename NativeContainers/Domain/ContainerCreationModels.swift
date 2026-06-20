import Foundation

enum ContainerArchitecture: String, CaseIterable, Codable, Identifiable, Sendable {
  case arm64
  case amd64

  var id: Self { self }
}

enum ContainerTransportProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
  case tcp
  case udp

  var id: Self { self }
}

struct ContainerEnvironmentVariable: Codable, Equatable, Sendable {
  let key: String
  let value: String

  init(key: String, value: String) throws {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    else {
      throw ContainerCreationValidationError.invalidEnvironmentKey(key)
    }
    self.key = key
    self.value = value
  }

  var entry: String { "\(key)=\(value)" }
}

struct ContainerPortPublication: Codable, Equatable, Hashable, Sendable, Identifiable {
  let hostAddress: String
  let hostPort: UInt16
  let containerPort: UInt16
  let transportProtocol: ContainerTransportProtocol

  init(
    hostAddress: String,
    hostPort: UInt16,
    containerPort: UInt16,
    transportProtocol: ContainerTransportProtocol
  ) throws {
    let hostAddress = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hostAddress.isEmpty else {
      throw ContainerCreationValidationError.missingHostAddress
    }
    self.hostAddress = hostAddress
    self.hostPort = hostPort
    self.containerPort = containerPort
    self.transportProtocol = transportProtocol
  }

  var id: String {
    "\(hostAddress):\(hostPort):\(containerPort)/\(transportProtocol.rawValue)"
  }

  var appleSpecification: String {
    "\(hostAddress):\(hostPort):\(containerPort)/\(transportProtocol.rawValue)"
  }
}

struct ContainerCreationRequest: Equatable, Sendable {
  static let bytesPerMiB: UInt64 = 1_048_576

  let operationID: UUID
  let name: String
  let imageReference: String
  let architecture: ContainerArchitecture
  let cpuCount: Int
  let memoryBytes: UInt64
  let arguments: [String]
  let environment: [ContainerEnvironmentVariable]
  let workingDirectory: String?
  let publishedPorts: [ContainerPortPublication]
  let startAfterCreation: Bool
  let removeWhenStopped: Bool
  let forwardSSHAgent: Bool
  let readOnlyRootFilesystem: Bool
  let useInitProcess: Bool

  init(
    operationID: UUID = UUID(),
    name: String,
    imageReference: String,
    architecture: ContainerArchitecture = .arm64,
    cpuCount: Int = 4,
    memoryBytes: UInt64 = 1_024 * bytesPerMiB,
    arguments: [String] = [],
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    publishedPorts: [ContainerPortPublication] = [],
    startAfterCreation: Bool = true,
    removeWhenStopped: Bool = false,
    forwardSSHAgent: Bool = false,
    readOnlyRootFilesystem: Bool = false,
    useInitProcess: Bool = true
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]+$"#, options: .regularExpression)
        != nil
    else {
      throw ContainerCreationValidationError.invalidName
    }

    let imageReference = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !imageReference.isEmpty else {
      throw ContainerCreationValidationError.missingImageReference
    }
    guard (1...256).contains(cpuCount) else {
      throw ContainerCreationValidationError.invalidCPUCount
    }
    guard
      memoryBytes >= 256 * Self.bytesPerMiB,
      memoryBytes.isMultiple(of: Self.bytesPerMiB)
    else {
      throw ContainerCreationValidationError.invalidMemory
    }

    let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.hasPrefix("/") {
      throw ContainerCreationValidationError.invalidWorkingDirectory
    }

    var environmentKeys: Set<String> = []
    for variable in environment where !environmentKeys.insert(variable.key).inserted {
      throw ContainerCreationValidationError.duplicateEnvironmentKey(variable.key)
    }
    guard Set(publishedPorts.map(\.id)).count == publishedPorts.count else {
      throw ContainerCreationValidationError.duplicatePortPublication
    }

    self.operationID = operationID
    self.name = name
    self.imageReference = imageReference
    self.architecture = architecture
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
    self.publishedPorts = publishedPorts
    self.startAfterCreation = startAfterCreation
    self.removeWhenStopped = removeWhenStopped
    self.forwardSSHAgent = forwardSSHAgent
    self.readOnlyRootFilesystem = readOnlyRootFilesystem
    self.useInitProcess = useInitProcess
  }
}

enum ContainerCreationValidationError: LocalizedError, Equatable {
  case invalidName
  case missingImageReference
  case invalidCPUCount
  case invalidMemory
  case invalidWorkingDirectory
  case malformedEnvironmentLine(Int)
  case invalidEnvironmentKey(String)
  case duplicateEnvironmentKey(String)
  case missingHostAddress
  case invalidPort
  case tooManyPortPublications
  case duplicatePortPublication

  var errorDescription: String? {
    switch self {
    case .invalidName:
      "Use at least two letters, numbers, periods, underscores, or hyphens for the name."
    case .missingImageReference:
      "Enter an OCI image reference."
    case .invalidCPUCount:
      "CPU count must be between 1 and 256."
    case .invalidMemory:
      "Memory must be at least 256 MiB and use whole MiB increments."
    case .invalidWorkingDirectory:
      "The working directory must be an absolute path inside the container."
    case .malformedEnvironmentLine(let line):
      "Environment line \(line) must use KEY=value format."
    case .invalidEnvironmentKey(let key):
      "“\(key)” is not a valid environment variable name."
    case .duplicateEnvironmentKey(let key):
      "Environment variable “\(key)” appears more than once."
    case .missingHostAddress:
      "Enter a host address for every published port."
    case .invalidPort:
      "Ports must be between 1 and 65535."
    case .tooManyPortPublications:
      "Apple’s runtime supports at most 64 published-port entries per container."
    case .duplicatePortPublication:
      "Each published host port and protocol combination must be unique."
    }
  }
}

struct ContainerOperationProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case preparing
    case fetchingImage
    case unpackingImage
    case fetchingKernel
    case fetchingInitImage
    case unpackingInitImage
    case creating
    case starting
    case completed
  }

  let phase: Phase
  let message: String
  let completedItems: Int
  let totalItems: Int
  let transferredBytes: Int64
  let totalBytes: Int64

  init(
    phase: Phase,
    message: String,
    completedItems: Int = 0,
    totalItems: Int = 0,
    transferredBytes: Int64 = 0,
    totalBytes: Int64 = 0
  ) {
    self.phase = phase
    self.message = message
    self.completedItems = completedItems
    self.totalItems = totalItems
    self.transferredBytes = transferredBytes
    self.totalBytes = totalBytes
  }

  var fractionCompleted: Double? {
    if totalBytes > 0 {
      return min(max(Double(transferredBytes) / Double(totalBytes), 0), 1)
    }
    if totalItems > 0 {
      return min(max(Double(completedItems) / Double(totalItems), 0), 1)
    }
    return nil
  }
}

typealias ContainerProgressHandler = @Sendable (ContainerOperationProgress) async -> Void
