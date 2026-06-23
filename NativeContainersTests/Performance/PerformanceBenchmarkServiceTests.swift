import ContainerAPIClient
import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct PerformanceBenchmarkServiceTests {
  @Test
  func productContractPublishesImplementedPerformanceRequirements() {
    let requirements = PerformanceBenchmarkContractRequirement.allCases

    #expect(requirements.count == 8)
    #expect(requirements.count(where: { $0.coverage == .complete }) == 8)
    #expect(requirements.count(where: { $0.coverage == .partial }) == 0)
    #expect(requirements.count(where: { $0.coverage == .missing }) == 0)
    #expect(requirements.contains(.postgreSQLDurability))
    #expect(requirements.contains(.recovery))
  }

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
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .coldMacVirtualMachineStartup
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .externalNetworkTransfer
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .idleContainerResources
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .idleContainerDensity50
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .hostSleepWakeRecovery
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .appProcessCrashRecovery
      )
    )
    #expect(
      !PerformanceBenchmarkKind.settingsSuiteCases.contains(
        .runtimeCrashRecovery
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
    #expect(await scenario.measurementPreparationCount == 4)
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
    #expect(await failed.measurementPreparationCount == 1)
    #expect(await failed.invocationCount == 1)
    #expect(await failed.cleanupCount == 1)
    #expect(await succeeding.preparationCount == 1)
    #expect(await succeeding.measurementPreparationCount == 1)
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
    #expect(await preparationFailure.measurementPreparationCount == 0)
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
    #expect(await cleanupFailure.measurementPreparationCount == 1)
    #expect(await cleanupFailure.invocationCount == 1)
    #expect(await cleanupFailure.cleanupCount == 1)
    #expect(await nextScenario.preparationCount == 0)
    #expect(await nextScenario.measurementPreparationCount == 0)
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
  func warmContainerStartupTimesRestartAfterAnUntimedStartStopCycle() async throws {
    let id = "nativecontainers-warm-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let scenario = WarmContainerStartupPerformanceBenchmarkScenario(
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
      ),
      clock: SequencePerformanceClock(values: [500, 725])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured warm-container startup result.")
      return
    }
    #expect(result.kind == .warmContainerStartup)
    #expect(result.samples.map(\.durationNanoseconds) == [225])
    let calls = await runtime.calls
    #expect(calls.filter { $0 == "start:\(id)" }.count == 2)
    #expect(calls.filter { $0 == "stop:\(id)" }.count == 2)
    #expect(calls.contains("delete:\(id)"))
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
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
    try await scenario.prepareMeasurement()
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
  func coldLinuxMachineStartupTimesReadinessAndDeletesPreparedMachine() async throws {
    let id = "nativecontainers-vm-fixture"
    let runtime = LinuxMachineStartupBenchmarkRuntimeDouble()
    let scenario = ColdLinuxMachineStartupPerformanceBenchmarkScenario(
      machines: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:machine",
      expectedImageDigest: "sha256:machine-fixture",
      makeMachineID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 9_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured cold Linux-machine startup result.")
      return
    }
    #expect(result.kind == .coldLinuxMachineStartup)
    #expect(result.samples.map(\.durationNanoseconds) == [8_000])
    let request = try #require(await runtime.lastRequest)
    #expect(request.startAfterCreation == false)
    #expect(request.architecture == .arm64)
    #expect(request.cpuCount == 1)
    #expect(request.memoryBytes == LinuxMachineCreationRequest.minimumMemoryBytes)
    #expect(request.homeMount == LinuxMachineHomeMount.none)
    #expect(await runtime.currentMachine() == nil)
    #expect(
      await runtime.calls == [
        "create:\(id)",
        "snapshot:\(id)",
        "snapshot:\(id)",
        "start:\(id)",
        "snapshot:\(id)",
        "snapshot:\(id)",
        "stop:\(id)",
        "snapshot:\(id)",
        "delete:\(id)",
        "snapshot:\(id)",
      ]
    )
  }

  @Test
  func coldLinuxMachineCleanupNeverMutatesSameNameReplacement() async throws {
    let id = "nativecontainers-vm-replacement"
    let runtime = LinuxMachineStartupBenchmarkRuntimeDouble()
    let scenario = ColdLinuxMachineStartupPerformanceBenchmarkScenario(
      machines: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:machine",
      expectedImageDigest: "sha256:machine-fixture",
      makeMachineID: { id }
    )
    try await scenario.prepareIteration()
    try await scenario.prepareMeasurement()
    _ = try await scenario.perform()
    await runtime.replaceCurrentMachine()

    await #expect(
      throws: ColdLinuxMachineStartupBenchmarkError.identityChanged(id)
    ) {
      try await scenario.cleanUpIteration()
    }

    #expect(await runtime.currentMachine()?.state == .running)
    let calls = await runtime.calls
    #expect(!calls.contains("stop:\(id)"))
    #expect(!calls.contains("force-stop:\(id)"))
    #expect(!calls.contains("delete:\(id)"))
  }

  @Test
  func coldLinuxMachineRejectsUnexpectedDigestAndStillCleansUp() async throws {
    let id = "nativecontainers-vm-digest-drift"
    let runtime = LinuxMachineStartupBenchmarkRuntimeDouble(
      imageDigest: "sha256:unexpected"
    )
    let scenario = ColdLinuxMachineStartupPerformanceBenchmarkScenario(
      machines: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:machine",
      expectedImageDigest: "sha256:machine-fixture",
      makeMachineID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected machine image drift to reject the benchmark.")
      return
    }
    #expect(kind == .coldLinuxMachineStartup)
    #expect(
      message
        == ColdLinuxMachineStartupBenchmarkError.imageIdentityChanged(id)
        .localizedDescription
    )
    #expect(await runtime.currentMachine() == nil)
  }

  @Test
  func coldLinuxMachineCleanupFallsBackToAuthorizedForceStop() async throws {
    let id = "nativecontainers-vm-force-cleanup"
    let runtime = LinuxMachineStartupBenchmarkRuntimeDouble(stopFails: true)
    let scenario = ColdLinuxMachineStartupPerformanceBenchmarkScenario(
      machines: runtime,
      stateReader: runtime,
      imageReference: "example.invalid/local:machine",
      expectedImageDigest: "sha256:machine-fixture",
      makeMachineID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10, 20])
    )

    let report = try await service.run { _ in }

    guard case .measured = report.outcomes[0] else {
      Issue.record("Expected force-cleanup recovery to preserve the sample.")
      return
    }
    #expect(await runtime.calls.contains("force-stop:\(id)"))
    #expect(await runtime.currentMachine() == nil)
  }

  @Test
  func coldMacVirtualMachineStartupTimesRunningConsoleAndDeletesClone() async throws {
    let source = try makeMacVirtualMachinePerformanceSource()
    let cloneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
    let library = MacVirtualMachineStartupBenchmarkLibraryDouble(
      source: source,
      cloneID: cloneID
    )
    let runtime = MacVirtualMachineStartupBenchmarkRuntimeDouble()
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: library,
      discarder: library,
      runtime: runtime,
      makeCloneName: { "Performance Clone" }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 9_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured cold macOS virtual-machine startup result.")
      return
    }
    #expect(result.kind == .coldMacVirtualMachineStartup)
    #expect(result.samples.map(\.durationNanoseconds) == [8_000])
    #expect(await library.currentClone() == nil)
    #expect(await library.currentSource() == source)
    #expect(
      await runtime.calls == [
        "refresh:\(cloneID.uuidString)",
        "snapshot:\(cloneID.uuidString)",
        "start:\(cloneID.uuidString)",
        "snapshot:\(cloneID.uuidString)",
        "console:\(cloneID.uuidString)",
        "snapshot:\(cloneID.uuidString)",
        "request-stop:\(cloneID.uuidString)",
        "snapshot:\(cloneID.uuidString)",
      ]
    )
  }

  @Test
  func coldMacVirtualMachineCleanupNeverMutatesChangedClone() async throws {
    let source = try makeMacVirtualMachinePerformanceSource()
    let cloneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
    let library = MacVirtualMachineStartupBenchmarkLibraryDouble(
      source: source,
      cloneID: cloneID
    )
    let runtime = MacVirtualMachineStartupBenchmarkRuntimeDouble()
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: library,
      discarder: library,
      runtime: runtime,
      makeCloneName: { "Performance Clone" }
    )
    try await scenario.prepareIteration()
    try await scenario.prepareMeasurement()
    _ = try await scenario.perform()
    await library.replaceClone()

    await #expect(
      throws: ColdMacVirtualMachineStartupBenchmarkError.cloneIdentityChanged(
        cloneID
      )
    ) {
      try await scenario.cleanUpIteration()
    }

    #expect(await library.currentClone() != nil)
    let runtimeCalls = await runtime.calls
    let libraryCalls = await library.calls
    #expect(!runtimeCalls.contains("request-stop:\(cloneID.uuidString)"))
    #expect(!runtimeCalls.contains("force-stop:\(cloneID.uuidString)"))
    #expect(!libraryCalls.contains("discard:\(cloneID.uuidString)"))
  }

  @Test
  func coldMacVirtualMachineRejectsMissingConsoleAndStillCleansUp() async throws {
    let source = try makeMacVirtualMachinePerformanceSource()
    let cloneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!
    let library = MacVirtualMachineStartupBenchmarkLibraryDouble(
      source: source,
      cloneID: cloneID
    )
    let runtime = MacVirtualMachineStartupBenchmarkRuntimeDouble(hasConsole: false)
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: library,
      discarder: library,
      runtime: runtime,
      makeCloneName: { "Performance Clone" }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 9_000])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected missing macOS VM console readiness to fail the sample.")
      return
    }
    #expect(kind == .coldMacVirtualMachineStartup)
    #expect(
      message
        == ColdMacVirtualMachineStartupBenchmarkError.consoleNotReady(cloneID)
        .localizedDescription
    )
    #expect(await library.currentClone() == nil)
  }

  @Test
  func coldMacVirtualMachineCleanupFallsBackToExactGenerationForceStop() async throws {
    let source = try makeMacVirtualMachinePerformanceSource()
    let cloneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c4")!
    let library = MacVirtualMachineStartupBenchmarkLibraryDouble(
      source: source,
      cloneID: cloneID
    )
    let runtime = MacVirtualMachineStartupBenchmarkRuntimeDouble(
      requestStopFails: true
    )
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: library,
      discarder: library,
      runtime: runtime,
      makeCloneName: { "Performance Clone" }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10, 20])
    )

    let report = try await service.run { _ in }

    guard case .measured = report.outcomes[0] else {
      Issue.record("Expected force-stop cleanup to preserve the macOS VM sample.")
      return
    }
    #expect(await runtime.calls.contains("force-stop:\(cloneID.uuidString)"))
    #expect(await library.currentClone() == nil)
  }

  @Test
  func coldMacVirtualMachineRejectsSourceBeforeCompletedFirstBoot() async throws {
    var source = try makeMacVirtualMachinePerformanceSource()
    source.macOSFirstBootState = .pending
    let cloneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c5")!
    let library = MacVirtualMachineStartupBenchmarkLibraryDouble(
      source: source,
      cloneID: cloneID
    )
    let runtime = MacVirtualMachineStartupBenchmarkRuntimeDouble()
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: library,
      discarder: library,
      runtime: runtime
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected an unfinished source VM to fail before cloning.")
      return
    }
    #expect(kind == .coldMacVirtualMachineStartup)
    #expect(
      message
        == ColdMacVirtualMachineStartupBenchmarkError.sourceNotReady(source.id)
        .localizedDescription
    )
    #expect(await library.currentClone() == nil)
    #expect(await runtime.calls.isEmpty)
  }

  @Test
  func guestRootIOUsesFixedBoundedWorkloadAndCleansUpContainer() async throws {
    let id = "nativecontainers-io-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ContainerIOCommandRuntimeDouble()
    let scenario = try ContainerIOPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      storage: .guestRoot,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      payloadMebibytes: 8,
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 2_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured guest-root I/O result.")
      return
    }
    #expect(result.kind == .guestRootFileIO)
    #expect(result.samples.map(\.durationNanoseconds) == [1_000])
    #expect(result.samples.map(\.processedByteCount) == [16 * 1_048_576])
    let request = try #require(await commands.requests.first)
    #expect(request.executable == "/bin/sh")
    #expect(request.arguments.first == "-c")
    #expect(request.arguments.dropFirst().first?.contains("conv=fsync") == true)
    #expect(request.arguments.dropFirst().first?.contains("trap cleanup") == true)
    #expect(request.arguments.contains("/tmp/nativecontainers-performance.bin"))
    #expect(request.arguments.last == "8")
    #expect(request.timeoutSeconds == 180)
    #expect(await commands.containerIDs == [id])
    let remaining = try await runtime.listedObservation(forContainerID: id)
    #expect(remaining == nil)
  }

  @Test
  func bindMountIORequiresReviewedWritableWorkspace() async {
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ContainerIOCommandRuntimeDouble()

    #expect(
      throws: ContainerIOPerformanceBenchmarkError.missingWritableBindMount
    ) {
      _ = try ContainerIOPerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        commands: commands,
        storage: .bindMount,
        imageReference: "example.invalid/local:benchmark",
        expectedImageDigest: "sha256:fixture"
      )
    }
  }

  @Test
  func bindMountIOCarriesReviewedWritableMountIntoPreparedContainer() async throws {
    let id = "nativecontainers-io-bind-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ContainerIOCommandRuntimeDouble()
    let mount = try ContainerHostDirectoryMount(
      bookmarkData: Data([0x01]),
      lastKnownPath: "/private/tmp/nativecontainers-bind-fixture",
      sourceIdentity: ContainerHostDirectorySourceIdentity(device: 1, inode: 2),
      containerPath: "/workspace",
      isReadOnly: false
    )
    let attachments = try ContainerAttachmentSelection(
      volumeMounts: [],
      hostDirectoryMounts: [mount],
      networks: [],
      publishedSockets: [],
      requiredHostAccess: nil
    )
    let scenario = try ContainerIOPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      storage: .bindMount,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      attachments: attachments,
      payloadMebibytes: 4,
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10, 30])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured bind-mount I/O result.")
      return
    }
    #expect(result.kind == .bindMountFileIO)
    #expect(result.samples.map(\.processedByteCount) == [8 * 1_048_576])
    let creationRequest = await runtime.lastRequest
    #expect(creationRequest?.attachments.hostDirectoryMounts == [mount])
    let request = try #require(await commands.requests.first)
    #expect(request.arguments.contains("/workspace/nativecontainers-performance.bin"))
    #expect(await commands.containerIDs == [id])
    let remaining = try await runtime.listedObservation(forContainerID: id)
    #expect(remaining == nil)
  }

  @Test
  func bindMountMetadataRunsEveryReviewedOperationAndCleansHostPath() async throws {
    let id = "nativecontainers-metadata-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = FixedContainerCommandRuntimeDouble(
      standardOutput: "operations=28\nnativecontainers-metadata-ok\n"
    )
    let mount = try ContainerHostDirectoryMount(
      bookmarkData: Data([0x01]),
      lastKnownPath: "/private/tmp/nativecontainers-metadata-fixture",
      sourceIdentity: ContainerHostDirectorySourceIdentity(device: 1, inode: 3),
      containerPath: "/workspace",
      isReadOnly: false
    )
    let attachments = try ContainerAttachmentSelection(
      volumeMounts: [],
      hostDirectoryMounts: [mount],
      networks: [],
      publishedSockets: [],
      requiredHostAccess: nil
    )
    let scenario = try BindMountMetadataPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      attachments: attachments,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      batches: 4,
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10, 20])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured bind-mount metadata result.")
      return
    }
    #expect(result.kind == .bindMountMetadata)
    #expect(
      await scenario.observations() == [
        BindMountMetadataObservation(
          batches: 4,
          operationsPerBatch: 7,
          totalOperations: 28
        )
      ]
    )
    let request = try #require(await commands.requests.first)
    let workload = try #require(request.arguments.dropFirst().first)
    for operation in ["stat", "chmod", "mv", "rm", "mkdir", "rmdir"] {
      #expect(workload.contains(operation))
    }
    #expect(workload.contains("trap cleanup"))
    #expect(await runtime.lastRequest?.attachments.hostDirectoryMounts == [mount])
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func postgreSQLDurabilityVerifiesFsyncCommitsAndCheckpoint() async throws {
    let id = "nativecontainers-postgres-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = PostgreSQLCommandRuntimeDouble(
      readinessExitCodes: [1, 0],
      verificationOutput: "on|on|32\n"
    )
    let sleeper = IdleResourceSleepDouble()
    let scenario = try PostgreSQLDurabilityPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      imageReference: "example.invalid/postgres:17",
      expectedImageDigest: "sha256:fixture",
      rowCount: 32,
      readinessAttempts: 3,
      readinessDelay: .milliseconds(10),
      makeContainerID: { id },
      sleep: { duration in await sleeper.sleep(for: duration) }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [100, 300])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured PostgreSQL durability result.")
      return
    }
    #expect(result.kind == .postgreSQLDurability)
    #expect(result.samples.map(\.processedByteCount) == [32 * 1_024])
    #expect(
      await scenario.observations() == [
        PostgreSQLDurabilityObservation(
          fsyncEnabled: true,
          synchronousCommitEnabled: true,
          pgTestFsyncCompleted: true,
          committedRowCount: 32,
          committedPayloadBytes: 32 * 1_024
        )
      ]
    )
    let creation = try #require(await runtime.lastRequest)
    #expect(creation.arguments.isEmpty)
    #expect(creation.memoryBytes == 512 * ContainerCreationRequest.bytesPerMiB)
    #expect(
      creation.environment.contains(where: {
        $0.key == "POSTGRES_HOST_AUTH_METHOD" && $0.value == "trust"
      })
    )
    let requests = await commands.requests
    #expect(requests.map(\.executable).contains("/usr/local/bin/pg_test_fsync"))
    let psql = try #require(
      requests.first(where: { $0.executable == "/usr/local/bin/psql" })
    )
    let sql = try #require(psql.arguments.last)
    #expect(sql.contains("CHECKPOINT"))
    #expect(sql.contains("current_setting('fsync')"))
    #expect(sql.contains("current_setting('synchronous_commit')"))
    #expect(await sleeper.durations == [.milliseconds(10)])
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func externalNetworkTransferVerifiesFixedPayloadAndDeletesContainer() async throws {
    let id = "nativecontainers-network-fixture"
    let digest = String(repeating: "a", count: 64)
    let byteCount: Int64 = 8 * 1_048_576
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ExternalNetworkCommandRuntimeDouble(
      standardOutput:
        "bytes=\(byteCount)\nsha256=\(digest)\nnativecontainers-network-ok\n"
    )
    let endpoint = try #require(
      URL(string: "https://fixtures.example.com/nativecontainers/payload.bin?run=fixed")
    )
    let scenario = try ExternalNetworkPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      endpoint: endpoint,
      expectedByteCount: byteCount,
      expectedSHA256: digest,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 9_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured external-network result.")
      return
    }
    #expect(result.kind == .externalNetworkTransfer)
    #expect(result.samples.map(\.durationNanoseconds) == [8_000])
    #expect(result.samples.map(\.processedByteCount) == [byteCount])
    let request = try #require(await commands.requests.first)
    #expect(request.executable == "/bin/sh")
    #expect(request.arguments.first == "-c")
    #expect(request.arguments.dropFirst().first?.contains("wget -q -T 180") == true)
    #expect(
      request.arguments.dropFirst().first?.contains("Cache-Control: no-cache") == true
    )
    #expect(request.arguments.dropFirst().first?.contains("sha256sum") == true)
    #expect(request.arguments.dropFirst().first?.contains("trap cleanup") == true)
    #expect(request.arguments.contains(endpoint.absoluteString))
    #expect(request.arguments.contains("/tmp/nativecontainers-external-network.bin"))
    #expect(request.timeoutSeconds == 300)
    #expect(await commands.containerIDs == [id])
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func externalNetworkTransferRejectsUnsafeOrUnboundedFixture() async throws {
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ExternalNetworkCommandRuntimeDouble(standardOutput: "")
    let digest = String(repeating: "a", count: 64)
    let localEndpoint = try #require(URL(string: "https://127.0.0.1/payload"))
    let plainEndpoint = try #require(URL(string: "http://fixtures.example.com/payload"))
    let publicEndpoint = try #require(
      URL(string: "https://fixtures.example.com/payload")
    )

    #expect(throws: ExternalNetworkPerformanceBenchmarkError.invalidEndpoint) {
      _ = try ExternalNetworkPerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        commands: commands,
        endpoint: localEndpoint,
        expectedByteCount: 1_048_576,
        expectedSHA256: digest,
        expectedImageDigest: "sha256:fixture"
      )
    }
    #expect(throws: ExternalNetworkPerformanceBenchmarkError.invalidEndpoint) {
      _ = try ExternalNetworkPerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        commands: commands,
        endpoint: plainEndpoint,
        expectedByteCount: 1_048_576,
        expectedSHA256: digest,
        expectedImageDigest: "sha256:fixture"
      )
    }
    #expect(
      throws: ExternalNetworkPerformanceBenchmarkError.invalidExpectedByteCount
    ) {
      _ = try ExternalNetworkPerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        commands: commands,
        endpoint: publicEndpoint,
        expectedByteCount: 0,
        expectedSHA256: digest,
        expectedImageDigest: "sha256:fixture"
      )
    }
    #expect(throws: ExternalNetworkPerformanceBenchmarkError.invalidExpectedDigest) {
      _ = try ExternalNetworkPerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        commands: commands,
        endpoint: publicEndpoint,
        expectedByteCount: 1_048_576,
        expectedSHA256: String(repeating: "A", count: 64),
        expectedImageDigest: "sha256:fixture"
      )
    }
  }

  @Test
  func externalNetworkTransferRejectsPayloadDriftAndStillCleansUp() async throws {
    let id = "nativecontainers-network-drift"
    let digest = String(repeating: "b", count: 64)
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = ExternalNetworkCommandRuntimeDouble(
      standardOutput:
        "bytes=1048577\nsha256=\(digest)\nnativecontainers-network-ok\n"
    )
    let endpoint = try #require(URL(string: "https://fixtures.example.com/payload"))
    let scenario = try ExternalNetworkPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      endpoint: endpoint,
      expectedByteCount: 1_048_576,
      expectedSHA256: digest,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected external payload drift to fail.")
      return
    }
    #expect(kind == .externalNetworkTransfer)
    #expect(
      message
        == ExternalNetworkPerformanceBenchmarkError.byteCountMismatch(
          expected: 1_048_576,
          actual: 1_048_577
        ).localizedDescription
    )
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func natDirectNetworkComparesSamePayloadOverBothRoutes() async throws {
    let id = "nativecontainers-network-compare-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble(
      containerIPAddress: "192.0.2.44/24"
    )
    let commands = FixedContainerCommandRuntimeDouble(
      standardOutput: "bytes=16\nnativecontainers-http-server-ok\n"
    )
    let transport = PerformanceHTTPTransportDouble(
      payload: Data(repeating: 0, count: 16)
    )
    let routeClock = SequencePerformanceClock(
      values: [0, 10, 10, 30, 30, 50, 50, 60]
    )
    let scenario = try NATDirectNetworkPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      inventory: runtime,
      commands: commands,
      hostPort: 38_080,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      payloadByteCount: 16,
      requestCount: 2,
      readinessAttempts: 1,
      readinessDelay: .milliseconds(10),
      transport: transport,
      clock: routeClock,
      makeContainerID: { id }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [100, 200])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured NAT/direct-IP comparison.")
      return
    }
    #expect(result.kind == .natDirectNetworkComparison)
    #expect(result.samples.map(\.processedByteCount) == [64])
    let observation = try #require(await scenario.observations().first)
    #expect(observation.publishedHost == "127.0.0.1")
    #expect(observation.publishedPort == 38_080)
    #expect(observation.directHost == "192.0.2.44")
    #expect(observation.containerPort == 8_080)
    #expect(observation.requestCountPerRoute == 2)
    #expect(observation.publishedRoute.samplesNanoseconds == [10, 10])
    #expect(observation.directRoute.samplesNanoseconds == [20, 20])
    #expect(observation.publishedRoute.medianLatencyNanoseconds == 10)
    #expect(observation.directRoute.p95LatencyNanoseconds == 20)
    let publication = try #require(await runtime.lastRequest?.publishedPorts.first)
    #expect(publication.hostAddress == "127.0.0.1")
    #expect(publication.hostPort == 38_080)
    #expect(publication.containerPort == 8_080)
    let fetchedURLs = await transport.urls
    #expect(fetchedURLs.count == 6)
    #expect(fetchedURLs.contains(where: { $0.host == "127.0.0.1" }))
    #expect(fetchedURLs.contains(where: { $0.host == "192.0.2.44" }))
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func idleContainerResourcesSamplesCounterDeltasAndDeletesContainer() async throws {
    let id = "nativecontainers-idle-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let statistics = IdleContainerStatisticsRuntimeDouble(
      samples: [
        idleContainerStatistics(
          memoryUsageBytes: 20 * 1_048_576,
          cpuUsageMicroseconds: 1_000,
          networkReceivedBytes: 100,
          networkTransmittedBytes: 200,
          blockReadBytes: 300,
          blockWrittenBytes: 400,
          processCount: 2
        ),
        idleContainerStatistics(
          memoryUsageBytes: 21 * 1_048_576,
          cpuUsageMicroseconds: 2_500,
          networkReceivedBytes: 110,
          networkTransmittedBytes: 220,
          blockReadBytes: 330,
          blockWrittenBytes: 440,
          processCount: 2
        ),
      ]
    )
    let sleeper = IdleResourceSleepDouble()
    let scenario = try IdleContainerResourcePerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      statistics: statistics,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      settlingDuration: .seconds(2),
      samplingDuration: .seconds(10),
      makeContainerID: { id },
      sleep: { duration in await sleeper.sleep(for: duration) }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [0, 10_000_000_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured idle-resource result.")
      return
    }
    #expect(result.kind == .idleContainerResources)
    #expect(result.samples.map(\.durationNanoseconds) == [10_000_000_000])
    #expect(
      await scenario.observations() == [
        IdleContainerResourceObservation(
          initialMemoryUsageBytes: 20 * 1_048_576,
          finalMemoryUsageBytes: 21 * 1_048_576,
          memoryLimitBytes: 256 * 1_048_576,
          cpuUsageDeltaMicroseconds: 1_500,
          networkReceivedDeltaBytes: 10,
          networkTransmittedDeltaBytes: 20,
          blockReadDeltaBytes: 30,
          blockWrittenDeltaBytes: 40,
          processCount: 2
        )
      ]
    )
    #expect(await statistics.containerIDs == [id, id])
    #expect(await sleeper.durations == [.seconds(2), .seconds(10)])
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func idleContainerResourcesRejectsCounterRegressionAndStillCleansUp() async throws {
    let id = "nativecontainers-idle-regression"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let statistics = IdleContainerStatisticsRuntimeDouble(
      samples: [
        idleContainerStatistics(cpuUsageMicroseconds: 2_000),
        idleContainerStatistics(cpuUsageMicroseconds: 1_999),
      ]
    )
    let scenario = try IdleContainerResourcePerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      statistics: statistics,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      settlingDuration: .zero,
      samplingDuration: .seconds(1),
      makeContainerID: { id },
      sleep: { _ in }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected a regressed idle CPU counter to fail.")
      return
    }
    #expect(kind == .idleContainerResources)
    #expect(
      message
        == IdleContainerResourceBenchmarkError.counterRegressed("CPU")
        .localizedDescription
    )
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func idleContainerResourcesRejectsUnboundedSamplingWindow() async {
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let statistics = IdleContainerStatisticsRuntimeDouble(samples: [])

    #expect(throws: IdleContainerResourceBenchmarkError.invalidSamplingDuration) {
      _ = try IdleContainerResourcePerformanceBenchmarkScenario(
        containers: runtime,
        stateReader: runtime,
        statistics: statistics,
        expectedImageDigest: "sha256:fixture",
        samplingDuration: .zero
      )
    }
  }

  @Test
  func idleContainerDensityMeasuresExactTenAndFiftyContainerSets() async throws {
    for density in IdleContainerDensity.allCases {
      let runtime = MultiContainerStartupBenchmarkRuntimeDouble()
      let initial = idleContainerStatistics(
        memoryUsageBytes: 20 * 1_048_576,
        cpuUsageMicroseconds: 1_000
      )
      let final = idleContainerStatistics(
        memoryUsageBytes: 21 * 1_048_576,
        cpuUsageMicroseconds: 1_100
      )
      let statistics = IdleContainerStatisticsRuntimeDouble(
        samples:
          Array(repeating: initial, count: density.rawValue)
          + Array(repeating: final, count: density.rawValue)
      )
      let sleeper = IdleResourceSleepDouble()
      let scenario = try IdleContainerDensityPerformanceBenchmarkScenario(
        density: density,
        containers: runtime,
        stateReader: runtime,
        statistics: statistics,
        imageReference: "example.invalid/local:benchmark",
        expectedImageDigest: "sha256:fixture",
        settlingDuration: .zero,
        samplingDuration: .seconds(1),
        sleep: { duration in await sleeper.sleep(for: duration) }
      )
      let service = PerformanceBenchmarkService(
        scenarios: [scenario],
        configuration: PerformanceBenchmarkConfiguration(
          warmupIterations: 0,
          measuredIterations: 1
        ),
        clock: SequencePerformanceClock(values: [100, 200])
      )

      let report = try await service.run { _ in }

      guard case .measured(let result) = report.outcomes[0] else {
        Issue.record("Expected a measured idle-density result for \(density.rawValue).")
        continue
      }
      #expect(result.kind == density.kind)
      let observation = try #require(await scenario.observations().first)
      #expect(observation.containerCount == density.rawValue)
      #expect(observation.initialMemoryUsageBytes.count == density.rawValue)
      #expect(observation.finalMemoryUsageBytes.count == density.rawValue)
      #expect(
        observation.initialTotalMemoryUsageBytes
          == UInt64(density.rawValue * 20 * 1_048_576)
      )
      #expect(
        observation.finalTotalMemoryUsageBytes
          == UInt64(density.rawValue * 21 * 1_048_576)
      )
      #expect(await statistics.containerIDs.count == density.rawValue * 2)
      #expect(await runtime.containerCount == 0)
      #expect(await sleeper.durations == [.zero, .seconds(1)])
    }
  }

  @Test
  func postStressMemoryRecordsBaselinePeakRetentionAndConfirmedStop() async throws {
    let id = "nativecontainers-stress-fixture"
    let runtime = ContainerStartupBenchmarkRuntimeDouble()
    let commands = FixedContainerCommandRuntimeDouble(
      standardOutput: "nativecontainers-memory-stress-ok\n"
    )
    let statistics = IdleContainerStatisticsRuntimeDouble(
      samples: [
        idleContainerStatistics(
          memoryUsageBytes: 20 * 1_048_576,
          cpuUsageMicroseconds: 100
        ),
        idleContainerStatistics(
          memoryUsageBytes: 84 * 1_048_576,
          cpuUsageMicroseconds: 200
        ),
        idleContainerStatistics(
          memoryUsageBytes: 31 * 1_048_576,
          cpuUsageMicroseconds: 300
        ),
      ]
    )
    let sleeper = IdleResourceSleepDouble()
    let scenario = try PostStressMemoryPerformanceBenchmarkScenario(
      containers: runtime,
      stateReader: runtime,
      commands: commands,
      statistics: statistics,
      imageReference: "example.invalid/local:benchmark",
      expectedImageDigest: "sha256:fixture",
      workloadMebibytes: 64,
      stressHoldSeconds: 3,
      stressSamplingDelay: .seconds(1),
      retainedIdleDuration: .seconds(10),
      makeContainerID: { id },
      sleep: { duration in await sleeper.sleep(for: duration) }
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 2_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured post-stress memory result.")
      return
    }
    #expect(result.kind == .postStressRetainedMemory)
    #expect(
      await scenario.observations() == [
        PostStressMemoryObservation(
          baselineMemoryUsageBytes: 20 * 1_048_576,
          stressedMemoryUsageBytes: 84 * 1_048_576,
          retainedMemoryUsageBytes: 31 * 1_048_576,
          memoryLimitBytes: 256 * 1_048_576,
          workloadMebibytes: 64,
          stopConfirmed: true
        )
      ]
    )
    let request = try #require(await commands.requests.first)
    #expect(request.arguments.dropFirst().first?.contains("dd if=/dev/zero") == true)
    #expect(request.arguments.contains("64"))
    #expect(await sleeper.durations == [.seconds(1), .seconds(10)])
    #expect(try await runtime.listedObservation(forContainerID: id) == nil)
  }

  @Test
  func imagePullMeasuresAllocatedGrowthAndDeletesExactPulledReference() async throws {
    let reference = "registry.example/nativecontainers/pull-fixture:1"
    let digest = "sha256:pull-fixture"
    let plan = ImagePullPlan(
      normalizedReference: reference,
      registryHost: "registry.example",
      existingDigest: nil,
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: .https,
      resolvedTransport: .https,
      unpackAfterPull: false,
      maxConcurrentDownloads: 4,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    let images = ImagePullPerformanceRuntimeDouble(
      plan: plan,
      result: ImagePullResult(
        reference: reference,
        digest: digest,
        replacedDigest: nil,
        unpackOutcome: nil
      )
    )
    let storage = ScriptedPerformanceStorageUsage(
      values: [
        performanceStorageUsage(imageCount: 4, allocatedImageBytes: 1_000),
        performanceStorageUsage(imageCount: 5, allocatedImageBytes: 9_192),
      ]
    )
    let scenario = try ImagePullDiskGrowthPerformanceBenchmarkScenario(
      images: images,
      storage: storage,
      reference: reference
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [1_000, 4_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured image-pull result.")
      return
    }
    #expect(result.kind == .imagePullAndDiskGrowth)
    #expect(result.samples.map(\.durationNanoseconds) == [3_000])
    #expect(
      await scenario.observations() == [
        ImagePullDiskGrowthObservation(
          reference: reference,
          digest: digest,
          allocatedImageBytesBefore: 1_000,
          allocatedImageBytesAfter: 9_192,
          allocatedImageGrowthBytes: 8_192,
          imageCountBefore: 4,
          imageCountAfter: 5
        )
      ]
    )
    #expect(await images.preparedReferences == [reference, reference])
    #expect(await images.pulledPlans == [plan])
    #expect(await images.deletedReferences == [reference])
    #expect(await storage.loadCount == 2)
  }

  @Test
  func imagePullRejectsAnAlreadyPresentReferenceBeforeMutation() async throws {
    let plan = ImagePullPlan(
      normalizedReference: "registry.example/nativecontainers/present:1",
      registryHost: "registry.example",
      existingDigest: "sha256:existing",
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: .https,
      resolvedTransport: .https,
      unpackAfterPull: false,
      maxConcurrentDownloads: 4,
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    let images = ImagePullPerformanceRuntimeDouble(
      plan: plan,
      result: ImagePullResult(
        reference: plan.normalizedReference,
        digest: "sha256:new",
        replacedDigest: plan.existingDigest,
        unpackOutcome: nil
      )
    )
    let storage = ScriptedPerformanceStorageUsage(values: [])
    let scenario = try ImagePullDiskGrowthPerformanceBenchmarkScenario(
      images: images,
      storage: storage,
      reference: plan.normalizedReference
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected an existing pull reference to fail closed.")
      return
    }
    #expect(kind == .imagePullAndDiskGrowth)
    #expect(message == ImagePullDiskGrowthBenchmarkError.invalidPlan.localizedDescription)
    #expect(await images.pulledPlans.isEmpty)
    #expect(await images.deletedReferences.isEmpty)
    #expect(await storage.loadCount == 0)
  }

  @Test
  func imageBuildUsesReviewedNoCachePlanAndRemovesOCIOutput() async throws {
    let fixture = try ImageBuildPerformanceFixture()
    defer { fixture.remove() }
    let runtime = ImageBuildPerformanceRuntimeDouble(
      outputDestination: fixture.outputDestination
    )
    let scenario = try ImageBuildPerformanceBenchmarkScenario(
      builder: runtime,
      request: fixture.request()
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [2_000, 7_000])
    )

    let report = try await service.run { _ in }

    guard case .measured(let result) = report.outcomes[0] else {
      Issue.record("Expected a measured image-build result.")
      return
    }
    #expect(result.kind == .imageBuild)
    #expect(result.samples.map(\.durationNanoseconds) == [5_000])
    #expect(result.samples.map(\.processedByteCount) == [nil])
    #expect(await runtime.preparedRequests == [fixture.request()])
    #expect(await runtime.builtPlanIDs == [runtime.planID])
    #expect(await runtime.discardedPlanIDs == [runtime.planID])
    #expect(await scenario.reviewedBuildIDs() == [runtime.planID])
    #expect(await scenario.reviewedOutputTags() == [fixture.tag])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.outputDestination.path(percentEncoded: false)
      )
    )
  }

  @Test
  func imageBuildRejectsCacheOrRegistryRefresh() throws {
    let fixture = try ImageBuildPerformanceFixture()
    defer { fixture.remove() }
    let runtime = ImageBuildPerformanceRuntimeDouble(
      outputDestination: fixture.outputDestination
    )

    #expect(throws: ImageBuildPerformanceBenchmarkError.invalidConfiguration) {
      _ = try ImageBuildPerformanceBenchmarkScenario(
        builder: runtime,
        request: fixture.request(cachePolicy: .builderInternal)
      )
    }
    #expect(throws: ImageBuildPerformanceBenchmarkError.invalidConfiguration) {
      _ = try ImageBuildPerformanceBenchmarkScenario(
        builder: runtime,
        request: fixture.request(pullLatest: true)
      )
    }
  }

  @Test
  func imageBuildRemovesOutputAfterResultValidationFailure() async throws {
    let fixture = try ImageBuildPerformanceFixture()
    defer { fixture.remove() }
    let runtime = ImageBuildPerformanceRuntimeDouble(
      outputDestination: fixture.outputDestination,
      resultSHA256: "invalid"
    )
    let scenario = try ImageBuildPerformanceBenchmarkScenario(
      builder: runtime,
      request: fixture.request()
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [10])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected an invalid image-build result to fail.")
      return
    }
    #expect(kind == .imageBuild)
    #expect(
      message
        == ImageBuildPerformanceBenchmarkError.resultChanged.localizedDescription
    )
    #expect(await runtime.discardedPlanIDs == [runtime.planID])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.outputDestination.path(percentEncoded: false)
      )
    )
  }

  @Test
  func imageBuildRejectsChangedPreparedPlanAndDiscardsIt() async throws {
    let fixture = try ImageBuildPerformanceFixture()
    defer { fixture.remove() }
    let runtime = ImageBuildPerformanceRuntimeDouble(
      outputDestination: fixture.outputDestination,
      planCachePolicy: .builderInternal
    )
    let scenario = try ImageBuildPerformanceBenchmarkScenario(
      builder: runtime,
      request: fixture.request()
    )
    let service = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      ),
      clock: SequencePerformanceClock(values: [])
    )

    let report = try await service.run { _ in }

    guard case .failed(let kind, let message) = report.outcomes[0] else {
      Issue.record("Expected a changed image-build plan to fail.")
      return
    }
    #expect(kind == .imageBuild)
    #expect(
      message == ImageBuildPerformanceBenchmarkError.planChanged.localizedDescription
    )
    #expect(await runtime.builtPlanIDs.isEmpty)
    #expect(await runtime.discardedPlanIDs == [runtime.planID])
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

  @Test
  func sleepWakeScenarioTimesOnlyPostWakeRecovery() async throws {
    let events = HostSleepWakeEventDouble()
    let recovery = HostSleepWakeRecoveryDouble()
    let scenario = try HostSleepWakePerformanceBenchmarkScenario(
      events: events,
      recovery: recovery,
      timeout: .seconds(90)
    )

    try await scenario.prepareIteration()
    try await scenario.prepareMeasurement()
    let byteCount = try await scenario.perform()
    try await scenario.cleanUpIteration()

    #expect(byteCount == nil)
    #expect(await events.timeouts == [.seconds(90)])
    #expect(await recovery.verificationCount == 1)
  }

  @Test
  func crashRecoveryScenarioRequiresExactOrderedRecoveryAndCleanup() async throws {
    let cycle = CrashRecoveryBenchmarkCycleDouble()
    let scenario = try CrashRecoveryPerformanceBenchmarkScenario(
      kind: .appProcessCrashRecovery,
      cycle: cycle
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

    guard case .measured(let result) = report.outcomes.first else {
      Issue.record("Expected the ordered crash-recovery cycle to be measured.")
      return
    }
    #expect(result.kind == .appProcessCrashRecovery)
    #expect(result.samples.map(\.durationNanoseconds) == [150])
    #expect(
      await cycle.calls == ["prepare", "crash", "recover", "verify", "cleanup"]
    )
  }

  @Test
  func isolatedAppCrashRecoverySurvivesSIGKILLAndLeavesNoResidue() async throws {
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-AppCrashRecoveryTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: workspace) }
    let cycle = IsolatedAppProcessCrashRecoveryBenchmarkCycle(
      workspaceRootURL: workspace
    )

    try await cycle.prepare()
    try await cycle.crash()
    try await cycle.recover()
    try await cycle.verifyRecovery()
    try await cycle.cleanUp()

    let residue = try FileManager.default.contentsOfDirectory(
      at: workspace,
      includingPropertiesForKeys: nil
    )
    #expect(residue.isEmpty)
  }

  @Test
  func runtimeCrashRecoveryParserRequiresPublishedProcessIdentifier() {
    #expect(
      AppleRuntimeCrashRecoveryBenchmarkCycle.processIdentifier(
        in: "state = running\n\tpid = 4242\n"
      ) == 4242
    )
    #expect(
      AppleRuntimeCrashRecoveryBenchmarkCycle.processIdentifier(
        in: "state = waiting\n"
      ) == nil
    )
  }
}

