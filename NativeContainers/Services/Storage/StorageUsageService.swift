import Foundation

protocol StorageUsageLoading: Sendable {
  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage
  func loadVirtualMachineStorageUsage() async throws -> VirtualMachineStorageSummary
}

struct StorageUsageService: StorageUsageLoading {
  private let appleRuntime: any AppleRuntimeStorageUsageLoading
  private let virtualMachines: any VirtualMachineStorageUsageLoading

  init(
    appleRuntime: any AppleRuntimeStorageUsageLoading,
    virtualMachines: any VirtualMachineStorageUsageLoading
  ) {
    self.appleRuntime = appleRuntime
    self.virtualMachines = virtualMachines
  }

  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    try await appleRuntime.loadAppleRuntimeStorageUsage()
  }

  func loadVirtualMachineStorageUsage() async throws -> VirtualMachineStorageSummary {
    try await virtualMachines.loadVirtualMachineStorageUsage()
  }
}

struct UnavailableStorageUsageService: StorageUsageLoading {
  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    throw StorageUsageError.unavailable
  }

  func loadVirtualMachineStorageUsage() async throws -> VirtualMachineStorageSummary {
    throw StorageUsageError.unavailable
  }
}
