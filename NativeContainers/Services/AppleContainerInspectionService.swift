import ContainerAPIClient
import ContainerResource
import Foundation

actor AppleContainerInspectionService: ContainerInspecting {
  private static let maximumLogBytes = 512 * 1_024

  private let containerClient: ContainerClient

  init(containerClient: ContainerClient = ContainerClient()) {
    self.containerClient = containerClient
  }

  func inspectContainer(id: String) async throws -> ContainerInspection {
    let snapshot = try await containerClient.get(id: id)
    async let diskUsageRequest = containerClient.diskUsage(id: id)
    async let logsRequest = loadContainerLogs(id: id)

    let statistics: ContainerStatistics?
    if snapshot.status == .running {
      statistics = try await loadStatistics(id: id)
    } else {
      statistics = nil
    }

    let (diskUsage, logs) = try await (diskUsageRequest, logsRequest)
    return ContainerInspection(
      diskUsageBytes: diskUsage,
      statistics: statistics,
      standardOutput: logs.standardOutput,
      bootLog: logs.bootLog,
      logsAreTruncated: logs.logsAreTruncated
    )
  }

  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else { return nil }
    return try await loadStatistics(id: id)
  }

  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    let logs = try await readLogs(id: id)
    return ContainerLogsSnapshot(
      standardOutput: logs.standardOutput.text,
      bootLog: logs.boot.text,
      logsAreTruncated: logs.standardOutput.isTruncated || logs.boot.isTruncated
    )
  }

  private func loadStatistics(id: String) async throws -> ContainerStatistics {
    let value = try await containerClient.stats(id: id)
    return ContainerStatistics(
      memoryUsageBytes: value.memoryUsageBytes,
      memoryLimitBytes: value.memoryLimitBytes,
      cpuUsageMicroseconds: value.cpuUsageUsec,
      networkReceivedBytes: value.networkRxBytes,
      networkTransmittedBytes: value.networkTxBytes,
      blockReadBytes: value.blockReadBytes,
      blockWrittenBytes: value.blockWriteBytes,
      processCount: value.numProcesses
    )
  }

  private func readLogs(id: String) async throws -> (
    standardOutput: (text: String, isTruncated: Bool),
    boot: (text: String, isTruncated: Bool)
  ) {
    let handles = try await containerClient.logs(id: id)
    defer {
      for handle in handles {
        try? handle.close()
      }
    }

    guard handles.count >= 2 else {
      return (("", false), ("", false))
    }
    return try (
      Self.readTail(from: handles[0], maximumBytes: Self.maximumLogBytes),
      Self.readTail(from: handles[1], maximumBytes: Self.maximumLogBytes)
    )
  }

  private static func readTail(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (text: String, isTruncated: Bool) {
    let length = try handle.seekToEnd()
    let maximumBytes = UInt64(maximumBytes)
    let isTruncated = length > maximumBytes
    try handle.seek(toOffset: isTruncated ? length - maximumBytes : 0)
    let data = try handle.readToEnd() ?? Data()
    return (String(decoding: data, as: UTF8.self), isTruncated)
  }
}
