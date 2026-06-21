import Foundation

enum RuntimeState: String, Codable, CaseIterable, Sendable {
  case unknown
  case stopped
  case running
  case stopping

  var isRunning: Bool { self == .running }
}

struct ContainerSystemInfo: Codable, Equatable, Sendable {
  let version: String
  let build: String
  let commit: String
  let applicationRoot: URL
  let installRoot: URL
}

struct ContainerPort: Codable, Equatable, Hashable, Sendable, Identifiable {
  let hostAddress: String
  let hostPort: UInt16
  let containerPort: UInt16
  let protocolName: String

  var id: String {
    "\(hostAddress):\(hostPort):\(containerPort):\(protocolName)"
  }
}

struct ContainerRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let imageReference: String
  let imageDigest: String?
  let platform: String
  let state: RuntimeState
  let ipAddress: String?
  let createdAt: Date
  let startedAt: Date?
  let cpuCount: Int
  let memoryBytes: UInt64
  let ports: [ContainerPort]
  let labels: [String: String]

  init(
    id: String,
    imageReference: String,
    imageDigest: String? = nil,
    platform: String,
    state: RuntimeState,
    ipAddress: String?,
    createdAt: Date,
    startedAt: Date?,
    cpuCount: Int,
    memoryBytes: UInt64,
    ports: [ContainerPort],
    labels: [String: String] = [:]
  ) {
    self.id = id
    self.imageReference = imageReference
    self.imageDigest = imageDigest
    self.platform = platform
    self.state = state
    self.ipAddress = ipAddress
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.ports = ports
    self.labels = labels
  }
}

struct ImageRecord: Codable, Equatable, Sendable, Identifiable {
  let reference: String
  let digest: String
  let mediaType: String
  let indexSizeBytes: Int64

  var id: String { reference }
  var inspectionID: String { "\(reference)@\(digest)" }
}

struct VolumeRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let name: String
  let driver: String
  let format: String
  let source: String
  let createdAt: Date
  let sizeBytes: UInt64?
  let allocatedBytes: UInt64?
  let labels: [String: String]
  let options: [String: String]
  let isAnonymous: Bool
  let usedByContainerIDs: [String]

  var configurationIdentity: VolumeConfigurationIdentity {
    VolumeConfigurationIdentity(
      name: name,
      driver: driver,
      format: format,
      source: source,
      createdAt: createdAt,
      labels: labels,
      options: options,
      sizeBytes: sizeBytes
    )
  }
}

struct LinuxMachineRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let imageReference: String
  let platform: String
  let state: RuntimeState
  let ipAddress: String?
  let createdAt: Date?
  let startedAt: Date?
  let diskSizeBytes: UInt64?
  let cpuCount: Int
  let memoryDescription: String
  let isInitialized: Bool
}

struct ContainerInventory: Equatable, Sendable {
  let system: ContainerSystemInfo
  let containers: [ContainerRecord]
  let images: [ImageRecord]
  let volumes: [VolumeRecord]
  let networks: [NetworkRecord]
  let machines: [LinuxMachineRecord]
}

struct ContainerStatistics: Codable, Equatable, Sendable {
  let memoryUsageBytes: UInt64?
  let memoryLimitBytes: UInt64?
  let cpuUsageMicroseconds: UInt64?
  let networkReceivedBytes: UInt64?
  let networkTransmittedBytes: UInt64?
  let blockReadBytes: UInt64?
  let blockWrittenBytes: UInt64?
  let processCount: UInt64?
}

struct ContainerInspection: Equatable, Sendable {
  let diskUsageBytes: UInt64
  let statistics: ContainerStatistics?
  let standardOutput: String
  let bootLog: String
  let logsAreTruncated: Bool
}

struct ContainerLogsSnapshot: Equatable, Sendable {
  let standardOutput: String
  let bootLog: String
  let logsAreTruncated: Bool
}

struct ContainerRuntimeSample: Equatable, Sendable, Identifiable {
  let id: UUID
  let capturedAt: Date
  let statistics: ContainerStatistics
  let cpuPercentage: Double?

  init(
    id: UUID = UUID(),
    capturedAt: Date = Date(),
    statistics: ContainerStatistics,
    cpuPercentage: Double?
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.statistics = statistics
    self.cpuPercentage = cpuPercentage
  }
}