@Suite("Live Apple performance benchmarks", .serialized)
struct LiveApplePerformanceBenchmarkTests {
  private static let outputMarker =
    "__NATIVECONTAINERS_COLD_CONTAINER_BENCHMARK__"
  private static let ioOutputMarker =
    "__NATIVECONTAINERS_CONTAINER_IO_BENCHMARK__"
  private static let networkOutputMarker =
    "__NATIVECONTAINERS_EXTERNAL_NETWORK_BENCHMARK__"
  private static let idleOutputMarker =
    "__NATIVECONTAINERS_IDLE_CONTAINER_BENCHMARK__"
  private static let memoryContractOutputMarker =
    "__NATIVECONTAINERS_MEMORY_CONTRACT_BENCHMARK__"
  private static let postgreSQLOutputMarker =
    "__NATIVECONTAINERS_POSTGRESQL_BENCHMARK__"
  private static let imagePullOutputMarker =
    "__NATIVECONTAINERS_IMAGE_PULL_BENCHMARK__"
  private static let networkComparisonOutputMarker =
    "__NATIVECONTAINERS_NETWORK_COMPARISON_BENCHMARK__"
  private static let recoveryOutputMarker =
    "__NATIVECONTAINERS_RECOVERY_BENCHMARK__"
  private static let buildOutputMarker =
    "__NATIVECONTAINERS_IMAGE_BUILD_BENCHMARK__"
  private static let machineOutputMarker =
    "__NATIVECONTAINERS_COLD_LINUX_MACHINE_BENCHMARK__"
  private static let macVirtualMachineOutputMarker =
    "__NATIVECONTAINERS_COLD_MAC_VM_BENCHMARK__"

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 with Apple container services running and the selected image already local."
    )
  )
  func measuresPreparedImageColdAndWarmContainerStartupWithoutResidue() async throws {
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
    let coldScenario = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: service,
      stateReader: AppleContainerStartupBenchmarkStateReader(),
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let warmScenario = WarmContainerStartupPerformanceBenchmarkScenario(
      containers: service,
      stateReader: AppleContainerStartupBenchmarkStateReader(),
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)warm-\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [coldScenario, warmScenario],
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

    let results = try report.outcomes.map { outcome in
      switch outcome {
      case .measured(let result):
        guard result.samples.count == 3 else {
          throw LivePerformanceBenchmarkError.missingScenarioResult(
            result.kind.rawValue
          )
        }
        return LiveContainerStartupBenchmarkResult(
          kind: result.kind.rawValue,
          samplesNanoseconds: result.samples.map(\.durationNanoseconds),
          medianMilliseconds: result.medianDurationMilliseconds,
          p95Milliseconds: result.p95DurationMilliseconds
        )
      case .failed(let kind, let message):
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
    }
    #expect(
      results.map(\.kind) == [
        PerformanceBenchmarkKind.coldContainerStartup.rawValue,
        PerformanceBenchmarkKind.warmContainerStartup.rawValue,
      ])

    let output = LiveContainerStartupBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      results: results
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.outputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_MACHINE"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_MACHINE=1 with Apple container services running and the selected machine image already local."
    )
  )
  func measuresColdLinuxMachineThroughFirstUserReadinessWithoutResidue() async throws {
    let containerService = AppleContainerService()
    let imageReference =
      ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_MACHINE_IMAGE"
      ]
      ?? ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"
      ]
      ?? "docker.io/library/alpine:3.22"
    let initialInventory = try await containerService.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }
    let inspection = try await containerService.inspectImage(
      reference: imageReference
    )
    guard
      inspection.variants.contains(where: {
        $0.os == "linux" && $0.architecture == "arm64"
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImagePlatform(
        reference: imageReference,
        platform: "linux/arm64"
      )
    }

    let runtime = AppleMachineRuntimeClient()
    let machineService = AppleMachineManagementService(
      runtime: runtime
    )
    let runPrefix =
      "nativecontainers-vm-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = ColdLinuxMachineStartupPerformanceBenchmarkScenario(
      machines: machineService,
      stateReader: runtime,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeMachineID: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(8))"
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
      try await requireNoResidualMachines(
        prefix: runPrefix,
        service: containerService
      )
      throw error
    }
    try await requireNoResidualMachines(
      prefix: runPrefix,
      service: containerService
    )

    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome
    else {
      if let outcome = report.outcomes.first,
        case .failed(let kind, let message) = outcome
      {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.coldLinuxMachineStartup.rawValue
      )
    }
    #expect(result.kind == .coldLinuxMachineStartup)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })

    let output = LiveColdLinuxMachineStartupBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      platform: "linux/arm64",
      cpuCount: 1,
      memoryMebibytes:
        LinuxMachineCreationRequest.minimumMemoryBytes
        / LinuxMachineCreationRequest.bytesPerMiB,
      includesFirstUserProvisioning: true,
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.machineOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1, NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM=1, and NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM_SOURCE to a stopped installed macOS VM UUID."
    )
  )
  @MainActor
  func measuresColdMacVirtualMachineRunningConsoleWithoutResidue() async throws {
    guard
      let sourceValue = ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM_SOURCE"
      ]
    else {
      throw LivePerformanceBenchmarkError.missingMacVirtualMachineSourceEnvironment
    }
    guard let sourceID = UUID(uuidString: sourceValue) else {
      throw LivePerformanceBenchmarkError.invalidMacVirtualMachineSource(sourceValue)
    }

    let library = VirtualMachineLibrary()
    guard
      let source = try await library.list().first(where: { $0.id == sourceID })
    else {
      throw LivePerformanceBenchmarkError.missingMacVirtualMachineSource(sourceID)
    }
    let savedState = MacVirtualMachineSavedStateService(
      store: MacVirtualMachineSavedStateStore()
    )
    let runtimeService = MacVirtualMachineRuntimeService(
      leasingStore: library,
      engine: AppleMacVirtualMachineRuntimeEngine(),
      savedStateService: savedState,
      firstBootService: MacVirtualMachineFirstBootService(
        persistence: library
      )
    )
    let cloner = VirtualMachineCloneService(store: library)
    let runPrefix =
      "NativeContainers Performance \(UUID().uuidString.lowercased().prefix(8)) "
    let scenario = ColdMacVirtualMachineStartupPerformanceBenchmarkScenario(
      source: source,
      inventory: library,
      cloner: cloner,
      discarder: library,
      runtime: AppleMacVirtualMachineStartupBenchmarkRuntime(
        runtime: runtimeService
      ),
      makeCloneName: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(8))"
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
      try await requireNoResidualMacVirtualMachines(
        prefix: runPrefix,
        source: source,
        library: library
      )
      throw error
    }
    try await requireNoResidualMacVirtualMachines(
      prefix: runPrefix,
      source: source,
      library: library
    )

    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome
    else {
      if let outcome = report.outcomes.first,
        case .failed(let kind, let message) = outcome
      {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.coldMacVirtualMachineStartup.rawValue
      )
    }
    #expect(result.kind == .coldMacVirtualMachineStartup)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })

    let operatingSystem = try #require(source.macOSGuestOperatingSystem)
    let output = LiveColdMacVirtualMachineStartupBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      sourceID: source.id.uuidString,
      sourceName: source.name,
      guestVersion: operatingSystem.versionDescription,
      guestBuildVersion: operatingSystem.buildVersion,
      cpuCount: source.resources.cpuCount,
      memoryMebibytes:
        source.resources.memoryBytes
        / (VirtualMachineResources.bytesPerGiB / 1_024),
      startupBoundary: "runtime-running-with-graphical-console",
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.macVirtualMachineOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_IO"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_IO=1 with Apple container services running and the selected image already local."
    )
  )
  func measuresGuestRootAndReviewedVirtioFSIOWithoutResidue() async throws {
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

    let runID = UUID().uuidString.lowercased()
    let runPrefix = "nativecontainers-io-\(runID.prefix(8))-"
    let hostRoot = URL(
      filePath: "/private/tmp/nativecontainers-io-\(runID)",
      directoryHint: .isDirectory
    )
    let bindDirectory = hostRoot.appending(
      path: "Bind",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: bindDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: hostRoot) }

    let reviewedMount = try service.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: bindDirectory,
        containerPath: "/workspace",
        isReadOnly: false
      )
    )
    let bindAttachments = try ContainerAttachmentSelection(
      volumeMounts: [],
      hostDirectoryMounts: [reviewedMount],
      networks: [],
      publishedSockets: [],
      requiredHostAccess: nil
    )
    let guestScenario = try ContainerIOPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      storage: .guestRoot,
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)guest-\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let bindScenario = try ContainerIOPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      storage: .bindMount,
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      attachments: bindAttachments,
      makeContainerID: {
        "\(runPrefix)bind-\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let metadataScenario = try BindMountMetadataPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      attachments: bindAttachments,
      imageReference: imageReference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)metadata-\(UUID().uuidString.lowercased().prefix(6))"
      }
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [guestScenario, bindScenario, metadataScenario],
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
      try requireNoResidualHostArtifacts(in: bindDirectory)
      throw error
    }
    try await requireNoResidualContainers(prefix: runPrefix, service: service)
    try requireNoResidualHostArtifacts(in: bindDirectory)

    let results = try report.outcomes.map { outcome in
      switch outcome {
      case .measured(let result):
        return LiveContainerIOBenchmarkResult(
          kind: result.kind.rawValue,
          samplesNanoseconds: result.samples.map(\.durationNanoseconds),
          medianMilliseconds: result.medianDurationMilliseconds,
          p95Milliseconds: result.p95DurationMilliseconds,
          throughputMebibytesPerSecond: result.throughputMebibytesPerSecond
        )
      case .failed(let kind, let message):
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
    }
    #expect(results.count == 3)

    let output = LiveContainerIOBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      payloadMebibytes: 16,
      results: results
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.ioOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK=1 with a local image plus NETWORK_URL, NETWORK_BYTES, and NETWORK_SHA256 fixture values."
    )
  )
  func measuresVerifiedExternalHTTPSTransferWithoutResidue() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let endpointValue = environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_URL"
      ],
      let endpoint = URL(string: endpointValue),
      let byteCountValue = environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_BYTES"
      ],
      let byteCount = Int64(byteCountValue),
      let sha256 = environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_SHA256"
      ]
    else {
      throw LivePerformanceBenchmarkError.missingExternalNetworkFixture
    }

    let service = AppleContainerService()
    let imageReference =
      environment["NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"]
      ?? "docker.io/library/alpine:3.21"
    let initialInventory = try await service.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }

    let runPrefix =
      "nativecontainers-network-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = try ExternalNetworkPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      endpoint: endpoint,
      expectedByteCount: byteCount,
      expectedSHA256: sha256,
      imageReference: image.reference,
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
        case .failed(let kind, let message) = outcome
      {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.externalNetworkTransfer.rawValue
      )
    }
    #expect(result.kind == .externalNetworkTransfer)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })
    #expect(result.samples.allSatisfy { $0.processedByteCount == byteCount })

    let authority =
      endpoint.port.map { "\(endpoint.host ?? "unknown"):\($0)" }
      ?? endpoint.host ?? "unknown"
    let output = LiveExternalNetworkBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      endpointAuthority: authority,
      protocolName: "HTTPS",
      expectedByteCount: byteCount,
      expectedSHA256: sha256,
      cacheRequest: "no-cache",
      verification: "byte-count+sha256",
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds,
      throughputMebibytesPerSecond: result.throughputMebibytesPerSecond
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.networkOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_IDLE"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_IDLE=1 with Apple container services running and the selected image already local."
    )
  )
  func measuresIdleContainerResourceCountersWithoutResidue() async throws {
    let environment = ProcessInfo.processInfo.environment
    let samplingSecondsValue =
      environment["NATIVECONTAINERS_LIVE_PERFORMANCE_IDLE_SECONDS"] ?? "10"
    guard
      let samplingSeconds = Int64(samplingSecondsValue),
      (1...300).contains(samplingSeconds)
    else {
      throw LivePerformanceBenchmarkError.invalidIdleSamplingDuration(
        samplingSecondsValue
      )
    }

    let service = AppleContainerService()
    let imageReference =
      environment["NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"]
      ?? "docker.io/library/alpine:3.21"
    let initialInventory = try await service.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }

    let runPrefix =
      "nativecontainers-idle-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = try IdleContainerResourcePerformanceBenchmarkScenario(
      containers: service,
      statistics: service,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      settlingDuration: .seconds(2),
      samplingDuration: .seconds(samplingSeconds),
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
        case .failed(let kind, let message) = outcome
      {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.idleContainerResources.rawValue
      )
    }
    #expect(result.kind == .idleContainerResources)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })

    let observations = Array((await scenario.observations()).suffix(result.samples.count))
    guard observations.count == result.samples.count else {
      throw LivePerformanceBenchmarkError.missingIdleResourceObservations
    }
    let samples = zip(result.samples, observations).map { sample, observation in
      LiveIdleContainerResourceSample(
        durationNanoseconds: sample.durationNanoseconds,
        normalizedCPUPercentage:
          Double(observation.cpuUsageDeltaMicroseconds) * 1_000
          / Double(sample.durationNanoseconds) * 100,
        cpuUsageDeltaMicroseconds: observation.cpuUsageDeltaMicroseconds,
        initialMemoryUsageBytes: observation.initialMemoryUsageBytes,
        finalMemoryUsageBytes: observation.finalMemoryUsageBytes,
        memoryLimitBytes: observation.memoryLimitBytes,
        networkReceivedDeltaBytes: observation.networkReceivedDeltaBytes,
        networkTransmittedDeltaBytes: observation.networkTransmittedDeltaBytes,
        blockReadDeltaBytes: observation.blockReadDeltaBytes,
        blockWrittenDeltaBytes: observation.blockWrittenDeltaBytes,
        processCount: observation.processCount
      )
    }
    let cpuPercentages = samples.map(\.normalizedCPUPercentage)
    let output = LiveIdleContainerResourceBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      cpuCount: 1,
      memoryLimitBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      settlingSeconds: 2,
      requestedSamplingSeconds: samplingSeconds,
      command: "/bin/sleep 3600",
      samples: samples,
      medianCPUPercentage: nearestRankPercentile(cpuPercentages, 0.5),
      p95CPUPercentage: nearestRankPercentile(cpuPercentages, 0.95),
      peakFinalMemoryUsageBytes: samples.map(\.finalMemoryUsageBytes).max() ?? 0
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.idleOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_MEMORY_CONTRACT"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_MEMORY_CONTRACT=1 with Apple container services running and enough capacity for 50 idle containers."
    )
  )
  func measuresTenFiftyAndPostStressMemoryWithoutResidue() async throws {
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
      "nativecontainers-memory-\(UUID().uuidString.lowercased().prefix(8))-"
    let ten = try IdleContainerDensityPerformanceBenchmarkScenario(
      density: .ten,
      containers: service,
      statistics: service,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)ten-\(UUID().uuidString.lowercased().prefix(8))"
      }
    )
    let fifty = try IdleContainerDensityPerformanceBenchmarkScenario(
      density: .fifty,
      containers: service,
      statistics: service,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)fifty-\(UUID().uuidString.lowercased().prefix(8))"
      }
    )
    let stress = try PostStressMemoryPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      statistics: service,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)stress-\(UUID().uuidString.lowercased().prefix(8))"
      }
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [ten, fifty, stress],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
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
    for outcome in report.outcomes {
      if case .failed(let kind, let message) = outcome {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
    }
    let tenObservation = try #require(await ten.observations().first)
    let fiftyObservation = try #require(await fifty.observations().first)
    let stressObservation = try #require(await stress.observations().first)
    let output = LiveMemoryContractBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      density: [
        LiveIdleDensityObservation(tenObservation),
        LiveIdleDensityObservation(fiftyObservation),
      ],
      stress: LivePostStressMemoryObservation(stressObservation)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.memoryContractOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_POSTGRESQL"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_POSTGRESQL=1 with the selected PostgreSQL image already local."
    )
  )
  func measuresPostgreSQLDurabilityAndFsyncWithoutResidue() async throws {
    let service = AppleContainerService()
    let imageReference =
      ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_POSTGRESQL_IMAGE"
      ] ?? "docker.io/library/postgres:17-alpine"
    let initialInventory = try await service.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }
    let runPrefix =
      "nativecontainers-postgres-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = try PostgreSQLDurabilityPerformanceBenchmarkScenario(
      containers: service,
      commands: service,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(8))"
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
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.postgreSQLDurability.rawValue
      )
    }
    let observations = Array(
      (await scenario.observations()).suffix(result.samples.count)
    )
    let output = LivePostgreSQLBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      observations: observations.map(LivePostgreSQLObservation.init)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.postgreSQLOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE_PULL"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1, NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE_PULL=1, and NATIVECONTAINERS_LIVE_PERFORMANCE_PULL_REFERENCE to a disposable remote reference absent locally."
    )
  )
  func measuresImagePullAndAllocatedDiskGrowthWithoutResidue() async throws {
    guard
      let reference = ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_PULL_REFERENCE"
      ]
    else {
      throw LivePerformanceBenchmarkError.missingImagePullReference
    }
    let service = AppleContainerService()
    let initialInventory = try await service.loadInventory()
    let scenario = try ImagePullDiskGrowthPerformanceBenchmarkScenario(
      images: service,
      storage: AppleRuntimeStorageUsageService(),
      reference: reference
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )
    let report = try await benchmark.run { _ in }
    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome,
      let observation = await scenario.observations().first
    else {
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.imagePullAndDiskGrowth.rawValue
      )
    }
    let residual = try await service.loadInventory().images.contains(where: {
      $0.reference == observation.reference
    })
    guard !residual else {
      throw LivePerformanceBenchmarkError.residualBuildImages([
        observation.reference
      ])
    }
    let output = LiveImagePullBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      sampleNanoseconds: result.samples[0].durationNanoseconds,
      observation: LiveImagePullObservation(observation)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.imagePullOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_COMPARISON"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1, NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_COMPARISON=1, and NATIVECONTAINERS_LIVE_PERFORMANCE_HOST_PORT to an unused localhost TCP port."
    )
  )
  func measuresNATAndDirectIPNetworkPathsWithoutResidue() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let hostPortValue = environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_HOST_PORT"
      ],
      let hostPort = UInt16(hostPortValue),
      hostPort > 1
    else {
      throw LivePerformanceBenchmarkError.invalidHostPort
    }
    let service = AppleContainerService()
    let imageReference =
      environment["NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"]
      ?? "docker.io/library/alpine:3.21"
    let initialInventory = try await service.loadInventory()
    guard
      let image = initialInventory.images.first(where: {
        $0.reference == imageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(imageReference)
    }
    let runPrefix =
      "nativecontainers-network-compare-\(UUID().uuidString.lowercased().prefix(8))-"
    let scenario = try NATDirectNetworkPerformanceBenchmarkScenario(
      containers: service,
      inventory: service,
      commands: service,
      hostPort: hostPort,
      imageReference: image.reference,
      expectedImageDigest: image.digest,
      makeContainerID: {
        "\(runPrefix)\(UUID().uuidString.lowercased().prefix(8))"
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
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.natDirectNetworkComparison.rawValue
      )
    }
    let observations = Array(
      (await scenario.observations()).suffix(result.samples.count)
    )
    let output = LiveNetworkComparisonBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      imageReference: image.reference,
      imageDigest: image.digest,
      observations: observations.map(LiveNetworkComparisonObservation.init)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.networkComparisonOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_BUILD"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_BUILD=1 with Apple container services running and the selected base image already local."
    )
  )
  func measuresFixedNoCacheImageBuildAndOCIExportWithoutResidue() async throws {
    let containerService = AppleContainerService()
    let baseImageReference =
      ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE_IMAGE"
      ] ?? "docker.io/library/alpine:3.21"
    let initialInventory = try await containerService.loadInventory()
    guard
      let baseImage = initialInventory.images.first(where: {
        $0.reference == baseImageReference
      })
    else {
      throw LivePerformanceBenchmarkError.missingLocalImage(baseImageReference)
    }

    let fixture = try LiveImageBuildPerformanceFixture(
      baseImageReference: baseImage.reference,
      baseImageDigest: baseImage.digest
    )
    defer { fixture.remove() }
    let scenario = try ImageBuildPerformanceBenchmarkScenario(
      builder: AppleContainerBuildService(),
      request: fixture.request
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
      try fixture.requireNoOutputArtifacts()
      let reviewedTags = await scenario.reviewedOutputTags()
      try await requireNoResidualBuildImages(
        references: Set(reviewedTags + [fixture.tag]),
        service: containerService
      )
      let buildIDs = await scenario.reviewedBuildIDs()
      let stagedContextDirectories =
        await scenario.reviewedStagedContextDirectories()
      try await requireNoResidualBuildArtifacts(
        buildIDs: buildIDs,
        stagedContextDirectories: stagedContextDirectories
      )
      throw error
    }
    try fixture.requireNoOutputArtifacts()
    let reviewedTags = await scenario.reviewedOutputTags()
    try await requireNoResidualBuildImages(
      references: Set(reviewedTags + [fixture.tag]),
      service: containerService
    )
    let buildIDs = await scenario.reviewedBuildIDs()
    let stagedContextDirectories =
      await scenario.reviewedStagedContextDirectories()
    try await requireNoResidualBuildArtifacts(
      buildIDs: buildIDs,
      stagedContextDirectories: stagedContextDirectories
    )

    guard
      let outcome = report.outcomes.first,
      case .measured(let result) = outcome
    else {
      if let outcome = report.outcomes.first,
        case .failed(let kind, let message) = outcome
      {
        throw LivePerformanceBenchmarkError.scenarioFailed(
          kind: kind.rawValue,
          message: message
        )
      }
      throw LivePerformanceBenchmarkError.missingScenarioResult(
        PerformanceBenchmarkKind.imageBuild.rawValue
      )
    }
    #expect(result.kind == .imageBuild)
    #expect(result.samples.count == 3)
    #expect(result.samples.allSatisfy { $0.durationNanoseconds > 0 })

    let output = LiveImageBuildBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      appleContainerVersion: initialInventory.system.version,
      baseImageReference: baseImage.reference,
      baseImageDigest: baseImage.digest,
      contextPayloadBytes: fixture.contextPayloadBytes,
      cachePolicy: ImageBuildCachePolicy.disabled.rawValue,
      outputKind: ImageBuildOutputKind.ociArchive.rawValue,
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.buildOutputMarker)\(json)")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_HOST_SLEEP"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_HOST_SLEEP=1, start the test, then put the host to sleep and wake it within ten minutes."
    )
  )
  func measuresVerifiedRecoveryAfterRealHostSleepAndWake() async throws {
    let initialInventory = try await AppleRuntimeInventoryService().loadInventory()
    let scenario = try HostSleepWakePerformanceBenchmarkScenario()
    let benchmark = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )
    let report = try await benchmark.run { _ in }
    let result = try measuredRecoveryResult(
      from: report,
      expected: .hostSleepWakeRecovery
    )
    try printRecoveryOutput(
      report: report,
      result: result,
      runtimeVersion: initialInventory.system.version
    )
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_APP_CRASH"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_APP_CRASH=1 to crash an isolated app-owned worker and verify journal recovery."
    )
  )
  func measuresIsolatedAppProcessCrashRecoveryWithoutResidue() async throws {
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-LiveAppCrashRecovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: workspace) }
    let cycle = IsolatedAppProcessCrashRecoveryBenchmarkCycle(
      workspaceRootURL: workspace
    )
    let scenario = try CrashRecoveryPerformanceBenchmarkScenario(
      kind: .appProcessCrashRecovery,
      cycle: cycle
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 3
      )
    )
    let report = try await benchmark.run { _ in }
    let result = try measuredRecoveryResult(
      from: report,
      expected: .appProcessCrashRecovery
    )
    let residue = try FileManager.default.contentsOfDirectory(
      at: workspace,
      includingPropertiesForKeys: nil
    )
    guard residue.isEmpty else {
      throw LivePerformanceBenchmarkError.residualHostArtifacts(
        residue.map(\.lastPathComponent).sorted()
      )
    }
    try printRecoveryOutput(
      report: report,
      result: result,
      runtimeVersion: nil
    )
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_PERFORMANCE"
      ] == "1"
        && ProcessInfo.processInfo.environment[
          "NATIVECONTAINERS_LIVE_PERFORMANCE_RUNTIME_CRASH"
        ] == "1",
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE=1 and NATIVECONTAINERS_LIVE_PERFORMANCE_RUNTIME_CRASH=1 to SIGKILL the identity-verified container API service and require launchd plus inventory recovery."
    )
  )
  func measuresIdentityVerifiedRuntimeCrashRecovery() async throws {
    let initialInventory = try await AppleRuntimeInventoryService().loadInventory()
    let cycle = try AppleRuntimeCrashRecoveryBenchmarkCycle()
    let scenario = try CrashRecoveryPerformanceBenchmarkScenario(
      kind: .runtimeCrashRecovery,
      cycle: cycle
    )
    let benchmark = PerformanceBenchmarkService(
      scenarios: [scenario],
      configuration: PerformanceBenchmarkConfiguration(
        warmupIterations: 0,
        measuredIterations: 1
      )
    )
    let report = try await benchmark.run { _ in }
    let result = try measuredRecoveryResult(
      from: report,
      expected: .runtimeCrashRecovery
    )
    try printRecoveryOutput(
      report: report,
      result: result,
      runtimeVersion: initialInventory.system.version
    )
  }

  private func measuredRecoveryResult(
    from report: PerformanceBenchmarkReport,
    expected: PerformanceBenchmarkKind
  ) throws -> PerformanceBenchmarkResult {
    guard let outcome = report.outcomes.first else {
      throw LivePerformanceBenchmarkError.missingScenarioResult(expected.rawValue)
    }
    switch outcome {
    case .measured(let result):
      guard result.kind == expected else {
        throw LivePerformanceBenchmarkError.missingScenarioResult(expected.rawValue)
      }
      return result
    case .failed(let kind, let message):
      throw LivePerformanceBenchmarkError.scenarioFailed(
        kind: kind.rawValue,
        message: message
      )
    }
  }

  private func printRecoveryOutput(
    report: PerformanceBenchmarkReport,
    result: PerformanceBenchmarkResult,
    runtimeVersion: String?
  ) throws {
    let output = LiveRecoveryBenchmarkOutput(
      generatedAt: report.generatedAt,
      hostOperatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      runtimeVersion: runtimeVersion,
      kind: result.kind.rawValue,
      samplesNanoseconds: result.samples.map(\.durationNanoseconds),
      medianMilliseconds: result.medianDurationMilliseconds,
      p95Milliseconds: result.p95DurationMilliseconds
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(output)
    let json = try #require(String(data: encoded, encoding: .utf8))
    print("\(Self.recoveryOutputMarker)\(json)")
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

  private func requireNoResidualMachines(
    prefix: String,
    service: AppleContainerService
  ) async throws {
    let residualIDs = try await service.loadInventory().machines
      .map(\.id)
      .filter { $0.hasPrefix(prefix) }
      .sorted()
    guard residualIDs.isEmpty else {
      throw LivePerformanceBenchmarkError.residualMachines(residualIDs)
    }
  }

  private func requireNoResidualMacVirtualMachines(
    prefix: String,
    source: VirtualMachineManifest,
    library: VirtualMachineLibrary
  ) async throws {
    let manifests = try await library.list()
    let residual =
      manifests
      .filter { $0.name.hasPrefix(prefix) }
      .map { "\($0.name) [\($0.id.uuidString)]" }
      .sorted()
    guard residual.isEmpty else {
      throw LivePerformanceBenchmarkError.residualMacVirtualMachines(residual)
    }
    guard manifests.first(where: { $0.id == source.id }) == source else {
      throw LivePerformanceBenchmarkError.macVirtualMachineSourceChanged(
        source.id
      )
    }
  }

  private func requireNoResidualHostArtifacts(in directory: URL) throws {
    let artifacts = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    guard artifacts.isEmpty else {
      throw LivePerformanceBenchmarkError.residualHostArtifacts(
        artifacts.map(\.lastPathComponent).sorted()
      )
    }
  }

  private func requireNoResidualBuildArtifacts(
    buildIDs: [UUID],
    stagedContextDirectories: [URL]
  ) async throws {
    let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
    let residualBuildPaths = buildIDs.flatMap { buildID -> [String] in
      let privateArtifact = PrivateBuildArtifactStore().artifactURL(
        buildID: buildID
      )
      let sharedExport = health.appRoot
        .appending(path: "builder", directoryHint: .isDirectory)
        .appending(
          path: buildID.uuidString.lowercased(),
          directoryHint: .isDirectory
        )
      return [privateArtifact, sharedExport]
        .filter {
          FileManager.default.fileExists(
            atPath: $0.path(percentEncoded: false)
          )
        }
        .map { $0.path(percentEncoded: false) }
    }
    let residualStagedPaths =
      stagedContextDirectories
      .filter {
        FileManager.default.fileExists(
          atPath: $0.path(percentEncoded: false)
        )
      }
      .map { $0.path(percentEncoded: false) }
    let residualPaths = residualBuildPaths + residualStagedPaths
    guard residualPaths.isEmpty else {
      throw LivePerformanceBenchmarkError.residualBuildArtifacts(
        residualPaths.sorted()
      )
    }
  }

  private func requireNoResidualBuildImages(
    references: Set<String>,
    service: AppleContainerService
  ) async throws {
    let residual = try await service.loadInventory().images
      .filter { references.contains($0.reference) }
      .map { "\($0.reference)@\($0.digest)" }
    guard residual.isEmpty else {
      throw LivePerformanceBenchmarkError.residualBuildImages(residual)
    }
  }
}

private struct LiveContainerStartupBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let results: [LiveContainerStartupBenchmarkResult]
}

