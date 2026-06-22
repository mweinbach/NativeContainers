import Foundation

struct PerformanceBenchmarkConfiguration: Equatable, Sendable {
  let warmupIterations: Int
  let measuredIterations: Int

  init(warmupIterations: Int = 1, measuredIterations: Int = 3) {
    self.warmupIterations = max(0, warmupIterations)
    self.measuredIterations = max(1, measuredIterations)
  }
}

protocol PerformanceBenchmarkScenario: Sendable {
  var kind: PerformanceBenchmarkKind { get }

  func prepareIteration() async throws
  func prepareMeasurement() async throws
  func perform() async throws -> Int64?
  func cleanUpIteration() async throws
}

extension PerformanceBenchmarkScenario {
  func prepareIteration() async throws {}
  func prepareMeasurement() async throws {}
  func cleanUpIteration() async throws {}
}

protocol PerformanceBenchmarkClock: Sendable {
  func nowNanoseconds() -> UInt64
}

struct ContinuousPerformanceBenchmarkClock: PerformanceBenchmarkClock {
  func nowNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }
}

struct PerformanceBenchmarkService: PerformanceBenchmarking {
  private let scenarios: [any PerformanceBenchmarkScenario]
  private let configuration: PerformanceBenchmarkConfiguration
  private let clock: any PerformanceBenchmarkClock
  private let now: @Sendable () -> Date

  init(
    scenarios: [any PerformanceBenchmarkScenario],
    configuration: PerformanceBenchmarkConfiguration = PerformanceBenchmarkConfiguration(),
    clock: any PerformanceBenchmarkClock = ContinuousPerformanceBenchmarkClock(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.scenarios = scenarios
    self.configuration = configuration
    self.clock = clock
    self.now = now
  }

  func run(
    progress: @escaping PerformanceBenchmarkProgressHandler
  ) async throws -> PerformanceBenchmarkReport {
    var outcomes: [PerformanceBenchmarkOutcome] = []
    outcomes.reserveCapacity(scenarios.count)

    do {
      for scenario in scenarios {
        try Task.checkCancellation()
        await progress(scenario.kind)

        do {
          for _ in 0..<configuration.warmupIterations {
            try Task.checkCancellation()
            _ = try await runIteration(
              scenario,
              recordsMeasurement: false
            )
          }

          var samples: [PerformanceBenchmarkSample] = []
          samples.reserveCapacity(configuration.measuredIterations)

          for _ in 0..<configuration.measuredIterations {
            try Task.checkCancellation()
            guard
              let sample = try await runIteration(
                scenario,
                recordsMeasurement: true
              )
            else {
              throw PerformanceBenchmarkError.missingMeasurement
            }
            samples.append(sample)
          }

          outcomes.append(
            .measured(
              PerformanceBenchmarkResult(
                kind: scenario.kind,
                samples: samples
              )
            )
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          if Task.isCancelled
            || (error as? PerformanceBenchmarkError)?.requiresSuiteAbort
              == true
          {
            throw error
          }
          outcomes.append(
            .failed(
              kind: scenario.kind,
              message: error.localizedDescription
            )
          )
        }
      }
    } catch {
      await progress(nil)
      throw error
    }

    await progress(nil)
    return PerformanceBenchmarkReport(
      generatedAt: now(),
      outcomes: outcomes
    )
  }

  private func runIteration(
    _ scenario: any PerformanceBenchmarkScenario,
    recordsMeasurement: Bool
  ) async throws -> PerformanceBenchmarkSample? {
    var operationResult: Result<PerformanceBenchmarkSample?, any Error>
    do {
      try await scenario.prepareIteration()
      try Task.checkCancellation()
      try await scenario.prepareMeasurement()
      try Task.checkCancellation()

      let startedAt = recordsMeasurement ? clock.nowNanoseconds() : nil
      let byteCount = try await scenario.perform()
      let finishedAt = recordsMeasurement ? clock.nowNanoseconds() : nil
      if let startedAt, let finishedAt {
        guard finishedAt >= startedAt else {
          throw PerformanceBenchmarkError.nonMonotonicClock
        }
        operationResult = .success(
          PerformanceBenchmarkSample(
            durationNanoseconds: finishedAt - startedAt,
            processedByteCount: byteCount
          )
        )
      } else {
        operationResult = .success(nil)
      }
    } catch {
      operationResult = .failure(error)
    }

    let cleanupErrorDescription = await Task.detached {
      do {
        try await scenario.cleanUpIteration()
        return nil as String?
      } catch {
        return error.localizedDescription
      }
    }.value

    switch (operationResult, cleanupErrorDescription) {
    case (.success(let sample), nil):
      return sample
    case (.success, .some(let cleanup)):
      throw PerformanceBenchmarkError.iterationCleanupFailed(cleanup)
    case (.failure(let operation), nil):
      throw operation
    case (.failure(let operation), .some(let cleanup)):
      throw PerformanceBenchmarkError.iterationAndCleanupFailed(
        operation: operation.localizedDescription,
        cleanup: cleanup
      )
    }
  }
}

enum PerformanceBenchmarkError: LocalizedError, Equatable, Sendable {
  case nonMonotonicClock
  case missingMeasurement
  case iterationCleanupFailed(String)
  case iterationAndCleanupFailed(operation: String, cleanup: String)
  case privateDiskWorkspaceUnavailable
  case privateDiskWriteFailed
  case privateDiskReadFailed
  case loopbackListenerUnavailable
  case loopbackConnectionFailed
  case loopbackTransferIncomplete(expected: Int, actual: Int)
  case loopbackTimedOut

  var requiresSuiteAbort: Bool {
    switch self {
    case .iterationCleanupFailed, .iterationAndCleanupFailed:
      true
    case .nonMonotonicClock, .missingMeasurement, .privateDiskWorkspaceUnavailable,
      .privateDiskWriteFailed, .privateDiskReadFailed, .loopbackListenerUnavailable,
      .loopbackConnectionFailed, .loopbackTransferIncomplete, .loopbackTimedOut:
      false
    }
  }

  var errorDescription: String? {
    switch self {
    case .nonMonotonicClock:
      "The benchmark clock moved backward, so the measurement was discarded."
    case .missingMeasurement:
      "The benchmark iteration completed without a measurement."
    case .iterationCleanupFailed(let cleanup):
      "The benchmark iteration completed, but cleanup failed: \(cleanup)"
    case .iterationAndCleanupFailed(let operation, let cleanup):
      "The benchmark iteration failed: \(operation) Cleanup also failed: \(cleanup)"
    case .privateDiskWorkspaceUnavailable:
      "The private benchmark workspace could not be prepared."
    case .privateDiskWriteFailed:
      "The private disk benchmark could not write and synchronize its temporary file."
    case .privateDiskReadFailed:
      "The private disk benchmark could not read back its complete temporary file."
    case .loopbackListenerUnavailable:
      "Network.framework could not create a local TCP listener."
    case .loopbackConnectionFailed:
      "The local Network.framework TCP connection failed."
    case .loopbackTransferIncomplete(let expected, let actual):
      "The loopback benchmark received \(actual) of \(expected) bytes."
    case .loopbackTimedOut:
      "The loopback benchmark did not finish within its bounded deadline."
    }
  }
}
