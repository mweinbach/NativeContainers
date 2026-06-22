import Foundation

protocol VirtualMachineNameManaging: Sendable {
  func currentName(id: UUID) async throws -> String

  func rename(
    _ name: String,
    for machineID: UUID
  ) async throws -> String
}

typealias MacVirtualMachineNameManaging = VirtualMachineNameManaging
typealias LinuxVirtualMachineNameManaging = VirtualMachineNameManaging

protocol MacVirtualMachineNamePersisting: Sendable {
  func macOSName(id: UUID) async throws -> String

  func renameMacOS(
    to name: String,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> String
}

protocol LinuxVirtualMachineNamePersisting: Sendable {
  func linuxName(id: UUID) async throws -> String

  func renameLinux(
    to name: String,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> String
}

struct UnavailableVirtualMachineNameService: VirtualMachineNameManaging {
  func currentName(id: UUID) async throws -> String {
    throw VirtualMachineNameError.unavailable
  }

  func rename(
    _ name: String,
    for machineID: UUID
  ) async throws -> String {
    throw VirtualMachineNameError.unavailable
  }
}

actor MacVirtualMachineNameService: MacVirtualMachineNameManaging {
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineNamePersisting

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineNamePersisting
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
  }

  func currentName(id: UUID) async throws -> String {
    try await persistence.macOSName(id: id)
  }

  func rename(
    _ name: String,
    for machineID: UUID
  ) async throws -> String {
    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }
    return try await persistence.renameMacOS(to: name, for: lease)
  }
}

actor LinuxVirtualMachineNameService: LinuxVirtualMachineNameManaging {
  private let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  private let persistence: any LinuxVirtualMachineNamePersisting

  init(
    leasingStore: any LinuxVirtualMachineRuntimeLeasing,
    persistence: any LinuxVirtualMachineNamePersisting
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
  }

  func currentName(id: UUID) async throws -> String {
    try await persistence.linuxName(id: id)
  }

  func rename(
    _ name: String,
    for machineID: UUID
  ) async throws -> String {
    let lease = try await leasingStore.acquireLinuxRuntime(id: machineID)
    defer { lease.release() }
    return try await persistence.renameLinux(to: name, for: lease)
  }
}

enum VirtualMachineNameError: LocalizedError, Equatable, Sendable {
  case unavailable

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine renaming is unavailable."
    }
  }
}
