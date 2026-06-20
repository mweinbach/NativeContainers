import Foundation
import Observation

@MainActor
@Observable
final class ContainerInspectorModel {
  private(set) var inspection: ContainerInspection?
  private(set) var samples: [ContainerRuntimeSample] = []
  private(set) var isLoading = false
  private(set) var errorMessage: String?
  private(set) var lastUpdated: Date?

  let containerID: String
  private let allocatedCPUCount: Int
  private let service: any ContainerManaging
  private let maximumSampleCount = 60

  init(
    containerID: String,
    allocatedCPUCount: Int,
    service: any ContainerManaging
  ) {
    self.containerID = containerID
    self.allocatedCPUCount = max(allocatedCPUCount, 1)
    self.service = service
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      inspection = try await service.inspectContainer(id: containerID)
      if let statistics = inspection?.statistics {
        appendSample(statistics)
      }
      lastUpdated = Date()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func monitor(followLogs: Bool, interval: Duration = .seconds(2)) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        let statistics = try await service.sampleContainer(id: containerID)
        let logs = followLogs ? try await service.loadContainerLogs(id: containerID) : nil
        guard !Task.isCancelled else { return }
        merge(statistics: statistics, logs: logs)
        errorMessage = nil
        lastUpdated = Date()
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func merge(
    statistics: ContainerStatistics?,
    logs: ContainerLogsSnapshot?
  ) {
    guard let inspection else { return }
    if let statistics {
      appendSample(statistics)
    }
    self.inspection = ContainerInspection(
      diskUsageBytes: inspection.diskUsageBytes,
      statistics: statistics,
      standardOutput: logs?.standardOutput ?? inspection.standardOutput,
      bootLog: logs?.bootLog ?? inspection.bootLog,
      logsAreTruncated: logs?.logsAreTruncated ?? inspection.logsAreTruncated
    )
  }

  private func appendSample(_ statistics: ContainerStatistics) {
    let capturedAt = Date()
    let cpuPercentage: Double? = {
      guard
        let previous = samples.last,
        let previousCPU = previous.statistics.cpuUsageMicroseconds,
        let currentCPU = statistics.cpuUsageMicroseconds,
        currentCPU >= previousCPU
      else {
        return nil
      }
      let elapsedMicroseconds = capturedAt.timeIntervalSince(previous.capturedAt) * 1_000_000
      guard elapsedMicroseconds > 0 else { return nil }
      let usedMicroseconds = Double(currentCPU - previousCPU)
      return min(
        max(usedMicroseconds / elapsedMicroseconds / Double(allocatedCPUCount) * 100, 0), 100)
    }()

    samples.append(
      ContainerRuntimeSample(
        capturedAt: capturedAt,
        statistics: statistics,
        cpuPercentage: cpuPercentage
      )
    )
    if samples.count > maximumSampleCount {
      samples.removeFirst(samples.count - maximumSampleCount)
    }
  }
}
