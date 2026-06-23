import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container runtime setup")
struct AppleContainerRuntimeSetupServiceTests {
  private let executableURL = URL(filePath: "/usr/local/bin/container")

  @Test
  func distributionContractPinsTheOfficialSignedInstaller() {
    #expect(AppleContainerRuntimeDistributionContract.requiredVersion == "1.0.0")
    #expect(
      AppleContainerRuntimeDistributionContract.packageIdentifier
        == "com.apple.container-installer"
    )
    #expect(
      AppleContainerRuntimeDistributionContract.executableURL.path
        == "/usr/local/bin/container"
    )
    #expect(
      AppleContainerRuntimeDistributionContract.releaseURL.absoluteString
        == "https://github.com/apple/container/releases/tag/1.0.0"
    )
  }

  @Test
  func readyCompatibleRuntimeSkipsExecutableAndProcessWork() async throws {
    let probe = RuntimeSetupProbeDouble([
      .ready(version: AppleContainerRuntimeSetupService.requiredVersion)
    ])
    let validator = RuntimeSetupExecutableValidatorDouble()
    let executor = RuntimeSetupCommandExecutorDouble([])
    let service = AppleContainerRuntimeSetupService(
      executableURL: executableURL,
      validator: validator,
      probe: probe,
      commandExecutor: executor
    )

    try await service.start()

    #expect(validator.validatedURLs.isEmpty)
    #expect(await executor.requests.isEmpty)
    #expect(await probe.callCount == 1)
  }

  @Test
  func unavailableRuntimeValidatesVersionStartsAndReprobes() async throws {
    let probe = RuntimeSetupProbeDouble([
      .unavailable,
      .ready(version: AppleContainerRuntimeSetupService.requiredVersion),
    ])
    let validator = RuntimeSetupExecutableValidatorDouble()
    let executor = RuntimeSetupCommandExecutorDouble([
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "container CLI version 1.0.0 (build: release)",
          standardError: "",
          outputWasTruncated: false
        )
      ),
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "Launching container-apiserver...",
          standardError: "",
          outputWasTruncated: false
        )
      ),
    ])
    let service = AppleContainerRuntimeSetupService(
      executableURL: executableURL,
      validator: validator,
      probe: probe,
      commandExecutor: executor,
      setupTimeout: .seconds(90)
    )

    try await service.start()

    #expect(validator.validatedURLs == [executableURL])
    #expect(
      await executor.requests
        == [
          RuntimeSetupCommandRequest(
            executableURL: executableURL,
            arguments: ["--version"],
            environment: nil,
            timeout: .seconds(10)
          ),
          RuntimeSetupCommandRequest(
            executableURL: executableURL,
            arguments: ["system", "start", "--enable-kernel-install"],
            environment: nil,
            timeout: .seconds(90)
          ),
        ]
    )
    #expect(await probe.callCount == 2)
  }

  @Test
  func incompatibleSignedCLIStopsBeforeServiceMutation() async {
    let probe = RuntimeSetupProbeDouble([.unavailable])
    let validator = RuntimeSetupExecutableValidatorDouble()
    let executor = RuntimeSetupCommandExecutorDouble([
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "container CLI version 2.0.0",
          standardError: "",
          outputWasTruncated: false
        )
      )
    ])
    let service = AppleContainerRuntimeSetupService(
      executableURL: executableURL,
      validator: validator,
      probe: probe,
      commandExecutor: executor
    )

    await #expect(
      throws: AppleContainerRuntimeSetupError.incompatibleVersion(
        found: "2.0.0",
        required: "1.0.0"
      )
    ) {
      try await service.start()
    }

    #expect(await executor.requests.count == 1)
  }

  @Test
  func failedSetupIncludesBoundedSignedCLIOutputAndDoesNotReprobe() async {
    let probe = RuntimeSetupProbeDouble([.unavailable])
    let executor = RuntimeSetupCommandExecutorDouble([
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "container CLI version 1.0.0",
          standardError: "",
          outputWasTruncated: false
        )
      ),
      .result(
        HostCommandResult(
          exitCode: 23,
          standardOutput: "",
          standardError: String(repeating: "x", count: 3_000),
          outputWasTruncated: true
        )
      ),
    ])
    let service = AppleContainerRuntimeSetupService(
      executableURL: executableURL,
      validator: RuntimeSetupExecutableValidatorDouble(),
      probe: probe,
      commandExecutor: executor
    )

    do {
      try await service.start()
      Issue.record("Expected the nonzero setup exit to fail.")
    } catch let error as AppleContainerRuntimeSetupError {
      guard case .startFailed(let detail) = error else {
        Issue.record("Expected startFailed, received \(error).")
        return
      }
      #expect(detail.contains("status 23"))
      #expect(detail.contains("Output was truncated"))
      #expect(detail.count < 2_100)
    } catch {
      Issue.record("Expected AppleContainerRuntimeSetupError, received \(error).")
    }

    #expect(await probe.callCount == 1)
  }

  @Test
  func startMustVerifyTheContainerAndMachineEndpoints() async {
    let probe = RuntimeSetupProbeDouble([.unavailable, .unavailable])
    let executor = RuntimeSetupCommandExecutorDouble([
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "container CLI version 1.0.0",
          standardError: "",
          outputWasTruncated: false
        )
      ),
      .result(
        HostCommandResult(
          exitCode: 0,
          standardOutput: "",
          standardError: "",
          outputWasTruncated: false
        )
      ),
    ])
    let service = AppleContainerRuntimeSetupService(
      executableURL: executableURL,
      validator: RuntimeSetupExecutableValidatorDouble(),
      probe: probe,
      commandExecutor: executor
    )

    await #expect(throws: AppleContainerRuntimeSetupError.self) {
      try await service.start()
    }

    #expect(await probe.callCount == 2)
  }

  @Test
  func semanticVersionParserRejectsIncompleteOrDecorativeNumbers() {
    #expect(
      AppleContainerRuntimeSetupService.semanticVersion(
        in: "container CLI version 1.0.0 (build 27A1)"
      ) == "1.0.0"
    )
    #expect(AppleContainerRuntimeSetupService.semanticVersion(in: "version 1.0") == nil)
    #expect(AppleContainerRuntimeSetupService.semanticVersion(in: "build 2700") == nil)
  }
}

