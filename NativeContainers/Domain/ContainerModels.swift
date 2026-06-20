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
  let platform: String
  let state: RuntimeState
  let ipAddress: String?
  let createdAt: Date
  let startedAt: Date?
  let cpuCount: Int
  let memoryBytes: UInt64
  let ports: [ContainerPort]
}

struct ImageRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let reference: String
  let digest: String
  let mediaType: String
  let compressedSizeBytes: Int64
}

struct VolumeRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let name: String
  let driver: String
  let format: String
  let source: String
  let createdAt: Date
  let sizeBytes: UInt64?
  let isAnonymous: Bool
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
