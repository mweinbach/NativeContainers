import Foundation
import Testing

@testable import NativeContainers

struct PerformanceBenchmarkServiceTests {
  @Test
  func runsWarmupAndComputesMedianP95AndThroughput() async throws {
    let scenario = ScriptedPerformanceScenario(
      kind: .privateDiskIO,
      byteCount: 1_048_576
    )
    let clock = SequencePerformanceClock(
      values: [
        0, 1_000_000_000,
        1_000_000_000, 3_000_000_000,
        3_000_000_000, 6_000_000_000,
      ]
    )
    let generatedAt = Date(timeIntervalSince1970: 123)
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 1,
        measuredIterations: 3
      ),
      clock: clock,
      now: { generatedAt }
    )

    let report = try await service.run { _ in }

    #expect(report.generatedAt == generatedAt)
    #expect(await scenario.invocationCount == 4)
    #expect(report.outcomes.count == 1)
    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured disk result.")
      return
    }

    #expect(result.kind == .privateDiskIO)
    #expect(result.medianDurationNanoseconds == 2_000_000_000)
    #expect(result.p95DurationNanoseconds == 3_000_000_000)
    #expect(result.medianDurationMilliseconds == 2_000)
    #expect(result.p95DurationMilliseconds == 3_000)
    #expect(result.throughputMebibytesPerSecond == 0.5)
  }

  @Test
  func isolatesScenarioFailureAndContinuesTheSuite() async throws {
    let failed = ScriptedPerformanceScenario(
      kind: .warmInventory,
      error: FixturePerformanceError.expected
    )
    let succeeding = ScriptedPerformanceScenario(
      kind: .loopbackNetwork,
      byteCount: 4_096
    )
    let service = PerformanceBenchmarkService(
      scenarios: [failed, succeeding],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [100, 200, 300])
    )

    let report = try await service.run { _ in }

    #expect(report.outcomes.count == 2)
    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected the first scenario to fail.")
      return
    }
    #expect(kind == .warmInventory)
    #expect(message == FixturePerformanceError.expected.localizedDescription)

    guard case .measured(let result) = report.outcomes[1] else {
      Issue.record("Expected the second scenario to run after the failure.")
      return
    }
    #expect(result.kind == .loopbackNetwork)
    #expect(await failed.invocationCount == 1)
    #expect(await succeeding.invocationCount == 1)
  }

  @Test
  func propagatesCancellationInsteadOfRecordingAFailure() async {
    let service = PerformanceBenchmarkService(
      scenarios: [CancellingPerformanceScenario()],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    await #expect(throws: CancellationError.self) {
      _ = try await service.run { _ in }
    }
  }

  @Test
  func privateDiskScenarioRemovesItsTemporaryArtifact() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "NativeContainers-PerformanceTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let scenario = PrivateDiskPerformanceBenchmarkScenario(
      workspaceDirectoryURL: directory,
      payloadByteCount: 512 * 1_024
    )

    let byteCount = try #require(await scenario.perform())

    #expect(byteCount == 1_024 * 1_024)
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    #expect(contents.isEmpty)
  }

  @Test
  func loopbackScenarioTransfersTheCompletePayload() async throws {
    let scenario = LoopbackNetworkPerformanceBenchmarkScenario(
      payloadByteCount: 1_048_576,
      timeout: .seconds(5)
    )

    let byteCount = try await scenario.perform()

    #expect(byteCount == 1_048_576)
  }
}

private actor ScriptedPerformanceScenario: PerformanceBenchmarkScenario {
  nonisolated let kind: PerformanceBenchmarkKind

  private let byteCount: Int64?
  private let error: (any Error)?
  private(set) var invocationCount = 0

  init(
    kind: PerformanceBenchmarkKind,
    byteCount: Int64? = nil,
    error: (any Error)? = nil
  ) {
    self.kind = kind
    self.byteCount = byteCount
    self.error = error
  }

  func perform() async throws -> Int64? {
    invocationCount += 1
    if let error {
      throw error
    }
    return byteCount
  }
}

private struct CancellingPerformanceScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.warmInventory

  func perform() async throws -> Int64? {
    throw CancellationError()
  }
}

private final class SequencePerformanceClock:
  @unchecked Sendable,
  PerformanceBenchmarkClock
{
  private let lock = NSLock()
  private var values: [UInt64]

  init(values: [UInt64]) {
    self.values = values
  }

  func nowNanoseconds() -> UInt64 {
    lock.withLock {
      precondition(!values.isEmpty)
      return values.removeFirst()
    }
  }
}

private enum FixturePerformanceError: LocalizedError {
  case expected

  var errorDescription: String? {
    "Expected performance scenario failure."
  }
}
