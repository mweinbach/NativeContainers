import Foundation

enum LinuxMachineHomeMount: String, CaseIterable, Codable, Identifiable, Sendable {
  case none
  case readOnly = "ro"
  case readWrite = "rw"

  var id: Self { self }

  var title: String {
    switch self {
    case .none:
      "None"
    case .readOnly:
      "Read only"
    case .readWrite:
      "Read and write"
    }
  }
}

struct LinuxMachineCreationRequest: Equatable, Sendable {
  static let bytesPerMiB: UInt64 = 1_048_576
  static let minimumMemoryBytes: UInt64 = 1_024 * bytesPerMiB
  static let maximumNameLength = 57

  let name: String
  let imageReference: String
  let architecture: ContainerArchitecture
  let cpuCount: Int
  let memoryBytes: UInt64
  let homeMount: LinuxMachineHomeMount
  let allowsWritableHomeMount: Bool
  let startAfterCreation: Bool

  init(
    name: String,
    imageReference: String,
    architecture: ContainerArchitecture = .arm64,
    cpuCount: Int = 4,
    memoryBytes: UInt64 = minimumMemoryBytes,
    homeMount: LinuxMachineHomeMount = .none,
    allowsWritableHomeMount: Bool = false,
    startAfterCreation: Bool = true
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.count <= Self.maximumNameLength else {
      throw LinuxMachineValidationError.nameTooLong
    }
    guard
      name.range(
        of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#,
        options: .regularExpression
      ) != nil
    else {
      throw LinuxMachineValidationError.invalidName
    }

    let imageReference = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !imageReference.isEmpty else {
      throw LinuxMachineValidationError.missingImageReference
    }
    guard (1...256).contains(cpuCount) else {
      throw LinuxMachineValidationError.invalidCPUCount
    }
    guard
      memoryBytes >= Self.minimumMemoryBytes,
      memoryBytes.isMultiple(of: Self.bytesPerMiB)
    else {
      throw LinuxMachineValidationError.invalidMemory
    }
    guard homeMount != .readWrite || allowsWritableHomeMount else {
      throw LinuxMachineValidationError.writableHomeMountRequiresAuthorization
    }

    self.name = name
    self.imageReference = imageReference
    self.architecture = architecture
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.homeMount = homeMount
    self.allowsWritableHomeMount = allowsWritableHomeMount
    self.startAfterCreation = startAfterCreation
  }
}

enum LinuxMachineValidationError: LocalizedError, Equatable {
  case invalidName
  case nameTooLong
  case missingImageReference
  case invalidCPUCount
  case invalidMemory
  case writableHomeMountRequiresAuthorization

  var errorDescription: String? {
    switch self {
    case .invalidName:
      "Use lowercase letters, numbers, and interior hyphens for the machine name."
    case .nameTooLong:
      "Machine names can be at most \(LinuxMachineCreationRequest.maximumNameLength) characters."
    case .missingImageReference:
      "Enter an OCI image reference."
    case .invalidCPUCount:
      "CPU count must be between 1 and 256."
    case .invalidMemory:
      "Memory must be at least 1 GiB and use whole MiB increments."
    case .writableHomeMountRequiresAuthorization:
      "Confirm writable access before mounting your home directory read and write."
    }
  }
}

struct LinuxMachineIdentity: Codable, Equatable, Hashable, Sendable {
  let id: String
  let imageReference: String
  let platform: String
  let createdAt: Date?

  init(
    id: String,
    imageReference: String,
    platform: String,
    createdAt: Date?
  ) {
    self.id = id
    self.imageReference = imageReference
    self.platform = platform
    self.createdAt = createdAt
  }

  init(machine: LinuxMachineRecord) {
    self.init(
      id: machine.id,
      imageReference: machine.imageReference,
      platform: machine.platform,
      createdAt: machine.createdAt
    )
  }

  var hasStableCreationIdentity: Bool {
    createdAt != nil
  }
}

struct LinuxMachineCreationResult: Equatable, Sendable {
  let identity: LinuxMachineIdentity
  let state: RuntimeState
  let isInitialized: Bool
}

