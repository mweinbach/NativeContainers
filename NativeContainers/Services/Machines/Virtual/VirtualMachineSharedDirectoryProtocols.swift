import Foundation

protocol VirtualMachineSharedDirectoryNameValidating: Sendable {
  func canonicalName(from proposedName: String) throws -> String
  func validatePersistedName(_ name: String) throws
}

protocol VirtualMachineSharedDirectoryBookmarkCreating: Sendable {
  func makeRecord(
    request: VirtualMachineSharedDirectoryRequest,
    canonicalGuestName: String
  ) throws -> VirtualMachineSharedDirectory
}

protocol VirtualMachineSharedDirectoryBookmarkResolving: Sendable {
  func resolve(
    _ directories: [VirtualMachineSharedDirectory]
  ) throws -> VirtualMachineSharedDirectoryAccess
}

protocol VirtualMachineSharedDirectoryBookmarking:
  VirtualMachineSharedDirectoryBookmarkCreating,
  VirtualMachineSharedDirectoryBookmarkResolving
{}

protocol VirtualMachineSharedDirectoryConfigurationStoring: Sendable {
  func load(
    from bundleURL: URL
  ) throws -> VirtualMachineSharedDirectoryConfiguration

  func save(
    _ configuration: VirtualMachineSharedDirectoryConfiguration,
    to bundleURL: URL
  ) throws
}

protocol VirtualMachineSharedDirectoryManaging: Sendable {
  func configuration(
    id: UUID
  ) async throws -> VirtualMachineSharedDirectoryConfiguration

  func add(
    to machineID: UUID,
    request: VirtualMachineSharedDirectoryRequest
  ) async throws -> VirtualMachineSharedDirectoryConfiguration

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> VirtualMachineSharedDirectoryConfiguration
}

typealias MacVirtualMachineSharedDirectoryNameValidating =
  VirtualMachineSharedDirectoryNameValidating
typealias MacVirtualMachineSharedDirectoryBookmarkCreating =
  VirtualMachineSharedDirectoryBookmarkCreating
typealias MacVirtualMachineSharedDirectoryBookmarkResolving =
  VirtualMachineSharedDirectoryBookmarkResolving
typealias MacVirtualMachineSharedDirectoryBookmarking =
  VirtualMachineSharedDirectoryBookmarking
typealias MacVirtualMachineSharedDirectoryConfigurationStoring =
  VirtualMachineSharedDirectoryConfigurationStoring
typealias MacVirtualMachineSharedDirectoryManaging =
  VirtualMachineSharedDirectoryManaging

typealias LinuxVirtualMachineSharedDirectoryNameValidating =
  VirtualMachineSharedDirectoryNameValidating
typealias LinuxVirtualMachineSharedDirectoryBookmarkCreating =
  VirtualMachineSharedDirectoryBookmarkCreating
typealias LinuxVirtualMachineSharedDirectoryBookmarkResolving =
  VirtualMachineSharedDirectoryBookmarkResolving
typealias LinuxVirtualMachineSharedDirectoryBookmarking =
  VirtualMachineSharedDirectoryBookmarking
typealias LinuxVirtualMachineSharedDirectoryConfigurationStoring =
  VirtualMachineSharedDirectoryConfigurationStoring
typealias LinuxVirtualMachineSharedDirectoryManaging =
  VirtualMachineSharedDirectoryManaging
