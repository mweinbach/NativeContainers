import Foundation

struct StorageResourceUsage: Equatable, Sendable {
  let totalCount: Int
  let activeCount: Int
  let allocatedBytes: UInt64
  let reclaimableBytes: UInt64

  var inactiveCount: Int {
    max(totalCount - activeCount, 0)
  }

  var retainedBytes: UInt64 {
    allocatedBytes > reclaimableBytes
      ? allocatedBytes - reclaimableBytes
      : 0
  }
}

struct AppleRuntimeStorageUsage: Equatable, Sendable {
  let capturedAt: Date
  let images: StorageResourceUsage
  let containers: StorageResourceUsage
  let volumes: StorageResourceUsage

  var totalAllocatedBytes: UInt64 {
    StorageByteMath.saturatingSum([
      images.allocatedBytes,
      containers.allocatedBytes,
      volumes.allocatedBytes,
    ])
  }

  var totalReclaimableBytes: UInt64 {
    StorageByteMath.saturatingSum([
      images.reclaimableBytes,
      containers.reclaimableBytes,
      volumes.reclaimableBytes,
    ])
  }
}

struct VirtualMachineStorageTarget: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
}

struct VirtualMachineStorageInventory: Equatable, Sendable {
  let rootURL: URL
  let targets: [VirtualMachineStorageTarget]
}

struct VirtualMachineStorageUsage: Equatable, Sendable, Identifiable {
  var id: UUID { machineID }

  let machineID: UUID
  let name: String
  let installState: VirtualMachineInstallState
  let provisionedDiskBytes: UInt64
  let diskLogicalBytes: UInt64
  let diskAllocatedBytes: UInt64
  let bundleLogicalBytes: UInt64
  let bundleAllocatedBytes: UInt64
  let savedStateAllocatedBytes: UInt64
  let regularFileCount: Int
  let hardLinkCount: Int
  let nonRegularEntryCount: Int
  let missingEntryCount: Int
  let overflowed: Bool

  var isApproximate: Bool {
    hardLinkCount > 0
      || nonRegularEntryCount > 0
      || missingEntryCount > 0
      || overflowed
  }
}

struct VirtualMachineStorageIssue: Equatable, Sendable, Identifiable {
  var id: UUID { machineID }

  let machineID: UUID
  let name: String
  let message: String
}

struct VirtualMachineStorageSummary: Equatable, Sendable {
  let capturedAt: Date
  let discoveredMachineCount: Int
  let libraryLogicalBytes: UInt64
  let libraryAllocatedBytes: UInt64
  let libraryEntryCount: Int
  let libraryHardLinkCount: Int
  let libraryNonRegularEntryCount: Int
  let libraryMissingEntryCount: Int
  let libraryOverflowed: Bool
  let machines: [VirtualMachineStorageUsage]
  let issues: [VirtualMachineStorageIssue]

  var totalProvisionedDiskBytes: UInt64 {
    StorageByteMath.saturatingSum(machines.map(\.provisionedDiskBytes))
  }

  var totalLogicalBytes: UInt64 {
    libraryLogicalBytes
  }

  var totalAllocatedBytes: UInt64 {
    libraryAllocatedBytes
  }

  var totalSavedStateAllocatedBytes: UInt64 {
    StorageByteMath.saturatingSum(machines.map(\.savedStateAllocatedBytes))
  }

  var hasApproximateMeasurements: Bool {
    libraryHardLinkCount > 0
      || libraryNonRegularEntryCount > 0
      || libraryMissingEntryCount > 0
      || libraryOverflowed
      || !issues.isEmpty
      || machines.contains(where: \.isApproximate)
  }

  var unattributedAllocatedBytes: UInt64 {
    let attributed = StorageByteMath.saturatingSum(
      machines.map(\.bundleAllocatedBytes)
    )
    return libraryAllocatedBytes > attributed
      ? libraryAllocatedBytes - attributed
      : 0
  }
}

enum StorageUsageError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidRuntimeResponse(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Storage accounting is unavailable."
    case .invalidRuntimeResponse(let reason):
      "Apple’s runtime returned invalid storage usage: \(reason)"
    }
  }
}

enum StorageByteMath {
  static func saturatingSum<S: Sequence>(_ values: S) -> UInt64
  where S.Element == UInt64 {
    values.reduce(0) { total, value in
      let (sum, overflow) = total.addingReportingOverflow(value)
      return overflow ? UInt64.max : sum
    }
  }

  static func saturatingProduct(_ lhs: UInt64, _ rhs: UInt64) -> (
    value: UInt64,
    overflowed: Bool
  ) {
    let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return (overflow ? UInt64.max : product, overflow)
  }

  static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> (
    value: UInt64,
    overflowed: Bool
  ) {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return (overflow ? UInt64.max : sum, overflow)
  }
}