struct LinuxMachineForceStopAuthorization: Equatable, Sendable {
  let target: LinuxMachineIdentity
  let allowsKill: Bool

  static func confirmed(for target: LinuxMachineIdentity) -> Self {
    Self(target: target, allowsKill: true)
  }
}

enum LinuxMachineRecoveryOutcome: Equatable, Sendable {
  case alreadyStopped
  case gracefullyStopped
  case forceStopped
  case missing
  case failed(String)

  var retainsMachine: Bool {
    switch self {
    case .alreadyStopped, .gracefullyStopped, .forceStopped:
      true
    case .missing, .failed:
      false
    }
  }
}

struct LinuxMachinePartialCompletionError: LocalizedError, Sendable {
  let result: LinuxMachineCreationResult
  let operationMessage: String
  let recovery: LinuxMachineRecoveryOutcome

  var errorDescription: String? {
    var message =
      "Machine “\(result.identity.id)” was created, but it did not become ready: \(operationMessage)"
    switch recovery {
    case .alreadyStopped:
      message += " The machine remains stopped for inspection."
    case .gracefullyStopped:
      message += " The machine was automatically stopped and kept for inspection."
    case .forceStopped:
      message += " Graceful stop did not complete, so the verified backing container was KILLed."
    case .missing:
      message += " The machine was no longer present during recovery."
    case .failed(let recoveryMessage):
      message += " Automatic stop and KILL recovery also failed: \(recoveryMessage)"
    }
    return message
  }
}

enum LinuxMachineManagementError: LocalizedError, Equatable {
  case alreadyExists(String)
  case creationOutcomeUnknown(String)
  case missing(String)
  case staleTarget(String)
  case stableIdentityRequired(String)
  case notRunning(String)
  case backingContainerMissing(String)
  case forceStopNotAuthorized(String)
  case stopBeforeDeleting(String)
  case initializationFailed(id: String, exitCode: Int32)
  case initializationNotConfirmed(String)
  case stopNotConfirmed(String)
  case forceStopNotConfirmed(String)
  case deletionNotConfirmed(String)
  case startRecoveryFailed(id: String, operation: String, recovery: String)

  var errorDescription: String? {
    switch self {
    case .alreadyExists(let id):
      "A Linux machine named “\(id)” already exists."
    case .creationOutcomeUnknown(let id):
      "Creation of Linux machine “\(id)” may have completed, but the runtime did not confirm ownership. Refresh before taking action."
    case .missing(let id):
      "Linux machine “\(id)” no longer exists."
    case .staleTarget(let id):
      "Linux machine “\(id)” changed after it was displayed. Refresh and review it again."
    case .stableIdentityRequired(let id):
      "Linux machine “\(id)” has no creation timestamp, so this destructive operation was refused."
    case .notRunning(let id):
      "Linux machine “\(id)” is not running."
    case .backingContainerMissing(let id):
      "Linux machine “\(id)” has no verified backing container to force-stop."
    case .forceStopNotAuthorized(let id):
      "KILL was not explicitly authorized for Linux machine “\(id)”."
    case .stopBeforeDeleting(let id):
      "Stop Linux machine “\(id)” before deleting it."
    case .initializationFailed(let id, let exitCode):
      "First-boot setup for Linux machine “\(id)” exited with status \(exitCode)."
    case .initializationNotConfirmed(let id):
      "Linux machine “\(id)” did not confirm first-boot setup."
    case .stopNotConfirmed(let id):
      "Linux machine “\(id)” did not confirm a graceful stop. Use Force Stop if it remains running."
    case .forceStopNotConfirmed(let id):
      "Linux machine “\(id)” did not confirm exit after KILL."
    case .deletionNotConfirmed(let id):
      "Linux machine “\(id)” did not confirm deletion."
    case .startRecoveryFailed(let id, let operation, let recovery):
      "Starting Linux machine “\(id)” failed: \(operation) Automatic stop and KILL recovery also failed: \(recovery)"
    }
  }
}
