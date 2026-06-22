import Foundation
import Testing

@testable import NativeContainers

struct PerformanceBenchmarkServiceTests {
  @Test
  func settingsSuiteExcludesMutatingLiveLanes() {
    #expect(
      PerformanceBenchmarkKind.settingsSuiteCases == [
        .warmInventory,
        .privateDiskIO,
        .loopbackNetwork,
      ]
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .coldContainerStartup
      )
    )
  }

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
    #expect(await scenario.preparationCount == 4)
    #expect(await scenario.invocationCount == 4)
    #expect(await scenario.cleanupCount == 4)
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
    #expect(await failed.preparationCount == 1)
    #expect(await failed.invocationCount == 1)
    #expect(await failed.cleanupCount == 1)
    #expect(await succeeding.preparationCount == 1)
    #expect(await succeeding.invocationCount == 1)
    #expect(await succeeding.cleanupCount == 1)
  }

  @Test
  func propagatesCancellationInsteadOfRecordingAFailure() async {
    let scenario = CancellingPerformanceScenario()
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    await #expect(throws: CancellationError.self) {
      _ = try await service.run { _ in }
    }
    #expect(await scenario.cleanupCount == 1)
  }

  @Test
  func cleansUpAfterPreparationFailureAndRecordsIt() async throws {
    let preparationFailure = ScriptedPerformanceScenario(
      kind: .warmInventory,
      preparationError: FixturePerformanceError.preparation
    )
    let service = PerformanceBenchmarkService(
      scenarios: [preparationFailure],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    let report = try await service.run { _ in }

    guard case .failed(let preparationKind, let preparationMessage) = report.outcomes[0]
    else {
      Issue.record("Expected the preparation failure to be isolated.")
      return
    }
    #expect(preparationKind == .warmInventory)
    #expect(
      preparationMessage == FixturePerformanceError.preparation.localizedDescription
    )
    #expect(await preparationFailure.preparationCount == 1)
    #expect(await preparationFailure.invocationCount == 0)
    #expect(await preparationFailure.cleanupCount == 1)
  }

  @Test
  func cleanupFailureAbortsBeforeAnotherScenarioCanRun() async {
    let cleanupFailure = ScriptedPerformanceScenario(
      kind: .privateDiskIO,
      cleanupError: FixturePerformanceError.cleanup
    )
    let nextScenario = ScriptedPerformanceScenario(kind: .warmInventory)
    let service = PerformanceBenchmarkService(
      scenarios: [cleanupFailure, nextScenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10, 20])
    )
    let expected = PerformanceBenchmarkError.iterationCleanupFailed(
      FixturePerformanceError.cleanup.localizedDescription
    )

    await #expect(throws: expected) {
      _ = try await service.run { _ in }
    }
    #expect(await cleanupFailure.preparationCount == 1)
    #expect(await cleanupFailure.invocationCount == 1)
    #expect(await cleanupFailure.cleanupCount == 1)
    #expect(await nextScenario.preparationCount == 0)
    #expect(await nextScenario.invocationCount == 0)
    #expect(await nextScenario.cleanupCount == 0)
  }

  @Test
  func coldContainerStartupTimesOnlyStartAndRemovesPreparedContainer() async throws {
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let scenario = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      makeContainerID: { "nativecontainers-perf-fixture" }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [100, 250])
    )

    let report = try await service.run { _ in }

    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome
    else {
      Issue.record("Expected a measured cold-container startup result.")
      return
    }
    #expect(result.kind == .coldContainerStartup)
    #expect(result.samples.map(\.durationNanoseconds) == [150])
    let request = await runtime.lastRequest
    #expect(request?.startAfterCreation == false)
    #expect(request?.cpuCount == 1)
    #expect(
      request?.memoryBytes
        == 256 * ContainerCreationRequest.bytesPerMiB
    )
    let remaining = try await runtime.listedObservation(
      forContainerID: "nativecontainers-perf-fixture"
    )
    #expect(remaining == nil)
    #expect(
      await runtime.calls == [
        "create:nativecontainers-perf-fixture",
        "observe:nativecontainers-perf-fixture",
        "start:nativecontainers-perf-fixture",
        "observe:nativecontainers-perf-fixture",
        "observe:nativecontainers-perf-fixture",
        "stop:nativecontainers-perf-fixture",
        "observe:nativecontainers-perf-fixture",
        "observe:nativecontainers-perf-fixture",
        "delete:nativecontainers-perf-fixture",
        "listed:nativecontainers-perf-fixture",
        "listed:nativecontainers-perf-fixture",
      ]
    )
  }

  @Test
  func coldContainerCleanupNeverMutatesSameNameReplacement() async throws {
    let id = "nativecontainers-perf-replacement"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let scenario = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      makeContainerID: { id }
    )
    try await scenario.prepareIteration()
    _ = try await scenario.perform()
    await runtime.replaceCurrentContainer()
    let expected = ColdContainerStartupBenchmarkError.cleanupFailed(
      id: id,
      operation: ColdContainerStartupBenchmarkError.identityChanged(id)
        .localizedDescription,
      recovery: ColdContainerStartupBenchmarkError.replacementPresent(id)
        .localizedDescription
    )

    await #expect(throws: expected) {
      try await scenario.cleanUpIteration()
    }

    let replacement = try await runtime.listedObservation(forContainerID: id)
    #expect(replacement?.state == .running)
    let calls = await runtime.calls
    #expect(!calls.contains("stop:\(id)"))
    #expect(!calls.contains("force-stop:\(id)"))
    #expect(!calls.contains("delete:\(id)"))
  }

  @Test
  func coldContainerStartupRejectsUnexpectedImageAndStillCleansUp() async throws {
    let id = "nativecontainers-perf-image-drift"
    let runtime = ContainerStartupBenchmarkRuntimeDouble(
      createdImageDigest: "sha256:unexpected"
    )
    let scenario = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    let report = try await service.run { _ in }

    guard
      let outcome = report.outcomes.first,
      case .failed(let kind, let message) = outcome
    else {
      Issue.record("Expected image identity drift to reject the benchmark.")
      return
    }
    #expect(kind == .coldContainerStartup)
    #expect(
      message
        == ColdContainerStartupBenchmarkError.imageIdentityChanged(id)
        .localizedDescription
    )
    let remaining = try await runtime.listedObservation(forContainerID: id)
    #expect(remaining == nil)
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

