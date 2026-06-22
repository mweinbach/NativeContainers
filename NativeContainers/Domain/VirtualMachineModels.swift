import Foundation

enum VirtualMachineGuest: String, Codable, CaseIterable, Hashable, Sendable {
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
  var resources: VirtualMachineResources
  let createdAt: Date
  var updatedAt: Date
  var diskImagePath: String
  var diskImageFormat: VirtualMachineDiskImageFormat? = nil
  var auxiliaryStoragePath: String?
  var hardwareModelPath: String?
  var machineIdentifierPath: String?
  var restoreImageURL: URL?
  var installationOperationID: UUID? = nil
  var installationFailure: VirtualMachineInstallationFailure? = nil
  var audioConfiguration: MacVirtualMachineAudioConfiguration? = nil
  var networkConfiguration: VirtualMachineNetworkConfiguration? = nil
  var linuxConfiguration: LinuxVirtualMachineConfiguration? = nil
  var macOSGuestOperatingSystem: MacGuestOperatingSystemIdentity? = nil
  var macOSMinimumCPUCount: Int? = nil
  var macOSMinimumMemoryBytes: UInt64? = nil
  var macOSFirstBootState: MacVirtualMachineFirstBootState? = nil
  var macOSDiskSnapshotConfiguration: MacVirtualMachineDiskSnapshotConfiguration? = nil
  var linuxDiskSnapshotConfiguration: VirtualMachineDiskSnapshotConfiguration? = nil

  init(
    id: UUID = UUID(),
    name: String,
    guest: VirtualMachineGuest,
    installState: VirtualMachineInstallState = .draft,
    resources: VirtualMachineResources,
    createdAt: Date = Date(),
    diskImagePath: String = "Disk.img",
    diskImageFormat: VirtualMachineDiskImageFormat = .raw
  ) throws {
    let trimmedName = try Self.normalizedName(name)

    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.name = trimmedName
    self.guest = guest
    self.installState = installState
    self.resources = resources
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.diskImagePath = diskImagePath
    self.diskImageFormat = diskImageFormat
  }

  var effectiveDiskImageFormat: VirtualMachineDiskImageFormat {
    diskImageFormat ?? .raw
  }

  init(
    cloning source: VirtualMachineManifest,
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date(),
    linuxMACAddress: String? = nil
  ) throws {
    let trimmedName = try Self.normalizedName(name)

    schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.name = trimmedName
    guest = source.guest
    installState = source.installState
    resources = source.resources
    self.createdAt = createdAt
    updatedAt = createdAt
    diskImagePath = source.diskImagePath
    diskImageFormat = source.effectiveDiskImageFormat
    auxiliaryStoragePath = source.auxiliaryStoragePath
    hardwareModelPath = source.hardwareModelPath
    machineIdentifierPath = source.machineIdentifierPath
    restoreImageURL = source.restoreImageURL
    installationOperationID = nil
    installationFailure = nil
    audioConfiguration = nil
    networkConfiguration = source.networkConfiguration
    if source.guest == .linux {
      guard var configuration = source.linuxConfiguration else {
        throw LinuxVirtualMachineError.missingManifestValue("linuxConfiguration")
      }
      guard let linuxMACAddress else {
        throw LinuxVirtualMachineError.missingManifestValue("linuxMACAddress")
      }
      configuration.macAddress = linuxMACAddress
      linuxConfiguration = configuration
    } else {
      linuxConfiguration = source.linuxConfiguration
    }
    macOSGuestOperatingSystem = source.macOSGuestOperatingSystem
    macOSMinimumCPUCount = source.macOSMinimumCPUCount
    macOSMinimumMemoryBytes = source.macOSMinimumMemoryBytes
    macOSFirstBootState = source.macOSFirstBootState
    macOSDiskSnapshotConfiguration = source.macOSDiskSnapshotConfiguration
    linuxDiskSnapshotConfiguration = source.linuxDiskSnapshotConfiguration
  }