private struct LiveContainerStartupBenchmarkResult: Encodable {
  let kind: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private struct LiveColdLinuxMachineStartupBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let platform: String
  let cpuCount: Int
  let memoryMebibytes: UInt64
  let includesFirstUserProvisioning: Bool
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private struct LiveColdMacVirtualMachineStartupBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let sourceID: String
  let sourceName: String
  let guestVersion: String
  let guestBuildVersion: String
  let cpuCount: Int
  let memoryMebibytes: UInt64
  let startupBoundary: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private struct LiveContainerIOBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let payloadMebibytes: Int
  let results: [LiveContainerIOBenchmarkResult]
}

private struct LiveContainerIOBenchmarkResult: Encodable {
  let kind: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let throughputMebibytesPerSecond: Double?
}

private struct LiveExternalNetworkBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let endpointAuthority: String
  let protocolName: String
  let expectedByteCount: Int64
  let expectedSHA256: String
  let cacheRequest: String
  let verification: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let throughputMebibytesPerSecond: Double?
}

private struct LiveIdleContainerResourceBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let cpuCount: Int
  let memoryLimitBytes: UInt64
  let settlingSeconds: Int64
  let requestedSamplingSeconds: Int64
  let command: String
  let samples: [LiveIdleContainerResourceSample]
  let medianCPUPercentage: Double
  let p95CPUPercentage: Double
  let peakFinalMemoryUsageBytes: UInt64
}