@Suite("Live Apple performance benchmarks", .serialized)
struct LiveApplePerformanceBenchmarkTests {
  private static let outputMarker =
    "__NATIVECONTAINERS_COLD_CONTAINER_BENCHMARK__"

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 with Apple container services running and the selected image already local."
    )
  )
  func measuresPreparedImageColdContainerStartupAndLeavesNoContainer() async throws {
    let service = AppleContainerService()
    let imageReference =
      ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"
      ] ?? "docker.io/library/alpine:3.21"
    let initialInventory = try await service.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }

    let runPrefix =
      "nativecontainers-perf-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: service,
      stateReader: AppleContainerStartupBenchmarkStateReader(),
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 1,
        measuredIterations: 3
      )
    )

    let report: PerformanceBenchmarkReport
    do {
      report = try await benchmark.run { _ in }
    } catch {
      try await requireNoResidualContainers(prefix: runPrefix, service: service)
      throw error
    }
    try await requireNoResidualContainers(prefix: runPrefix, service: service)

    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome
    else {
      if let outcome = report.outcomes.first,
        case .failed(_, let message) = outcome
      {
        Issue.record("Cold-container startup benchmark failed: \(message)")
      } else {
        Issue.record("Cold-container startup benchmark returned no result.")
      }
      return
    }
    #expect(result.kind == .coldContainerStartup)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })

    let output = LiveColdContainerStartupBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.outputMarker)\(json)")
  }

  private func requireNoResidualContainers(
    prefix: String,
    service: AppleContainerService
  ) async throws {
    let residualIDs = try await service.loadInventory().containers
      .map(\.id)
      .filter { $0.hasPrefix(prefix) }
      .sorted()
    guard residualIDs.isEmpty else {
      throw LivePerformanceBenchmarkError.residualContainers(residualIDs)
    }
  }
}

private struct LiveColdContainerStartupBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private enum LivePerformanceBenchmarkError: LocalizedError {
  case missingLocalImage(String)
  case residualContainers([String])

  var errorDescription: String? {
    switch self {
    case .missingLocalImage(let reference):
      "Pull “\(reference)” before running the live performance gate; image pulls are excluded from the startup measurement."
    case .residualContainers(let ids):
      "The live performance gate left benchmark containers behind: \(ids.joined(separator: ", "))."
    }
  }
}