private enum RuntimeSetupProbeStep: Sendable {
  case ready(version: String)
  case unavailable
}

private enum RuntimeSetupTestError: Error {
  case unavailable
  case noQueuedResult
}

private actor RuntimeSetupProbeDouble: AppleContainerRuntimeProbing {
  private var steps: [RuntimeSetupProbeStep]
  private(set) var callCount = 0

  init(_ steps: [RuntimeSetupProbeStep]) {
    self.steps = steps
  }

  func probe() async throws -> AppleContainerRuntimeObservation {
    callCount += 1
    guard !steps.isEmpty else { throw RuntimeSetupTestError.noQueuedResult }
    switch steps.removeFirst() {
    case .ready(let version):
      return AppleContainerRuntimeObservation(version: version)
    case .unavailable:
      throw RuntimeSetupTestError.unavailable
    }
  }
}

private final class RuntimeSetupExecutableValidatorDouble:
  AppleContainerExecutableValidating, @unchecked Sendable
{
  private let lock = NSLock()
  private var urls: [URL] = []

  var validatedURLs: [URL] {
    lock.withLock { urls }
  }

  func validate(executableURL: URL) throws {
    lock.withLock {
      urls.append(executableURL)
    }
  }
}

private struct RuntimeSetupCommandRequest: Equatable, Sendable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]?
  let timeout: Duration
}

private enum RuntimeSetupCommandStep: Sendable {
  case result(HostCommandResult)
}

private actor RuntimeSetupCommandExecutorDouble: HostCommandExecuting {
  private var steps: [RuntimeSetupCommandStep]
  private(set) var requests: [RuntimeSetupCommandRequest] = []

  init(_ steps: [RuntimeSetupCommandStep]) {
    self.steps = steps
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    requests.append(
      RuntimeSetupCommandRequest(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        timeout: timeout
      )
    )
    guard !steps.isEmpty else { throw RuntimeSetupTestError.noQueuedResult }
    switch steps.removeFirst() {
    case .result(let result):
      return result
    }
  }
}
