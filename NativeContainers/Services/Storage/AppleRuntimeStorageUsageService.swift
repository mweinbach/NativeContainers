import ContainerAPIClient
import ContainerXPC
import Foundation

protocol AppleRuntimeStorageUsageLoading: Sendable {
  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage
}

protocol AppleRuntimeDiskUsageReading: Sendable {
  func readDiskUsage() async throws -> AppleRuntimeDiskUsageValues
}

struct AppleRuntimeDiskUsageValues: Equatable, Sendable {
  let images: StorageResourceUsage
  let containers: StorageResourceUsage
  let volumes: StorageResourceUsage
}

struct AppleRuntimeDiskUsageClient: AppleRuntimeDiskUsageReading {
  private let requestSender: any AppleXPCRequestSending

  init(operationTimeout: Duration = .seconds(60)) {
    requestSender = AppleXPCRequestClient(
      operationTimeout: operationTimeout
    )
  }

  init(requestSender: any AppleXPCRequestSending) {
    self.requestSender = requestSender
  }

  func readDiskUsage() async throws -> AppleRuntimeDiskUsageValues {
    let response = try await requestSender.send(
      XPCMessage(route: .systemDiskUsage),
      operation: "Inspect Apple runtime storage"
    )
    guard let data = response.dataNoCopy(key: .diskUsageStats) else {
      throw StorageUsageError.invalidRuntimeResponse(
        "the disk-usage payload is missing"
      )
    }
    let usage: DiskUsageStats
    do {
      usage = try JSONDecoder().decode(DiskUsageStats.self, from: data)
    } catch {
      throw StorageUsageError.invalidRuntimeResponse(
        "the disk-usage payload is malformed"
      )
    }
    return AppleRuntimeDiskUsageValues(
      images: try map(usage.images, name: "images"),
      containers: try map(usage.containers, name: "containers"),
      volumes: try map(usage.volumes, name: "volumes")
    )
  }

  private func map(
    _ usage: ResourceUsage,
    name: String
  ) throws -> StorageResourceUsage {
    guard usage.total >= 0 else {
      throw StorageUsageError.invalidRuntimeResponse(
        "\(name) has a negative total count"
      )
    }
    guard usage.active >= 0, usage.active <= usage.total else {
      throw StorageUsageError.invalidRuntimeResponse(
        "\(name) has an invalid active count"
      )
    }
    guard usage.reclaimable <= usage.sizeInBytes else {
      throw StorageUsageError.invalidRuntimeResponse(
        "\(name) has more reclaimable than allocated bytes"
      )
    }
    return StorageResourceUsage(
      totalCount: usage.total,
      activeCount: usage.active,
      allocatedBytes: usage.sizeInBytes,
      reclaimableBytes: usage.reclaimable
    )
  }
}

struct AppleRuntimeStorageUsageService: AppleRuntimeStorageUsageLoading {
  private let reader: any AppleRuntimeDiskUsageReading
  private let now: @Sendable () -> Date

  init(
    reader: any AppleRuntimeDiskUsageReading = AppleRuntimeDiskUsageClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.reader = reader
    self.now = now
  }

  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    try Task.checkCancellation()
    let usage = try await reader.readDiskUsage()
    try Task.checkCancellation()
    return AppleRuntimeStorageUsage(
      capturedAt: now(),
      images: usage.images,
      containers: usage.containers,
      volumes: usage.volumes
    )
  }
}

struct UnavailableAppleRuntimeStorageUsageService:
  AppleRuntimeStorageUsageLoading
{
  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    throw StorageUsageError.unavailable
  }
}