  var effectiveAudioConfiguration: MacVirtualMachineAudioConfiguration {
    audioConfiguration ?? .disconnected
  }

  var effectiveNetworkConfiguration: VirtualMachineNetworkConfiguration {
    networkConfiguration ?? .nat
  }

  var effectiveMacOSDiskSnapshotConfiguration: MacVirtualMachineDiskSnapshotConfiguration {
    macOSDiskSnapshotConfiguration ?? .empty
  }

  var effectiveLinuxDiskSnapshotConfiguration: VirtualMachineDiskSnapshotConfiguration {
    linuxDiskSnapshotConfiguration ?? .empty
  }

  var effectiveDiskSnapshotConfiguration: VirtualMachineDiskSnapshotConfiguration {
    switch guest {
    case .macOS:
      effectiveMacOSDiskSnapshotConfiguration
    case .linux:
      effectiveLinuxDiskSnapshotConfiguration
    }
  }

  @discardableResult
  mutating func rename(
    to name: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    let normalizedName = try Self.normalizedName(name)
    guard normalizedName != self.name else { return false }
    self.name = normalizedName
    self.updatedAt = updatedAt
    return true
  }

  private static func normalizedName(_ name: String) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw VirtualMachineModelError.emptyName
    }
    return normalizedName
  }

  mutating func markInstallationStarted(
    operationID: UUID,
    updatedAt: Date = Date()
  ) {
    installState = .installing
    installationOperationID = operationID
    installationFailure = nil
    self.updatedAt = updatedAt
  }

  mutating func markInstallationCompleted(
    diskImagePath: String,
    auxiliaryStoragePath: String,
    updatedAt: Date = Date()
  ) {
    installState = .stopped
    self.diskImagePath = diskImagePath
    diskImageFormat = .raw
    self.auxiliaryStoragePath = auxiliaryStoragePath
    restoreImageURL = nil
    installationOperationID = nil
    installationFailure = nil
    macOSFirstBootState = .pending
    macOSDiskSnapshotConfiguration = nil
    linuxDiskSnapshotConfiguration = nil
    self.updatedAt = updatedAt
  }

  mutating func markDiskImageReplaced(
    to path: String,
    format: VirtualMachineDiskImageFormat,
    updatedAt: Date = Date()
  ) {
    diskImagePath = path
    diskImageFormat = format
    self.updatedAt = updatedAt
  }

  @discardableResult
  mutating func growDisk(
    to diskBytes: UInt64,
    updatedAt: Date = Date()
  ) throws -> Bool {
    guard diskBytes >= resources.diskBytes else {
      throw VirtualMachineDiskImageResizeError.growthRequired(
        current: resources.diskBytes,
        requested: diskBytes
      )
    }
    guard diskBytes != resources.diskBytes else { return false }
    resources = try VirtualMachineResources(
      cpuCount: resources.cpuCount,
      memoryBytes: resources.memoryBytes,
      diskBytes: diskBytes
    )
    self.updatedAt = updatedAt
    return true
  }

  mutating func markInstallationAborted(
    kind: VirtualMachineInstallationFailureKind,
    message: String,
    updatedAt: Date = Date()
  ) {
    installState = .readyToInstall
    installationOperationID = nil
    installationFailure = VirtualMachineInstallationFailure(
      kind: kind,
      message: message,
      occurredAt: updatedAt
    )
    self.updatedAt = updatedAt
  }

  mutating func markInstallationFailed(
    kind: VirtualMachineInstallationFailureKind,
    message: String,
    updatedAt: Date = Date()
  ) {
    installState = .failed
    installationOperationID = nil
    installationFailure = VirtualMachineInstallationFailure(
      kind: kind,
      message: message,
      occurredAt: updatedAt
    )
    self.updatedAt = updatedAt
  }

  mutating func markReadyToInstallMacOS(
    restoreImageURL: URL,
    auxiliaryStoragePath: String,
    hardwareModelPath: String,
    machineIdentifierPath: String,
    operatingSystem: MacGuestOperatingSystemIdentity? = nil,
    minimumCPUCount: Int? = nil,
    minimumMemoryBytes: UInt64? = nil,
    updatedAt: Date = Date()
  ) {
    installState = .readyToInstall
    self.restoreImageURL = restoreImageURL
    self.auxiliaryStoragePath = auxiliaryStoragePath
    self.hardwareModelPath = hardwareModelPath
    self.machineIdentifierPath = machineIdentifierPath
    macOSGuestOperatingSystem = operatingSystem
    macOSMinimumCPUCount = minimumCPUCount
    macOSMinimumMemoryBytes = minimumMemoryBytes
    macOSFirstBootState = nil
    macOSDiskSnapshotConfiguration = nil
    linuxDiskSnapshotConfiguration = nil
    installationOperationID = nil
    installationFailure = nil
    self.updatedAt = updatedAt
  }

  mutating func markReadyToInstallLinux(
    configuration: LinuxVirtualMachineConfiguration,
    updatedAt: Date = Date()
  ) {
    installState = .readyToInstall
    linuxConfiguration = configuration
    linuxDiskSnapshotConfiguration = nil
    installationOperationID = nil
    installationFailure = nil
    self.updatedAt = updatedAt
  }

  mutating func markLinuxInstallationCompleted(updatedAt: Date = Date()) {
    installState = .stopped
    linuxConfiguration?.installationMediaPath = nil
    installationOperationID = nil
    installationFailure = nil
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
  case bundleIdentifierMismatch(expected: UUID, bundleName: String)
  case libraryInUse
  case virtualMachineNotFound(UUID)
  case virtualMachineIdentityChanged(UUID)
  case requiresMacOSGuest(UUID)
  case requiresLinuxGuest(UUID)
  case invalidInstallState(VirtualMachineInstallState)
  case platformArtifactsAlreadyExist(UUID)
  case linuxPlatformArtifactsAlreadyExist(UUID)
  case invalidRestoreImageReference(URL)
  case macPlatformPreparationUnavailable
  case linuxPlatformPreparationUnavailable
  case virtualMachineDiscardUnavailable

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
    case .bundleIdentifierMismatch(let expected, let bundleName):
      "Virtual machine bundle \(bundleName) does not match manifest identifier \(expected.uuidString)."
    case .libraryInUse:
      "Another NativeContainers process is changing the virtual machine library. Try again when that operation finishes."
    case .virtualMachineNotFound(let identifier):
      "No virtual machine with identifier \(identifier.uuidString) exists."
    case .virtualMachineIdentityChanged(let identifier):
      "Virtual machine \(identifier.uuidString) changed after it was reviewed."
    case .requiresMacOSGuest(let identifier):
      "Virtual machine \(identifier.uuidString) is not configured for macOS."
    case .requiresLinuxGuest(let identifier):
      "Virtual machine \(identifier.uuidString) is not configured for Linux."
    case .invalidInstallState(let state):
      "A virtual machine in the \(state.rawValue) state cannot perform this operation."
    case .platformArtifactsAlreadyExist(let identifier):
      "macOS platform artifacts already exist for virtual machine \(identifier.uuidString)."
    case .linuxPlatformArtifactsAlreadyExist(let identifier):
      "Linux platform artifacts already exist for virtual machine \(identifier.uuidString)."
    case .invalidRestoreImageReference(let url):
      "The restore-image reference is invalid: \(url.absoluteString)"
    case .macPlatformPreparationUnavailable:
      "macOS platform preparation is unavailable for this virtual machine library."
    case .linuxPlatformPreparationUnavailable:
      "Linux platform preparation is unavailable for this virtual machine library."
    case .virtualMachineDiscardUnavailable:
      "Discarding virtual machines is unavailable for this virtual machine library."
    }
  }
}