private struct LiveIdleContainerResourceSample: Encodable {
  let durationNanoseconds: UInt64
  let normalizedCPUPercentage: Double
  let cpuUsageDeltaMicroseconds: UInt64
  let initialMemoryUsageBytes: UInt64
  let finalMemoryUsageBytes: UInt64
  let memoryLimitBytes: UInt64
  let networkReceivedDeltaBytes: UInt64?
  let networkTransmittedDeltaBytes: UInt64?
  let blockReadDeltaBytes: UInt64?
  let blockWrittenDeltaBytes: UInt64?
  let processCount: UInt64
}

private struct LiveMemoryContractBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let density: [LiveIdleDensityObservation]
  let stress: LivePostStressMemoryObservation
}

private struct LiveIdleDensityObservation: Encodable {
  let containerCount: Int
  let initialTotalMemoryUsageBytes: UInt64
  let finalTotalMemoryUsageBytes: UInt64
  let initialMemoryUsageBytes: [UInt64]
  let finalMemoryUsageBytes: [UInt64]

  init(_ observation: IdleContainerDensityObservation) {
    containerCount = observation.containerCount
    initialTotalMemoryUsageBytes = observation.initialTotalMemoryUsageBytes
    finalTotalMemoryUsageBytes = observation.finalTotalMemoryUsageBytes
    initialMemoryUsageBytes = observation.initialMemoryUsageBytes
    finalMemoryUsageBytes = observation.finalMemoryUsageBytes
  }
}

