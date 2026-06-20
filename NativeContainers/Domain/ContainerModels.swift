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
