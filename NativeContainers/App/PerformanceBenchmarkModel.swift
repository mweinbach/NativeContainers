import Foundation
import Observation

@MainActor
@Observable
final class PerformanceBenchmarkModel {
  private(set) var report: PerformanceBenchmarkReport?
  private(set) var currentKind: PerformanceBenchmarkKind?
  private(set) var isRunning = false
  private(set) var errorMessage: String?

  @ObservationIgnored
  private let service: any PerformanceBenchmarking

  @ObservationIgnored
  private var activeTask: Task<Void, Never>?

  init(
    service: any PerformanceBenchmarking,
    initialReport: PerformanceBenchmarkReport? = nil
  ) {
    self.service = service
    report = initialReport
  }

  func start() {
    guard activeTask == nil else { return }

    isRunning = true
    errorMessage = nil
    activeTask = Task { [weak self, service] in
      do {
        let report = try await service.run { [weak self] kind in
          self?.currentKind = kind
        }
        try Task.checkCancellation()
        self?.report = report
      } catch is CancellationError {
        // Cancellation preserves the previous completed report.
      } catch {
        self?.errorMessage = error.localizedDescription
      }

      self?.currentKind = nil
      self?.isRunning = false
      self?.activeTask = nil
    }
  }

  func cancel() {
    activeTask?.cancel()
  }
}