private struct LivePostStressMemoryObservation: Encodable {
  let baselineMemoryUsageBytes: UInt64
  let stressedMemoryUsageBytes: UInt64
  let retainedMemoryUsageBytes: UInt64
  let memoryLimitBytes: UInt64
  let workloadMebibytes: Int
  let stopConfirmed: Bool

  init(_ observation: PostStressMemoryObservation) {
    baselineMemoryUsageBytes = observation.baselineMemoryUsageBytes
    stressedMemoryUsageBytes = observation.stressedMemoryUsageBytes
    retainedMemoryUsageBytes = observation.retainedMemoryUsageBytes
    memoryLimitBytes = observation.memoryLimitBytes
    workloadMebibytes = observation.workloadMebibytes
    stopConfirmed = observation.stopConfirmed
  }
}

private struct LivePostgreSQLBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let samplesNanoseconds: [UInt64]
  let observations: [LivePostgreSQLObservation]
}

private struct LivePostgreSQLObservation: Encodable {
  let fsyncEnabled: Bool
  let synchronousCommitEnabled: Bool
  let pgTestFsyncCompleted: Bool
  let committedRowCount: Int
  let committedPayloadBytes: Int64

  init(_ observation: PostgreSQLDurabilityObservation) {
    fsyncEnabled = observation.fsyncEnabled
    synchronousCommitEnabled = observation.synchronousCommitEnabled
    pgTestFsyncCompleted = observation.pgTestFsyncCompleted
    committedRowCount = observation.committedRowCount
    committedPayloadBytes = observation.committedPayloadBytes
  }
}

