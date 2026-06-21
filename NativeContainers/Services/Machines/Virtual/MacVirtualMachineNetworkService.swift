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

protocol MacVirtualMachineNetworkManaging: Sendable {
  func snapshot(id: UUID) async throws -> MacVirtualMachineNetworkSnapshot

  func setAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) async throws -> MacVirtualMachineNetworkSnapshot
}

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
