import ContainerAPIClient
import Darwin
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
    let request = await runtime.lastRequest
    #expect(request?.startAfterCreation == false)
    #expect(request?.architecture == .arm64)
    #expect(request?.cpuCount == 1)
    #expect(request?.memoryBytes == LinuxMachineCreationRequest.minimumMemoryBytes)
    #expect(request?.homeMount == .none)
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
}

@Suite("Live Apple performance benchmarks", .serialized)
struct LiveApplePerformanceBenchmarkTests {
  private static let outputMarker =
    "__NATIVECONTAINERS_COLD_CONTAINER_BENCHMARK__"
  private static let ioOutputMarker =
    "__NATIVECONTAINERS_CONTAINER_IO_BENCHMARK__"
  private static let buildOutputMarker =
    "__NATIVECONTAINERS_IMAGE_BUILD_BENCHMARK__"
  private static let machineOutputMarker =
    "__NATIVECONTAINERS_COLD_LINUX_MACHINE_BENCHMARK__"

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
    let benchmark = PerformanceBenchmarkService(
      scenarios: [guestScenario, bindScenario],
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
    #expect(results.count == 2)

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

private enum LivePerformanceBenchmarkError: LocalizedError {
  case missingLocalImage(String)
  case missingLocalImagePlatform(reference: String, platform: String)
  case residualContainers([String])
  case residualMachines([String])
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
    case .residualContainers(let ids):
      "The live performance gate left benchmark containers behind: \(ids.joined(separator: ", "))."
    case .residualMachines(let ids):
      "The live performance gate left benchmark Linux machines behind: \(ids.joined(separator: ", "))."
    case .residualHostArtifacts(let names):
      "The bind-mount benchmark left host artifacts behind: \(names.joined(separator: ", "))."
    case .residualBuildArtifacts(let paths):
      "The image-build benchmark left private artifacts behind: \(paths.joined(separator: ", "))."
    case .residualBuildImages(let references):
      "The OCI-export benchmark unexpectedly changed the image store: \(references.joined(separator: ", "))."
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