private struct LiveImagePullBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let sampleNanoseconds: UInt64
  let observation: LiveImagePullObservation
}

private struct LiveImagePullObservation: Encodable {
  let reference: String
  let digest: String
  let allocatedImageBytesBefore: UInt64
  let allocatedImageBytesAfter: UInt64
  let allocatedImageGrowthBytes: UInt64
  let imageCountBefore: Int
  let imageCountAfter: Int

  init(_ observation: ImagePullDiskGrowthObservation) {
    reference = observation.reference
    digest = observation.digest
    allocatedImageBytesBefore = observation.allocatedImageBytesBefore
    allocatedImageBytesAfter = observation.allocatedImageBytesAfter
    allocatedImageGrowthBytes = observation.allocatedImageGrowthBytes
    imageCountBefore = observation.imageCountBefore
    imageCountAfter = observation.imageCountAfter
  }
}

private struct LiveNetworkComparisonBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let imageReference: String
  let imageDigest: String
  let observations: [LiveNetworkComparisonObservation]
}

private struct LiveNetworkComparisonObservation: Encodable {
  let publishedHost: String
  let publishedPort: UInt16
  let directHost: String
  let containerPort: UInt16
  let payloadByteCount: Int
  let requestCountPerRoute: Int
  let publishedRoute: LiveNetworkRouteObservation
  let directRoute: LiveNetworkRouteObservation

  init(_ observation: NATDirectNetworkObservation) {
    publishedHost = observation.publishedHost
    publishedPort = observation.publishedPort
    directHost = observation.directHost
    containerPort = observation.containerPort
    payloadByteCount = observation.payloadByteCount
    requestCountPerRoute = observation.requestCountPerRoute
    publishedRoute = LiveNetworkRouteObservation(observation.publishedRoute)
    directRoute = LiveNetworkRouteObservation(observation.directRoute)
  }
}

private struct LiveNetworkRouteObservation: Encodable {
  let samplesNanoseconds: [UInt64]
  let transferredByteCount: Int64
  let medianLatencyNanoseconds: UInt64
  let p95LatencyNanoseconds: UInt64
  let throughputMebibytesPerSecond: Double?

  init(_ observation: NetworkRoutePerformanceObservation) {
    samplesNanoseconds = observation.samplesNanoseconds
    transferredByteCount = observation.transferredByteCount
    medianLatencyNanoseconds = observation.medianLatencyNanoseconds
    p95LatencyNanoseconds = observation.p95LatencyNanoseconds
    throughputMebibytesPerSecond = observation.throughputMebibytesPerSecond
  }
}