private actor ScriptedPerformanceScenario: PerformanceBenchmarkScenario {
  nonisolated let kind: PerformanceBenchmarkKind

  private let byteCount: Int64?
  private let preparationError: (any Error)?
  private let error: (any Error)?
  private let cleanupError: (any Error)?
  private(set) var preparationCount = 0
  private(set) var invocationCount = 0
  private(set) var cleanupCount = 0

  init(
    kind: PerformanceBenchmarkKind,
    byteCount: Int64? = nil,
    preparationError: (any Error)? = nil,
    error: (any Error)? = nil,
    cleanupError: (any Error)? = nil
  ) {
    self.kind = kind
    self.byteCount = byteCount
    self.preparationError = preparationError
    self.error = error
    self.cleanupError = cleanupError
  }

  func prepareIteration() async throws {
    preparationCount += 1
    if let preparationError {
      throw preparationError
    }
  }

  func perform() async throws -> Int64? {
    invocationCount += 1
    if let error {
      throw error
    }
    return byteCount
  }

  func cleanUpIteration() async throws {
    cleanupCount += 1
    if let cleanupError {
      throw cleanupError
    }
  }
}

private actor CancellingPerformanceScenario: PerformanceBenchmarkScenario {
  nonisolated let kind = PerformanceBenchmarkKind.warmInventory
  private(set) var cleanupCount = 0

  func perform() async throws -> Int64? {
    throw CancellationError()
  }

  func cleanUpIteration() async {
    cleanupCount += 1
  }
}

private actor ContainerStartupBenchmarkRuntimeDouble:
  ContainerCreating,
  ContainerLifecycleManaging,
  ContainerStartupBenchmarkStateReading
{
  private(set) var calls: [String] = []
  private(set) var lastRequest: ContainerCreationRequest?
  private var currentID: String?
  private var state: RuntimeState?
  private var startedAt: Date?
  private var operationID: UUID?
  private var imageReference: String?
  private var imageDigest: String?
  private let createdImageDigest: String

  init(createdImageDigest: String = "sha256:fixture") {
    self.createdImageDigest = createdImageDigest
  }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    calls.append("create:\(request.name)")
    lastRequest = request
    currentID = request.name
    state = .stopped
    startedAt = nil
    operationID = request.operationID
    imageReference = request.imageReference
    imageDigest = createdImageDigest
  }

  func startContainer(id: String) async throws {
    try requireCurrentID(id)
    calls.append("start:\(id)")
    state = .running
    startedAt = Date(timeIntervalSince1970: 123)
  }

  func stopContainer(id: String) async throws {
    try requireCurrentID(id)
    calls.append("stop:\(id)")
    state = .stopped
  }

  func restartContainer(id: String) async throws {
    try await startContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try requireCurrentID(id)
    calls.append("force-stop:\(id)")
    state = .stopped
  }

  func deleteContainer(id: String) async throws {
    try requireCurrentID(id)
    calls.append("delete:\(id)")
    currentID = nil
    state = nil
    startedAt = nil
    operationID = nil
    imageReference = nil
    imageDigest = nil
  }

  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation {
    try requireCurrentID(id)
    calls.append("observe:\(id)")
    guard let state, let imageReference, let imageDigest else {
      throw FixturePerformanceError.missingContainer
    }
    return ContainerStartupBenchmarkObservation(
      state: state,
      startedAt: startedAt,
      operationID: operationID,
      imageReference: imageReference,
      imageDigest: imageDigest
    )
  }

  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation? {
    calls.append("listed:\(id)")
    guard
      currentID == id,
      let state,
      let imageReference,
      let imageDigest
    else {
      return nil
    }
    return ContainerStartupBenchmarkObservation(
      state: state,
      startedAt: startedAt,
      operationID: operationID,
      imageReference: imageReference,
      imageDigest: imageDigest
    )
  }

  func replaceCurrentContainer() {
    guard let currentID else { return }
    calls.append("replace:\(currentID)")
    operationID = UUID()
    state = .running
    startedAt = Date(timeIntervalSince1970: 456)
  }

  private func requireCurrentID(_ id: String) throws {
    guard currentID == id else {
      throw FixturePerformanceError.missingContainer
    }
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
  case preparation
  case cleanup
  case missingContainer

  var errorDescription: String? {
    switch self {
    case .expected:
      "Expected performance scenario failure."
    case .preparation:
      "Expected preparation failure."
    case .cleanup:
      "Expected cleanup failure."
    case .missingContainer:
      "The fixture container is missing."
    }
  }
}
