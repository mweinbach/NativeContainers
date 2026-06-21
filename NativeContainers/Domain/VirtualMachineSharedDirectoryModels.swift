import Foundation

enum VirtualMachineSharedDirectoryNameNormalizer {
  static func normalized(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}

struct VirtualMachineSharedDirectorySourceIdentity: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
}

struct VirtualMachineSharedDirectory: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let guestName: String
  let bookmarkData: Data
  let lastKnownPath: String
  let sourceIdentity: VirtualMachineSharedDirectorySourceIdentity
  let readOnly: Bool
}

struct VirtualMachineSharedDirectorySummary: Equatable, Identifiable, Sendable {
  let id: UUID
  let guestName: String
  let lastKnownPath: String
  let readOnly: Bool
}

extension VirtualMachineSharedDirectory {
  var summary: VirtualMachineSharedDirectorySummary {
    VirtualMachineSharedDirectorySummary(
      id: id,
      guestName: guestName,
      lastKnownPath: lastKnownPath,
      readOnly: readOnly
    )
  }
}

struct VirtualMachineSharedDirectoryConfiguration: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let revision: UInt64
  let directories: [VirtualMachineSharedDirectory]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    revision: UInt64 = 0,
    directories: [VirtualMachineSharedDirectory] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.directories = directories.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  static let empty = VirtualMachineSharedDirectoryConfiguration()
}

struct ResolvedVirtualMachineSharedDirectory: Equatable, Sendable {
  let id: UUID
  let guestName: String
  let sourceURL: URL
  let sourceIdentity: VirtualMachineSharedDirectorySourceIdentity
  let readOnly: Bool
}

struct VirtualMachineSharedDirectoryRequest: Equatable, Sendable {
  let sourceURL: URL
  let guestName: String
  let readOnly: Bool
}

enum VirtualMachineSharedDirectoryError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidName(String, String)
  case duplicateName(String)
  case invalidDirectory(String)
  case accessDenied(String)
  case staleBookmark(String)
  case sourceIdentityChanged(String)
  case sharedDirectoryNotFound(UUID)
  case savedStateBlocksChanges(UUID)
  case invalidStore(String)
  case configurationRevisionOverflow

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Shared-folder management is unavailable."
    case .invalidName(let name, let reason):
      "The guest folder name “\(name)” is invalid: \(reason)"
    case .duplicateName(let name):
      "A shared folder named “\(name)” already exists in this virtual machine."
    case .invalidDirectory(let path):
      "The shared-folder source is not a safe local directory: \(path)"
    case .accessDenied(let path):
      "NativeContainers cannot access the shared folder at \(path). Choose it again."
    case .staleBookmark(let name):
      "The saved permission for “\(name)” is stale. Remove the share and choose the folder again."
    case .sourceIdentityChanged(let name):
      "The folder behind “\(name)” was replaced. Remove the share and choose the intended folder again."
    case .sharedDirectoryNotFound(let identifier):
      "No shared folder with identifier \(identifier.uuidString) exists."
    case .savedStateBlocksChanges:
      "Discard the VM’s saved state before changing shared folders."
    case .invalidStore(let reason):
      "The shared-folder configuration is invalid: \(reason)"
    case .configurationRevisionOverflow:
      "The shared-folder configuration revision cannot be advanced."
    }
  }
}

typealias MacVirtualMachineSharedDirectoryNameNormalizer =
  VirtualMachineSharedDirectoryNameNormalizer
typealias MacVirtualMachineSharedDirectorySourceIdentity =
  VirtualMachineSharedDirectorySourceIdentity
typealias MacVirtualMachineSharedDirectory = VirtualMachineSharedDirectory
typealias MacVirtualMachineSharedDirectorySummary = VirtualMachineSharedDirectorySummary
typealias MacVirtualMachineSharedDirectoryConfiguration =
  VirtualMachineSharedDirectoryConfiguration
typealias ResolvedMacVirtualMachineSharedDirectory = ResolvedVirtualMachineSharedDirectory
typealias MacVirtualMachineSharedDirectoryRequest = VirtualMachineSharedDirectoryRequest
typealias MacVirtualMachineSharedDirectoryError = VirtualMachineSharedDirectoryError

typealias LinuxVirtualMachineSharedDirectoryNameNormalizer =
  VirtualMachineSharedDirectoryNameNormalizer
typealias LinuxVirtualMachineSharedDirectorySourceIdentity =
  VirtualMachineSharedDirectorySourceIdentity
typealias LinuxVirtualMachineSharedDirectory = VirtualMachineSharedDirectory
typealias LinuxVirtualMachineSharedDirectorySummary = VirtualMachineSharedDirectorySummary
typealias LinuxVirtualMachineSharedDirectoryConfiguration =
  VirtualMachineSharedDirectoryConfiguration
typealias ResolvedLinuxVirtualMachineSharedDirectory = ResolvedVirtualMachineSharedDirectory
typealias LinuxVirtualMachineSharedDirectoryRequest = VirtualMachineSharedDirectoryRequest
typealias LinuxVirtualMachineSharedDirectoryError = VirtualMachineSharedDirectoryError