private func nearestRankPercentile(_ values: [Double], _ percentile: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let rank = Int(ceil(percentile * Double(sorted.count)))
  return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

private struct LiveImageBuildBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let appleContainerVersion: String
  let baseImageReference: String
  let baseImageDigest: String
  let contextPayloadBytes: Int
  let cachePolicy: String
  let outputKind: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private struct LiveRecoveryBenchmarkOutput: Encodable {
  let generatedAt: Date
  let hostOperatingSystem: String
  let runtimeVersion: String?
  let kind: String
  let samplesNanoseconds: [UInt64]
  let medianMilliseconds: Double
  let p95Milliseconds: Double
}

private enum LivePerformanceBenchmarkError: LocalizedError {
  case missingLocalImage(String)
  case missingLocalImagePlatform(reference: String, platform: String)
  case missingMacVirtualMachineSourceEnvironment
  case invalidMacVirtualMachineSource(String)
  case missingMacVirtualMachineSource(UUID)
  case macVirtualMachineSourceChanged(UUID)
  case missingExternalNetworkFixture
  case missingImagePullReference
  case invalidHostPort
  case invalidIdleSamplingDuration(String)
  case missingIdleResourceObservations
  case residualContainers([String])
  case residualMachines([String])
  case residualMacVirtualMachines([String])
  case residualHostArtifacts([String])
  case residualBuildArtifacts([String])
  case residualBuildImages([String])
  case scenarioFailed(kind: String, message: String)
  case missingScenarioResult(String)

  var errorDescription: String? {
    switch self {
    case .missingLocalImage(let reference):
      "Pull “\(reference)” before running the live performance gate; image pulls are excluded from the startup measurement."
    case .missingLocalImagePlatform(let reference, let platform):
      "Pull the \(platform) variant of “\(reference)” before running the live performance gate."
    case .missingMacVirtualMachineSourceEnvironment:
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM_SOURCE to the UUID of a stopped installed macOS virtual machine."
    case .invalidMacVirtualMachineSource(let value):
      "The macOS virtual-machine benchmark source “\(value)” is not a UUID."
    case .missingMacVirtualMachineSource(let id):
      "No macOS virtual-machine benchmark source with identifier \(id.uuidString) exists."
    case .macVirtualMachineSourceChanged(let id):
      "The macOS virtual-machine benchmark source \(id.uuidString) changed during the live gate."
    case .missingExternalNetworkFixture:
      "Set the external-network benchmark URL, byte count, and lowercase SHA-256 fixture values."
    case .missingImagePullReference:
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE_PULL_REFERENCE to a disposable remote image reference that is absent locally."
    case .invalidHostPort:
      "Set NATIVECONTAINERS_LIVE_PERFORMANCE_HOST_PORT to an unused TCP port between 2 and 65535."
    case .invalidIdleSamplingDuration(let value):
      "The idle-resource sampling duration “\(value)” is not between 1 and 300 seconds."
    case .missingIdleResourceObservations:
      "The idle-resource benchmark did not retain all measured counter observations."
    case .residualContainers(let ids):
      "The live performance gate left benchmark containers behind: \(ids.joined(separator: ", "))."
    case .residualMachines(let ids):
      "The live performance gate left benchmark Linux machines behind: \(ids.joined(separator: ", "))."
    case .residualMacVirtualMachines(let machines):
      "The live performance gate left benchmark macOS virtual machines behind: \(machines.joined(separator: ", "))."
    case .residualHostArtifacts(let names):
      "The bind-mount benchmark left host artifacts behind: \(names.joined(separator: ", "))."
    case .residualBuildArtifacts(let paths):
      "The image-build benchmark left private artifacts behind: \(paths.joined(separator: ", "))."
    case .residualBuildImages(let references):
      "The image benchmark left unexpected image-store references: \(references.joined(separator: ", "))."
    case .scenarioFailed(let kind, let message):
      "The live \(kind) benchmark failed: \(message)"
    case .missingScenarioResult(let kind):
      "The live \(kind) benchmark returned no result."
    }
  }
}

private struct ImageBuildPerformanceFixture {
  let rootDirectory: URL
  let contextDirectory: URL
  let outputDirectory: URL
  let outputDestination: URL
  let tag: String

  init() throws {
    let suffix = UUID().uuidString.lowercased()
    rootDirectory = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-performance-build-fixture-\(suffix)",
      directoryHint: .isDirectory
    )
    contextDirectory = rootDirectory.appending(
      path: "Context",
      directoryHint: .isDirectory
    )
    outputDirectory = rootDirectory.appending(
      path: "Output",
      directoryHint: .isDirectory
    )
    outputDestination = outputDirectory.appending(
      path: "image.oci.tar",
      directoryHint: .notDirectory
    )
    tag = "nativecontainers.local/performance-fixture:\(suffix)"
    try FileManager.default.createDirectory(
      at: contextDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: false
    )
    try Data("FROM scratch\n".utf8).write(
      to: contextDirectory.appending(path: "Dockerfile")
    )
  }

  func request(
    cachePolicy: ImageBuildCachePolicy = .disabled,
    pullLatest: Bool = false
  ) -> ImageBuildRequest {
    ImageBuildRequest(
      contextDirectory: contextDirectory,
      dockerfile: nil,
      secrets: [],
      tags: [tag],
      platforms: [.current],
      buildArguments: [],
      labels: ["com.nativecontainers.performance-fixture=true"],
      targetStage: "",
      cachePolicy: cachePolicy,
      pullLatest: pullLatest,
      builderCPUCount: nil,
      builderMemoryMiB: nil,
      output: ImageBuildOutputSelection(
        kind: .ociArchive,
        destinationURL: outputDestination
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootDirectory)
  }
}

private actor ImageBuildPerformanceRuntimeDouble: ImageBuilding {
  nonisolated let planID = UUID()

  private let outputDestination: URL
  private let resultSHA256: String
  private let planCachePolicy: ImageBuildCachePolicy?
  private(set) var preparedRequests: [ImageBuildRequest] = []
  private(set) var builtPlanIDs: [UUID] = []
  private(set) var discardedPlanIDs: [UUID] = []

  init(
    outputDestination: URL,
    resultSHA256: String = String(repeating: "c", count: 64),
    planCachePolicy: ImageBuildCachePolicy? = nil
  ) {
    self.outputDestination = outputDestination.standardizedFileURL
      .resolvingSymlinksInPath()
    self.resultSHA256 = resultSHA256
    self.planCachePolicy = planCachePolicy
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    preparedRequests.append(request)
    let stagedContext = request.contextDirectory.appending(
      path: ".staged-\(planID.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    return ImageBuildPlan(
      id: planID,
      sourceContextDirectory: request.contextDirectory.standardizedFileURL,
      stagedContextDirectory: stagedContext,
      stagedDockerfile: stagedContext.appending(path: "Dockerfile"),
      dockerfileSHA256: String(repeating: "a", count: 64),
      stagedDockerignore: nil,
      dockerignoreSHA256: nil,
      contextFingerprint: String(repeating: "b", count: 64),
      secretReviewID: nil,
      secrets: [],
      tags: request.tags.map {
        ContainerBuildTagExpectation(reference: $0, existingDigest: nil)
      },
      platforms: request.platforms,
      buildArguments: request.buildArguments,
      labels: request.labels,
      targetStage: request.targetStage,
      cachePolicy: planCachePolicy ?? request.cachePolicy,
      pullLatest: request.pullLatest,
      builderCPUCount: request.builderCPUCount,
      builderMemoryMiB: request.builderMemoryMiB,
      output: ImageBuildOutputPlan(
        reviewID: planID,
        kind: .ociArchive,
        destinationURL: outputDestination,
        existingDestinationIdentity: nil
      ),
      generatedAt: Date(timeIntervalSince1970: 1_000)
    )
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    builtPlanIDs.append(plan.id)
    let archive = Data("nativecontainers-oci-archive".utf8)
    try archive.write(to: outputDestination, options: .atomic)
    return ImageBuildResult(
      buildID: plan.id,
      output: .ociArchive(
        destination: outputDestination,
        sha256: resultSHA256,
        byteCount: Int64(archive.count)
      ),
      platforms: plan.platforms,
      durationMilliseconds: 5,
      logTail: "fixture build complete"
    )
  }

  func discardBuild(_ plan: ImageBuildPlan) async {
    discardedPlanIDs.append(plan.id)
  }
}

private struct LiveImageBuildPerformanceFixture {
  static let payloadByteCount = 8 * 1_048_576

  let rootDirectory: URL
  let contextDirectory: URL
  let outputDirectory: URL
  let outputDestination: URL
  let contextPayloadBytes: Int
  let tag: String
  let request: ImageBuildRequest

  init(baseImageReference: String, baseImageDigest: String) throws {
    let suffix = UUID().uuidString.lowercased()
    let rootDirectory = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-build-performance-\(suffix)",
      directoryHint: .isDirectory
    )
    let contextDirectory = rootDirectory.appending(
      path: "Context",
      directoryHint: .isDirectory
    )
    let outputDirectory = rootDirectory.appending(
      path: "Output",
      directoryHint: .isDirectory
    )
    let outputDestination = outputDirectory.appending(
      path: "image.oci.tar",
      directoryHint: .notDirectory
    )
    let tag = "nativecontainers.local/performance-build:\(suffix)"

    do {
      try FileManager.default.createDirectory(
        at: contextDirectory,
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: false
      )
      for directory in [rootDirectory, contextDirectory, outputDirectory] {
        guard chmod(directory.path(percentEncoded: false), 0o700) == 0 else {
          throw LiveImageBuildPerformanceFixtureError.privateDirectoryUnavailable(
            directory.path(percentEncoded: false)
          )
        }
      }

      let pinnedReference =
        baseImageReference.contains("@")
        ? baseImageReference
        : "\(baseImageReference)@\(baseImageDigest)"
      let dockerfile = """
        FROM \(pinnedReference)
        COPY payload.bin /nativecontainers-performance-payload.bin
        RUN sha256sum /nativecontainers-performance-payload.bin > /nativecontainers-performance-payload.sha256
        """
      try Data(dockerfile.utf8).write(
        to: contextDirectory.appending(path: "Dockerfile"),
        options: .atomic
      )
      try Data(count: Self.payloadByteCount).write(
        to: contextDirectory.appending(path: "payload.bin"),
        options: .atomic
      )

      self.rootDirectory = rootDirectory
      self.contextDirectory = contextDirectory
      self.outputDirectory = outputDirectory
      self.outputDestination = outputDestination
      contextPayloadBytes = Self.payloadByteCount
      self.tag = tag
      request = ImageBuildRequest(
        contextDirectory: contextDirectory,
        dockerfile: nil,
        secrets: [],
        tags: [tag],
        platforms: [.current],
        buildArguments: [],
        labels: ["com.nativecontainers.performance=true"],
        targetStage: "",
        cachePolicy: .disabled,
        pullLatest: false,
        builderCPUCount: nil,
        builderMemoryMiB: nil,
        output: ImageBuildOutputSelection(
          kind: .ociArchive,
          destinationURL: outputDestination
        )
      )
    } catch {
      try? FileManager.default.removeItem(at: rootDirectory)
      throw error
    }
  }

  func requireNoOutputArtifacts() throws {
    let artifacts = try FileManager.default.contentsOfDirectory(
      at: outputDirectory,
      includingPropertiesForKeys: nil
    )
    guard artifacts.isEmpty else {
      throw LivePerformanceBenchmarkError.residualBuildArtifacts(
        artifacts.map { $0.path(percentEncoded: false) }.sorted()
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootDirectory)
  }
}

private enum LiveImageBuildPerformanceFixtureError: LocalizedError {
  case privateDirectoryUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .privateDirectoryUnavailable(let path):
      "Could not make the image-build benchmark directory private: \(path)"
    }
  }
}

private actor ImagePullPerformanceRuntimeDouble: ImageManaging {
  private let plan: ImagePullPlan
  private let result: ImagePullResult

  private(set) var preparedReferences: [String] = []
  private(set) var pulledPlans: [ImagePullPlan] = []
  private(set) var deletedReferences: [String] = []

  init(plan: ImagePullPlan, result: ImagePullResult) {
    self.plan = plan
    self.result = result
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    preparedReferences.append(reference)
    return plan
  }

  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    pulledPlans.append(plan)
    return result
  }

  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    ImageDeletionPlan(
      reference: reference,
      digest: result.digest,
      aliases: [],
      usedByContainerIDs: [],
      isInfrastructureImage: false
    )
  }

  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    deletedReferences.append(plan.reference)
    return ImageCleanupResult(
      removedReferences: [plan.reference],
      failedReferences: [],
      removedBlobDigests: [plan.digest],
      reclaimedBytes: 8_192
    )
  }
}

private actor ScriptedPerformanceStorageUsage: AppleRuntimeStorageUsageLoading {
  private var values: [AppleRuntimeStorageUsage]
  private(set) var loadCount = 0

  init(values: [AppleRuntimeStorageUsage]) {
    self.values = values
  }

  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    loadCount += 1
    guard !values.isEmpty else {
      throw FixturePerformanceError.expected
    }
    return values.removeFirst()
  }
}

private func performanceStorageUsage(
  imageCount: Int,
  allocatedImageBytes: UInt64
) -> AppleRuntimeStorageUsage {
  AppleRuntimeStorageUsage(
    capturedAt: Date(timeIntervalSince1970: 1),
    images: StorageResourceUsage(
      totalCount: imageCount,
      activeCount: 0,
      allocatedBytes: allocatedImageBytes,
      reclaimableBytes: allocatedImageBytes
    ),
    containers: StorageResourceUsage(
      totalCount: 0,
      activeCount: 0,
      allocatedBytes: 0,
      reclaimableBytes: 0
    ),
    volumes: StorageResourceUsage(
      totalCount: 0,
      activeCount: 0,
      allocatedBytes: 0,
      reclaimableBytes: 0
    )
  )
}

