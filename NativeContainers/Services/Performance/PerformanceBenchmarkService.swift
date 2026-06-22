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

  func perform() async throws -> Int64?
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
            _ = try await scenario.perform()
          }

          var samples: [PerformanceBenchmarkSample] = []
          samples.reserveCapacity(configuration.measuredIterations)

          for _ in 0..<configuration.measuredIterations {
            try Task.checkCancellation()
            let startedAt = clock.nowNanoseconds()
            let byteCount = try await scenario.perform()
            let finishedAt = clock.nowNanoseconds()
            guard finishedAt >= startedAt else {
              throw PerformanceBenchmarkError.nonMonotonicClock
            }
            samples.append(
              PerformanceBenchmarkSample(
                durationNanoseconds: finishedAt - startedAt,
                processedByteCount: byteCount
              )
            )
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
}

enum PerformanceBenchmarkError: LocalizedError, Equatable, Sendable {
  case nonMonotonicClock
  case privateDiskWorkspaceUnavailable
  case privateDiskWriteFailed
  case privateDiskReadFailed
  case loopbackListenerUnavailable
  case loopbackConnectionFailed
  case loopbackTransferIncomplete(expected: Int, actual: Int)
  case loopbackTimedOut

  var errorDescription: String? {
    switch self {
    case .nonMonotonicClock:
      "The benchmark clock moved backward, so the measurement was discarded."
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
