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

protocol MacVirtualMachineSharedDirectoryPersisting: Sendable {
  func macOSSharedDirectoryConfiguration(
    id: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration

  func addMacOSSharedDirectory(
    _ directory: MacVirtualMachineSharedDirectory,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration

  func removeMacOSSharedDirectory(
    id: UUID,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration
}

protocol MacVirtualMachineSharedDirectoryManaging: Sendable {
  func configuration(
    id: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration

  func add(
    to machineID: UUID,
    request: MacVirtualMachineSharedDirectoryRequest
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration
}

struct UnavailableMacVirtualMachineSharedDirectoryService:
  MacVirtualMachineSharedDirectoryManaging
{
  func configuration(
    id: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    throw MacVirtualMachineSharedDirectoryError.unavailable
  }

  func add(
    to machineID: UUID,
    request: MacVirtualMachineSharedDirectoryRequest
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    throw MacVirtualMachineSharedDirectoryError.unavailable
  }

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    throw MacVirtualMachineSharedDirectoryError.unavailable
  }
}

actor MacVirtualMachineSharedDirectoryService:
  MacVirtualMachineSharedDirectoryManaging
{
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineSharedDirectoryPersisting
  private let savedStateService: any MacVirtualMachineSavedStateInspecting
  private let bookmarkService: any VirtualMachineSharedDirectoryBookmarkCreating
  private let nameValidator: any VirtualMachineSharedDirectoryNameValidating

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineSharedDirectoryPersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting,
    bookmarkService: any VirtualMachineSharedDirectoryBookmarkCreating =
      MacVirtualMachineSharedDirectoryBookmarkService(),
    nameValidator: any VirtualMachineSharedDirectoryNameValidating =
      AppleMacVirtualMachineSharedDirectoryNameValidator()
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
    self.bookmarkService = bookmarkService
    self.nameValidator = nameValidator
  }

  func configuration(
    id: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    try await persistence.macOSSharedDirectoryConfiguration(id: id)
  }

  func add(
    to machineID: UUID,
    request: MacVirtualMachineSharedDirectoryRequest
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let canonicalName = try nameValidator.canonicalName(from: request.guestName)
    let current = try await persistence.macOSSharedDirectoryConfiguration(id: machineID)
    try requireUniqueName(canonicalName, in: current.directories)

    let directory = try bookmarkService.makeRecord(
      request: request,
      canonicalGuestName: canonicalName
    )
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    return try await persistence.addMacOSSharedDirectory(directory, for: lease)
  }

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> MacVirtualMachineSharedDirectoryConfiguration {
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    return try await persistence.removeMacOSSharedDirectory(
      id: sharedDirectoryID,
      for: lease
    )
  }

  private func requireNoSavedState(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    let status = try await savedStateService.inspect(for: lease)
    guard status == .none else {
      throw MacVirtualMachineSharedDirectoryError.savedStateBlocksChanges(
        lease.target.machineID
      )
    }
  }

  private func requireUniqueName(
    _ name: String,
    in directories: [MacVirtualMachineSharedDirectory]
  ) throws {
    let normalized = MacVirtualMachineSharedDirectoryNameNormalizer.normalized(name)
    guard
      !directories.contains(where: {
        MacVirtualMachineSharedDirectoryNameNormalizer.normalized($0.guestName)
          == normalized
      })
    else {
      throw MacVirtualMachineSharedDirectoryError.duplicateName(name)
    }
  }
}
