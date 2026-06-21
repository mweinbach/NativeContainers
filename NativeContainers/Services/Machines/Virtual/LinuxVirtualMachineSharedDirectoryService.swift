import Foundation

protocol LinuxVirtualMachineSharedDirectoryPersisting: Sendable {
  func linuxSharedDirectoryConfiguration(
    id: UUID
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration

  func addLinuxSharedDirectory(
    _ directory: LinuxVirtualMachineSharedDirectory,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration

  func removeLinuxSharedDirectory(
    id: UUID,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration
}

struct UnavailableLinuxVirtualMachineSharedDirectoryService:
  LinuxVirtualMachineSharedDirectoryManaging
{
  func configuration(
    id: UUID
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    throw LinuxVirtualMachineSharedDirectoryError.unavailable
  }

  func add(
    to machineID: UUID,
    request: LinuxVirtualMachineSharedDirectoryRequest
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    throw LinuxVirtualMachineSharedDirectoryError.unavailable
  }

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    throw LinuxVirtualMachineSharedDirectoryError.unavailable
  }
}

actor LinuxVirtualMachineSharedDirectoryService:
  LinuxVirtualMachineSharedDirectoryManaging
{
  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let persistence: any LinuxVirtualMachineSharedDirectoryPersisting
  private let bookmarkService: any LinuxVirtualMachineSharedDirectoryBookmarkCreating
  private let nameValidator: any LinuxVirtualMachineSharedDirectoryNameValidating

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    persistence: any LinuxVirtualMachineSharedDirectoryPersisting,
    bookmarkService: any LinuxVirtualMachineSharedDirectoryBookmarkCreating =
      LinuxVirtualMachineSharedDirectoryBookmarkService(),
    nameValidator: any LinuxVirtualMachineSharedDirectoryNameValidating =
      AppleLinuxVirtualMachineSharedDirectoryNameValidator()
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.bookmarkService = bookmarkService
    self.nameValidator = nameValidator
  }

  func configuration(
    id: UUID
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    try await persistence.linuxSharedDirectoryConfiguration(id: id)
  }

  func add(
    to machineID: UUID,
    request: LinuxVirtualMachineSharedDirectoryRequest
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    let canonicalName = try nameValidator.canonicalName(from: request.guestName)
    let current = try await persistence.linuxSharedDirectoryConfiguration(id: machineID)
    try requireUniqueName(canonicalName, in: current.directories)

    let directory = try bookmarkService.makeRecord(
      request: request,
      canonicalGuestName: canonicalName
    )
    let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
    defer { lease.release() }

    return try await persistence.addLinuxSharedDirectory(directory, for: lease)
  }

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) async throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
    defer { lease.release() }

    return try await persistence.removeLinuxSharedDirectory(
      id: sharedDirectoryID,
      for: lease
    )
  }

  private func requireUniqueName(
    _ name: String,
    in directories: [LinuxVirtualMachineSharedDirectory]
  ) throws {
    let normalized = LinuxVirtualMachineSharedDirectoryNameNormalizer.normalized(name)
    guard
      !directories.contains(where: {
        LinuxVirtualMachineSharedDirectoryNameNormalizer.normalized($0.guestName)
          == normalized
      })
    else {
      throw LinuxVirtualMachineSharedDirectoryError.duplicateName(name)
    }
  }
}
