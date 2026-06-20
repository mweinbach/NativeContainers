import Foundation

enum VirtualMachineGuest: String, Codable, CaseIterable, Sendable {
  case macOS
  case linux
}

enum VirtualMachineInstallState: String, Codable, CaseIterable, Sendable {
  case draft
  case readyToInstall
  case installing
  case stopped
  case failed
}

struct VirtualMachineResources: Codable, Equatable, Sendable {
  static let bytesPerGiB: UInt64 = 1_073_741_824

  let cpuCount: Int
  let memoryBytes: UInt64
  let diskBytes: UInt64

  init(cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64) throws {
    guard cpuCount > 0 else {
      throw VirtualMachineModelError.invalidCPUCount
    }
    guard memoryBytes >= Self.bytesPerGiB else {
      throw VirtualMachineModelError.insufficientMemory
    }
    guard diskBytes >= 8 * Self.bytesPerGiB else {
      throw VirtualMachineModelError.insufficientDisk
    }

    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
  }
}

struct VirtualMachineManifest: Codable, Equatable, Sendable, Identifiable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  var name: String
  let guest: VirtualMachineGuest
  var installState: VirtualMachineInstallState
  let resources: VirtualMachineResources
  let createdAt: Date
  var updatedAt: Date
  let diskImagePath: String
  var auxiliaryStoragePath: String?
  var hardwareModelPath: String?
  var machineIdentifierPath: String?
  var restoreImageURL: URL?

  init(
    id: UUID = UUID(),
    name: String,
    guest: VirtualMachineGuest,
    installState: VirtualMachineInstallState = .draft,
    resources: VirtualMachineResources,
    createdAt: Date = Date(),
    diskImagePath: String = "Disk.img"
  ) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw VirtualMachineModelError.emptyName
    }

    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.name = trimmedName
    self.guest = guest
    self.installState = installState
    self.resources = resources
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.diskImagePath = diskImagePath
  }

  mutating func markReadyToInstallMacOS(
    restoreImageURL: URL,
    auxiliaryStoragePath: String,
    hardwareModelPath: String,
    machineIdentifierPath: String,
    updatedAt: Date = Date()
  ) {
    installState = .readyToInstall
    self.restoreImageURL = restoreImageURL
    self.auxiliaryStoragePath = auxiliaryStoragePath
    self.hardwareModelPath = hardwareModelPath
    self.machineIdentifierPath = machineIdentifierPath
    self.updatedAt = updatedAt
  }
}

struct MacRestoreImageInfo: Codable, Equatable, Sendable {
  let url: URL
  let buildVersion: String
  let majorVersion: Int
  let minorVersion: Int
  let patchVersion: Int
  let minimumCPUCount: Int
  let minimumMemoryBytes: UInt64
  let isSupported: Bool
}

enum VirtualMachineModelError: LocalizedError, Equatable {
  case emptyName
  case invalidCPUCount
  case insufficientMemory
  case insufficientDisk
  case unsupportedSchema(Int)
  case duplicateIdentifier(UUID)
  case virtualMachineNotFound(UUID)
  case requiresMacOSGuest(UUID)
  case invalidInstallState(VirtualMachineInstallState)
  case platformArtifactsAlreadyExist(UUID)
  case macPlatformPreparationUnavailable

  var errorDescription: String? {
    switch self {
    case .emptyName:
      "Virtual machine names cannot be empty."
    case .invalidCPUCount:
      "A virtual machine needs at least one CPU."
    case .insufficientMemory:
      "A virtual machine needs at least 1 GiB of memory."
    case .insufficientDisk:
      "A virtual machine disk needs at least 8 GiB."
    case .unsupportedSchema(let version):
      "This virtual machine uses unsupported manifest version \(version)."
    case .duplicateIdentifier(let identifier):
      "A virtual machine with identifier \(identifier.uuidString) already exists."
    case .virtualMachineNotFound(let identifier):
      "No virtual machine with identifier \(identifier.uuidString) exists."
    case .requiresMacOSGuest(let identifier):
      "Virtual machine \(identifier.uuidString) is not configured for macOS."
    case .invalidInstallState(let state):
      "A virtual machine in the \(state.rawValue) state cannot prepare macOS platform artifacts."
    case .platformArtifactsAlreadyExist(let identifier):
      "macOS platform artifacts already exist for virtual machine \(identifier.uuidString)."
    case .macPlatformPreparationUnavailable:
      "macOS platform preparation is unavailable for this virtual machine library."
    }
  }
}