private actor ScriptedPerformanceScenario: PerformanceBenchmarkScenario {
  nonisolated let kind: PerformanceBenchmarkKind

  private let byteCount: Int64?
  private let preparationError: (any Error)?
  private let error: (any Error)?
  private let cleanupError: (any Error)?
  private(set) var preparationCount = 0
  private(set) var measurementPreparationCount = 0
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

  func prepareMeasurement() async {
    measurementPreparationCount += 1
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

private actor HostSleepWakeEventDouble: HostSleepWakeEventAwaiting {
  private(set) var timeouts: [Duration] = []

  func awaitSleepWake(timeout: Duration) {
    timeouts.append(timeout)
  }
}

private actor HostSleepWakeRecoveryDouble: HostSleepWakeRecoveryVerifying {
  private(set) var verificationCount = 0

  func verifyRecoveryAfterWake() {
    verificationCount += 1
  }
}

private actor CrashRecoveryBenchmarkCycleDouble: CrashRecoveryBenchmarkCycling {
  private(set) var calls: [String] = []

  func prepare() {
    calls.append("prepare")
  }

  func crash() {
    calls.append("crash")
  }

  func recover() {
    calls.append("recover")
  }

  func verifyRecovery() {
    calls.append("verify")
  }

  func cleanUp() {
    calls.append("cleanup")
  }
}

private actor ContainerStartupBenchmarkRuntimeDouble:
  ContainerCreating,
  ContainerLifecycleManaging,
  ContainerStartupBenchmarkStateReading,
  ContainerInventoryLoading
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
  private let containerIPAddress: String

  init(
    createdImageDigest: String = "sha256:fixture",
    containerIPAddress: String = "192.0.2.44/24"
  ) {
    self.createdImageDigest = createdImageDigest
    self.containerIPAddress = containerIPAddress
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

  func loadInventory() async throws -> ContainerInventory {
    let records: [ContainerRecord]
    if let currentID,
      let state,
      let operationID,
      let imageReference,
      let imageDigest,
      let lastRequest
    {
      records = [
        ContainerRecord(
          id: currentID,
          imageReference: imageReference,
          imageDigest: imageDigest,
          platform: "linux/arm64",
          state: state,
          ipAddress: containerIPAddress,
          createdAt: Date(timeIntervalSince1970: 1),
          startedAt: startedAt,
          cpuCount: lastRequest.cpuCount,
          memoryBytes: lastRequest.memoryBytes,
          ports: lastRequest.publishedPorts.map {
            ContainerPort(
              hostAddress: $0.hostAddress,
              hostPort: $0.hostPort,
              containerPort: $0.containerPort,
              protocolName: $0.transportProtocol.rawValue
            )
          },
          labels: [
            AppleContainerOwnership.creationOperationLabel: operationID.uuidString
          ]
        )
      ]
    } else {
      records = []
    }
    return ContainerInventory(
      system: ContainerSystemInfo(
        version: "fixture",
        build: "fixture",
        commit: "fixture",
        applicationRoot: URL(filePath: "/tmp/application"),
        installRoot: URL(filePath: "/tmp/install")
      ),
      containers: records,
      images: [],
      volumes: [],
      networks: [],
      machines: []
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

private actor MultiContainerStartupBenchmarkRuntimeDouble:
  ContainerCreating,
  ContainerLifecycleManaging,
  ContainerStartupBenchmarkStateReading
{
  private struct Record {
    let operationID: UUID
    let imageReference: String
    let imageDigest: String
    var state: RuntimeState
    var startedAt: Date?
  }

  private var containers: [String: Record] = [:]

  var containerCount: Int { containers.count }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    guard containers[request.name] == nil else {
      throw FixturePerformanceError.expected
    }
    containers[request.name] = Record(
      operationID: request.operationID,
      imageReference: request.imageReference,
      imageDigest: "sha256:fixture",
      state: .stopped,
      startedAt: nil
    )
  }

  func startContainer(id: String) async throws {
    guard var record = containers[id] else {
      throw FixturePerformanceError.missingContainer
    }
    record.state = .running
    record.startedAt = Date(timeIntervalSince1970: 123)
    containers[id] = record
  }

  func stopContainer(id: String) async throws {
    guard var record = containers[id] else {
      throw FixturePerformanceError.missingContainer
    }
    record.state = .stopped
    containers[id] = record
  }

  func restartContainer(id: String) async throws {
    try await startContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try await stopContainer(id: id)
  }

  func deleteContainer(id: String) async throws {
    guard containers.removeValue(forKey: id) != nil else {
      throw FixturePerformanceError.missingContainer
    }
  }

  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation {
    guard let record = containers[id] else {
      throw FixturePerformanceError.missingContainer
    }
    return Self.observation(record)
  }

  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation? {
    containers[id].map(Self.observation)
  }

  private static func observation(_ record: Record) -> ContainerStartupBenchmarkObservation {
    ContainerStartupBenchmarkObservation(
      state: record.state,
      startedAt: record.startedAt,
      operationID: record.operationID,
      imageReference: record.imageReference,
      imageDigest: record.imageDigest
    )
  }
}

private actor LinuxMachineStartupBenchmarkRuntimeDouble:
  MachineCreating,
  MachineLifecycleManaging,
  LinuxMachineStartupBenchmarkStateReading
{
  private(set) var calls: [String] = []
  private(set) var lastRequest: LinuxMachineCreationRequest?

  private let imageDigest: String
  private let stopFails: Bool
  private var current: LinuxMachineRuntimeSnapshot?

  init(
    imageDigest: String = "sha256:machine-fixture",
    stopFails: Bool = false
  ) {
    self.imageDigest = imageDigest
    self.stopFails = stopFails
  }

  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    calls.append("create:\(request.name)")
    lastRequest = request
    let identity = LinuxMachineIdentity(
      id: request.name,
      imageReference: request.imageReference,
      platform: "linux/arm64",
      createdAt: Date(timeIntervalSince1970: 1_000)
    )
    current = LinuxMachineRuntimeSnapshot(
      identity: identity,
      state: .stopped,
      backingContainerID: nil,
      isInitialized: false,
      imageDigest: imageDigest,
      startedAt: nil
    )
    return LinuxMachineCreationResult(
      identity: identity,
      state: .stopped,
      isInitialized: false
    )
  }

  func startMachine(_ target: LinuxMachineIdentity) async throws {
    try requireCurrent(target)
    calls.append("start:\(target.id)")
    current = LinuxMachineRuntimeSnapshot(
      identity: target,
      state: .running,
      backingContainerID: "backing-\(target.id)",
      isInitialized: true,
      imageDigest: imageDigest,
      startedAt: Date(timeIntervalSince1970: 2_000)
    )
  }

  func stopMachine(_ target: LinuxMachineIdentity) async throws {
    let snapshot = try requireCurrent(target)
    calls.append("stop:\(target.id)")
    if stopFails {
      throw FixturePerformanceError.expected
    }
    current = LinuxMachineRuntimeSnapshot(
      identity: target,
      state: .stopped,
      backingContainerID: snapshot.backingContainerID,
      isInitialized: snapshot.isInitialized,
      imageDigest: snapshot.imageDigest,
      startedAt: snapshot.startedAt
    )
  }

  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws {
    let snapshot = try requireCurrent(target)
    guard authorization == .confirmed(for: target) else {
      throw FixturePerformanceError.expected
    }
    calls.append("force-stop:\(target.id)")
    current = LinuxMachineRuntimeSnapshot(
      identity: target,
      state: .stopped,
      backingContainerID: snapshot.backingContainerID,
      isInitialized: snapshot.isInitialized,
      imageDigest: snapshot.imageDigest,
      startedAt: snapshot.startedAt
    )
  }

  func deleteMachine(_ target: LinuxMachineIdentity) async throws {
    let snapshot = try requireCurrent(target)
    guard snapshot.state == .stopped else {
      throw FixturePerformanceError.expected
    }
    calls.append("delete:\(target.id)")
    current = nil
  }

  func snapshot(id: String) async throws -> LinuxMachineRuntimeSnapshot? {
    calls.append("snapshot:\(id)")
    guard current?.identity.id == id else { return nil }
    return current
  }

  func currentMachine() -> LinuxMachineRuntimeSnapshot? {
    current
  }

  func replaceCurrentMachine() {
    guard let current else { return }
    let replacement = LinuxMachineIdentity(
      id: current.identity.id,
      imageReference: current.identity.imageReference,
      platform: current.identity.platform,
      createdAt: Date(timeIntervalSince1970: 3_000)
    )
    self.current = LinuxMachineRuntimeSnapshot(
      identity: replacement,
      state: .running,
      backingContainerID: "replacement-\(replacement.id)",
      isInitialized: true,
      imageDigest: current.imageDigest,
      startedAt: Date(timeIntervalSince1970: 3_000)
    )
  }

  @discardableResult
  private func requireCurrent(
    _ target: LinuxMachineIdentity
  ) throws -> LinuxMachineRuntimeSnapshot {
    guard let current, current.identity == target else {
      throw FixturePerformanceError.missingContainer
    }
    return current
  }
}

private actor MacVirtualMachineStartupBenchmarkLibraryDouble:
  VirtualMachineInventoryLoading,
  VirtualMachineCloning,
  VirtualMachineIdentityDiscarding
{
  private(set) var calls: [String] = []
  private var source: VirtualMachineManifest
  private var clone: VirtualMachineManifest?
  private let cloneID: UUID

  init(source: VirtualMachineManifest, cloneID: UUID) {
    self.source = source
    self.cloneID = cloneID
  }

  func list() -> [VirtualMachineManifest] {
    calls.append("list")
    return [source] + [clone].compactMap { $0 }
  }

  func cloneVirtualMachine(id: UUID, name: String) throws -> VirtualMachineManifest {
    guard id == source.id, clone == nil else {
      throw FixturePerformanceError.expected
    }
    calls.append("clone:\(id.uuidString)")
    let clone = try VirtualMachineManifest(
      cloning: source,
      id: cloneID,
      name: name,
      createdAt: Date(timeIntervalSince1970: 2_000)
    )
    self.clone = clone
    return clone
  }

  func discardVirtualMachine(ifUnchanged manifest: VirtualMachineManifest) throws {
    guard clone == manifest else {
      throw VirtualMachineModelError.virtualMachineIdentityChanged(manifest.id)
    }
    calls.append("discard:\(manifest.id.uuidString)")
    clone = nil
  }

  func replaceClone() {
    clone?.name = "Replacement"
  }

  func currentClone() -> VirtualMachineManifest? {
    clone
  }

  func currentSource() -> VirtualMachineManifest {
    source
  }
}

private actor MacVirtualMachineStartupBenchmarkRuntimeDouble:
  MacVirtualMachineStartupBenchmarkRuntime
{
  private(set) var calls: [String] = []

  private let hasConsoleValue: Bool
  private let requestStopFails: Bool
  private var snapshots: [UUID: MacVirtualMachineRuntimeSnapshot] = [:]

  init(
    hasConsole: Bool = true,
    requestStopFails: Bool = false
  ) {
    hasConsoleValue = hasConsole
    self.requestStopFails = requestStopFails
  }

  func refreshSavedState(id: UUID) {
    calls.append("refresh:\(id.uuidString)")
    snapshots[id] = MacVirtualMachineRuntimeSnapshot(
      machineID: id,
      revision: 1,
      state: .stopped,
      savedStateStatus: .none
    )
  }

  func snapshot(id: UUID) -> MacVirtualMachineRuntimeSnapshot {
    calls.append("snapshot:\(id.uuidString)")
    return snapshots[id]
      ?? MacVirtualMachineRuntimeSnapshot(
        machineID: id,
        savedStateStatus: .unknown
      )
  }

  func start(id: UUID) throws {
    guard snapshots[id]?.state == .stopped else {
      throw FixturePerformanceError.expected
    }
    calls.append("start:\(id.uuidString)")
    snapshots[id] = MacVirtualMachineRuntimeSnapshot(
      machineID: id,
      revision: 2,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!
      ),
      state: .running,
      savedStateStatus: .none,
      saveRestoreSupport: .supported
    )
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    try requireTarget(target)
    calls.append("request-stop:\(target.machineID.uuidString)")
    if requestStopFails {
      throw FixturePerformanceError.expected
    }
    snapshots[target.machineID] = MacVirtualMachineRuntimeSnapshot(
      machineID: target.machineID,
      revision: 3,
      state: .stopped,
      savedStateStatus: .none,
      saveRestoreSupport: .supported
    )
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) throws {
    try requireTarget(target)
    calls.append("force-stop:\(target.machineID.uuidString)")
    snapshots[target.machineID] = MacVirtualMachineRuntimeSnapshot(
      machineID: target.machineID,
      revision: 3,
      state: .stopped,
      savedStateStatus: .none,
      saveRestoreSupport: .supported
    )
  }

  func hasConsole(for target: MacVirtualMachineRuntimeTarget) -> Bool {
    guard snapshots[target.machineID]?.target == target else { return false }
    calls.append("console:\(target.machineID.uuidString)")
    return hasConsoleValue
  }

  private func requireTarget(_ target: MacVirtualMachineRuntimeTarget) throws {
    guard snapshots[target.machineID]?.target == target else {
      throw FixturePerformanceError.expected
    }
  }
}

private func makeMacVirtualMachinePerformanceSource() throws -> VirtualMachineManifest {
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  var manifest = try VirtualMachineManifest(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
    name: "Installed macOS Fixture",
    guest: .macOS,
    installState: .stopped,
    resources: resources,
    createdAt: Date(timeIntervalSince1970: 1_000)
  )
  manifest.auxiliaryStoragePath = "Installed/AuxiliaryStorage"
  manifest.hardwareModelPath = "Installed/HardwareModel"
  manifest.machineIdentifierPath = "Installed/MachineIdentifier"
  manifest.macOSGuestOperatingSystem = MacGuestOperatingSystemIdentity(
    buildVersion: "TEST",
    majorVersion: 27,
    minorVersion: 0,
    patchVersion: 0
  )
  manifest.macOSFirstBootState = .started
  return manifest
}

private actor ExternalNetworkCommandRuntimeDouble: ContainerCommandRunning {
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerCommandRequest] = []

  private let standardOutput: String

  init(standardOutput: String) {
    self.standardOutput = standardOutput
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    containerIDs.append(id)
    requests.append(request)
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: standardOutput,
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(1)
    )
  }
}

private actor FixedContainerCommandRuntimeDouble: ContainerCommandRunning {
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerCommandRequest] = []

  private let standardOutput: String

  init(standardOutput: String) {
    self.standardOutput = standardOutput
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    containerIDs.append(id)
    requests.append(request)
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: standardOutput,
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(1)
    )
  }
}

private actor PerformanceHTTPTransportDouble:
  PerformanceBenchmarkHTTPTransferring
{
  private let payload: Data
  private(set) var urls: [URL] = []

  init(payload: Data) {
    self.payload = payload
  }

  func fetch(_ url: URL) async throws -> Data {
    urls.append(url)
    return payload
  }
}

private actor PostgreSQLCommandRuntimeDouble: ContainerCommandRunning {
  private(set) var requests: [ContainerCommandRequest] = []

  private var readinessExitCodes: [Int32]
  private let verificationOutput: String

  init(readinessExitCodes: [Int32], verificationOutput: String) {
    self.readinessExitCodes = readinessExitCodes
    self.verificationOutput = verificationOutput
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    requests.append(request)
    let exitCode: Int32
    let output: String
    switch request.executable {
    case "/usr/local/bin/pg_isready":
      exitCode =
        readinessExitCodes.isEmpty
        ? 1
        : readinessExitCodes.removeFirst()
      output = exitCode == 0 ? "accepting connections\n" : "no response\n"
    case "/usr/local/bin/pg_test_fsync":
      exitCode = 0
      output = "Compare file sync methods using one 8kB write\n"
    case "/usr/local/bin/psql":
      exitCode = 0
      output = verificationOutput
    default:
      throw FixturePerformanceError.expected
    }
    return ContainerCommandResult(
      exitCode: exitCode,
      standardOutput: output,
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(1)
    )
  }
}

private actor IdleContainerStatisticsRuntimeDouble:
  IdleContainerStatisticsSampling
{
  private(set) var containerIDs: [String] = []
  private var samples: [ContainerStatistics]

  init(samples: [ContainerStatistics]) {
    self.samples = samples
  }

  func sampleContainer(id: String) -> ContainerStatistics? {
    containerIDs.append(id)
    guard !samples.isEmpty else { return nil }
    return samples.removeFirst()
  }
}

private actor IdleResourceSleepDouble {
  private(set) var durations: [Duration] = []

  func sleep(for duration: Duration) {
    durations.append(duration)
  }
}

private func idleContainerStatistics(
  memoryUsageBytes: UInt64 = 20 * 1_048_576,
  cpuUsageMicroseconds: UInt64,
  networkReceivedBytes: UInt64 = 0,
  networkTransmittedBytes: UInt64 = 0,
  blockReadBytes: UInt64 = 0,
  blockWrittenBytes: UInt64 = 0,
  processCount: UInt64 = 2
) -> ContainerStatistics {
  ContainerStatistics(
    memoryUsageBytes: memoryUsageBytes,
    memoryLimitBytes: 256 * 1_048_576,
    cpuUsageMicroseconds: cpuUsageMicroseconds,
    networkReceivedBytes: networkReceivedBytes,
    networkTransmittedBytes: networkTransmittedBytes,
    blockReadBytes: blockReadBytes,
    blockWrittenBytes: blockWrittenBytes,
    processCount: processCount
  )
}

private actor ContainerIOCommandRuntimeDouble: ContainerCommandRunning {
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerCommandRequest] = []

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    containerIDs.append(id)
    requests.append(request)
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: "nativecontainers-io-ok\n",
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(1)
    )
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
