import Foundation
@preconcurrency import Virtualization

@MainActor
enum AppleVirtualMachineComputeLimits {
  static func current() -> VirtualMachineComputeLimits {
    let gibibyte = VirtualMachineResources.bytesPerGiB
    let minimumMemory = max(
      VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      gibibyte
    )
    let roundedMinimumMemory =
      ((minimumMemory + gibibyte - 1) / gibibyte) * gibibyte
    let roundedMaximumMemory =
      (VZVirtualMachineConfiguration.maximumAllowedMemorySize / gibibyte)
      * gibibyte

    return VirtualMachineComputeLimits(
      minimumCPUCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      minimumMemoryBytes: roundedMinimumMemory,
      maximumMemoryBytes: roundedMaximumMemory
    )
  }
}

protocol VirtualMachineComputeManaging: Sendable {
  func snapshot(id: UUID) async throws -> VirtualMachineComputeSnapshot

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) async throws -> VirtualMachineComputeSnapshot
}

typealias MacVirtualMachineComputeManaging = VirtualMachineComputeManaging
typealias LinuxVirtualMachineComputeManaging = VirtualMachineComputeManaging

protocol MacVirtualMachineComputePersisting: Sendable {
  func macOSComputeState(id: UUID) async throws -> VirtualMachineComputeState

  func setMacOSComputeConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    platformLimits: VirtualMachineComputeLimits,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineComputeState
}

protocol LinuxVirtualMachineComputePersisting: Sendable {
  func linuxComputeState(id: UUID) async throws -> VirtualMachineComputeState

  func setLinuxComputeConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    platformLimits: VirtualMachineComputeLimits,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineComputeState
}

struct UnavailableVirtualMachineComputeService: VirtualMachineComputeManaging {
  func snapshot(id: UUID) async throws -> VirtualMachineComputeSnapshot {
    throw VirtualMachineComputeError.unavailable
  }

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) async throws -> VirtualMachineComputeSnapshot {
    throw VirtualMachineComputeError.unavailable
  }
}

actor MacVirtualMachineComputeService: MacVirtualMachineComputeManaging {
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineComputePersisting
  private let savedStateService: any MacVirtualMachineSavedStateInspecting
  private let platformLimits: VirtualMachineComputeLimits

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineComputePersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting,
    platformLimits: VirtualMachineComputeLimits
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
    self.platformLimits = platformLimits
  }

  func snapshot(id: UUID) async throws -> VirtualMachineComputeSnapshot {
    let state = try await persistence.macOSComputeState(id: id)
    return try state.snapshot(platformLimits: platformLimits)
  }

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) async throws -> VirtualMachineComputeSnapshot {
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    let savedState = try await savedStateService.inspect(for: lease)
    guard savedState == .none else {
      throw VirtualMachineComputeError.savedStateBlocksChanges(machineID)
    }

    let state = try await persistence.setMacOSComputeConfiguration(
      configuration,
      platformLimits: platformLimits,
      for: lease
    )
    return try state.snapshot(platformLimits: platformLimits)
  }
}

actor LinuxVirtualMachineComputeService: LinuxVirtualMachineComputeManaging {
  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let persistence: any LinuxVirtualMachineComputePersisting
  private let savedStateService: any LinuxVirtualMachineSavedStateInspecting
  private let platformLimits: VirtualMachineComputeLimits

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    persistence: any LinuxVirtualMachineComputePersisting,
    savedStateService: any LinuxVirtualMachineSavedStateInspecting,
    platformLimits: VirtualMachineComputeLimits
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
    self.platformLimits = platformLimits
  }

  func snapshot(id: UUID) async throws -> VirtualMachineComputeSnapshot {
    let state = try await persistence.linuxComputeState(id: id)
    return try state.snapshot(platformLimits: platformLimits)
  }

  func setConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    for machineID: UUID
  ) async throws -> VirtualMachineComputeSnapshot {
    let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
    defer { lease.release() }

    let savedState = try await savedStateService.inspect(for: lease)
    guard savedState == .none else {
      throw VirtualMachineComputeError.savedStateBlocksChanges(machineID)
    }

    let state = try await persistence.setLinuxComputeConfiguration(
      configuration,
      platformLimits: platformLimits,
      for: lease
    )
    return try state.snapshot(platformLimits: platformLimits)
  }
}
