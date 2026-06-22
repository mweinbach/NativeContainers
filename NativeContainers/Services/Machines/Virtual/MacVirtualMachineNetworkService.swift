import Foundation

protocol MacVirtualMachineNetworkConfigurationPersisting: Sendable {
  func macOSNetworkConfiguration(
    id: UUID
  ) async throws -> MacVirtualMachineNetworkConfiguration

  func setMacOSNetworkAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineNetworkConfiguration
}

protocol VirtualMachineNetworkManaging: Sendable {
  func snapshot(id: UUID) async throws -> VirtualMachineNetworkSnapshot

  func setAttachment(
    _ attachment: VirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> VirtualMachineNetworkSnapshot
}

typealias MacVirtualMachineNetworkManaging = VirtualMachineNetworkManaging
typealias LinuxVirtualMachineNetworkManaging = VirtualMachineNetworkManaging

struct UnavailableMacVirtualMachineNetworkService:
  MacVirtualMachineNetworkManaging
{
  func snapshot(id: UUID) async throws -> MacVirtualMachineNetworkSnapshot {
    throw MacVirtualMachineNetworkError.unavailable
  }

  func setAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> MacVirtualMachineNetworkSnapshot {
    throw MacVirtualMachineNetworkError.unavailable
  }
}

actor MacVirtualMachineNetworkService: MacVirtualMachineNetworkManaging {
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineNetworkConfigurationPersisting
  private let savedStateService: any MacVirtualMachineSavedStateInspecting

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineNetworkConfigurationPersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
  }

  func snapshot(id: UUID) async throws -> MacVirtualMachineNetworkSnapshot {
    MacVirtualMachineNetworkSnapshot(
      configuration: try await persistence.macOSNetworkConfiguration(id: id)
    )
  }

  func setAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> MacVirtualMachineNetworkSnapshot {
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    let configuration = try await persistence.setMacOSNetworkAttachment(
      attachment,
      for: lease
    )
    return MacVirtualMachineNetworkSnapshot(configuration: configuration)
  }

  private func requireNoSavedState(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    let status = try await savedStateService.inspect(for: lease)
    guard status == .none else {
      throw MacVirtualMachineNetworkError.savedStateBlocksChanges(
        lease.target.machineID
      )
    }
  }
}

protocol LinuxVirtualMachineNetworkConfigurationPersisting: Sendable {
  func linuxNetworkConfiguration(
    id: UUID
  ) async throws -> LinuxVirtualMachineNetworkConfiguration

  func setLinuxNetworkAttachment(
    _ attachment: LinuxVirtualMachineNetworkAttachment,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineNetworkConfiguration
}

struct UnavailableLinuxVirtualMachineNetworkService:
  LinuxVirtualMachineNetworkManaging
{
  func snapshot(id: UUID) async throws -> LinuxVirtualMachineNetworkSnapshot {
    throw LinuxVirtualMachineNetworkError.unavailable
  }

  func setAttachment(
    _ attachment: LinuxVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> LinuxVirtualMachineNetworkSnapshot {
    throw LinuxVirtualMachineNetworkError.unavailable
  }
}

actor LinuxVirtualMachineNetworkService: LinuxVirtualMachineNetworkManaging {
  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let persistence: any LinuxVirtualMachineNetworkConfigurationPersisting
  private let savedStateService: any LinuxVirtualMachineSavedStateInspecting

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    persistence: any LinuxVirtualMachineNetworkConfigurationPersisting,
    savedStateService: any LinuxVirtualMachineSavedStateInspecting
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
  }

  func snapshot(id: UUID) async throws -> LinuxVirtualMachineNetworkSnapshot {
    LinuxVirtualMachineNetworkSnapshot(
      configuration: try await persistence.linuxNetworkConfiguration(id: id)
    )
  }

  func setAttachment(
    _ attachment: LinuxVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> LinuxVirtualMachineNetworkSnapshot {
    let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
    defer { lease.release() }

    let savedState = try await savedStateService.inspect(for: lease)
    guard savedState == .none else {
      throw LinuxVirtualMachineNetworkError.savedStateBlocksChanges(machineID)
    }

    return LinuxVirtualMachineNetworkSnapshot(
      configuration: try await persistence.setLinuxNetworkAttachment(
        attachment,
        for: lease
      )
    )
  }
}
