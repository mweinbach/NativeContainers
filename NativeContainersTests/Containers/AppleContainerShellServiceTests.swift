import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container shell discovery")
struct AppleContainerShellServiceTests {
  @Test
  func candidatePolicyPrefersLastEnvironmentOverrideAndDeduplicates() {
    let configuration = ProcessConfiguration(
      executable: "/bin/bash",
      arguments: [],
      environment: ["SHELL=/bin/zsh", "SHELL=/bin/bash"]
    )

    let candidates = ContainerShellCandidatePolicy().candidates(for: configuration)

    #expect(candidates.first == ContainerShell(executable: "/bin/bash", source: .environment))
    #expect(candidates.filter { $0.executable == "/bin/bash" }.count == 1)
  }

  @Test
  func candidatePolicyRecognizesContainerProcessShellBeforeFallbacks() {
    let configuration = ProcessConfiguration(
      executable: "/opt/tools/fish",
      arguments: [],
      environment: []
    )

    let candidates = ContainerShellCandidatePolicy().candidates(for: configuration)

    #expect(
      candidates.first == ContainerShell(executable: "/opt/tools/fish", source: .containerProcess))
    #expect(candidates.contains(ContainerShell(executable: "/bin/sh", source: .fallback)))
  }

  @Test
  func discoveryFallsBackAfterUnavailableEnvironmentShell() async throws {
    let context = ShellConfigurationLoaderStub(
      configuration: ProcessConfiguration(
        executable: "/usr/bin/server",
        arguments: [],
        environment: ["SHELL=/custom/missing"]
      )
    )
    let executor = ShellProbeExecutor(
      outcomes: [
        "/custom/missing": .exit(127),
        "/bin/bash": .exit(0),
      ]
    )
    let service = AppleContainerShellService(
      configurationLoader: context,
      commandExecutor: executor
    )

    let shell = try await service.discoverShell(in: "  web  ")

    #expect(shell == ContainerShell(executable: "/bin/bash", source: .fallback))
    #expect(await context.containerIDs == ["web"])
    #expect(await executor.executables == ["/custom/missing", "/bin/bash"])
    #expect(await executor.arguments == [["-c", "exit 0"], ["-c", "exit 0"]])
    #expect(await executor.timeoutSeconds == [1, 1])
  }

  @Test
  func discoverySurfacesUnavailableAfterEveryCandidateFails() async {
    let context = ShellConfigurationLoaderStub(
      configuration: ProcessConfiguration(
        executable: "/usr/bin/server",
        arguments: [],
        environment: []
      )
    )
    let executor = ShellProbeExecutor(outcomes: [:])
    let service = AppleContainerShellService(
      configurationLoader: context,
      commandExecutor: executor
    )

    await #expect(throws: ContainerShellDiscoveryError.unavailable("minimal")) {
      try await service.discoverShell(in: "minimal")
    }
    #expect(!(await executor.executables).isEmpty)
  }

  @Test
  func discoveryStopsImmediatelyOnCancellation() async {
    let context = ShellConfigurationLoaderStub(
      configuration: ProcessConfiguration(
        executable: "/usr/bin/server",
        arguments: [],
        environment: ["SHELL=/cancelled"]
      )
    )
    let executor = ShellProbeExecutor(outcomes: ["/cancelled": .cancellation])
    let service = AppleContainerShellService(
      configurationLoader: context,
      commandExecutor: executor
    )

    await #expect(throws: CancellationError.self) {
      try await service.discoverShell(in: "web")
    }
    #expect(await executor.executables == ["/cancelled"])
  }

  @Test
  func discoveryRejectsBlankContainerBeforeLoadingContext() async {
    let context = ShellConfigurationLoaderStub(
      configuration: ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: []
      )
    )
    let service = AppleContainerShellService(
      configurationLoader: context,
      commandExecutor: ShellProbeExecutor(outcomes: ["/bin/sh": .exit(0)])
    )

    await #expect(throws: ContainerShellDiscoveryError.invalidContainerIdentifier) {
      try await service.discoverShell(in: "  ")
    }
    #expect(await context.containerIDs.isEmpty)
  }

  @Test
  func automaticTerminalResolvesShellBeforeLaunching() async throws {
    let shellDiscovery = RecordingShellDiscovery(executable: "/usr/bin/zsh")
    let process = ShellTerminalProcess()
    let launcher = RecordingResolvedTerminalLauncher(process: process)
    let service = AppleContainerTerminalService(
      shellDiscovery: shellDiscovery,
      terminalProcessLauncher: launcher
    )
    let request = try ContainerTerminalRequest(initialSize: .standard)

    let session = try await service.openTerminal(in: "  dev  ", request: request)

    #expect(await shellDiscovery.containerIDs == ["dev"])
    #expect(await launcher.containerIDs == ["dev"])
    #expect(await launcher.requests.first?.executable == "/usr/bin/zsh")
    #expect(await process.startCount == 1)
    await session.close()
  }

  @Test
  func explicitTerminalExecutableSkipsShellDiscovery() async throws {
    let shellDiscovery = RecordingShellDiscovery(executable: "/unused")
    let process = ShellTerminalProcess()
    let launcher = RecordingResolvedTerminalLauncher(process: process)
    let service = AppleContainerTerminalService(
      shellDiscovery: shellDiscovery,
      terminalProcessLauncher: launcher
    )
    let request = try ContainerTerminalRequest(program: .executable("/opt/custom-shell"))

    let session = try await service.openTerminal(in: "dev", request: request)

    #expect(await shellDiscovery.containerIDs.isEmpty)
    #expect(await launcher.requests.first?.executable == "/opt/custom-shell")
    await session.close()
  }
}

private actor ShellConfigurationLoaderStub: ContainerShellConfigurationLoading {
  private let configuration: ProcessConfiguration
  private(set) var containerIDs: [String] = []

  init(configuration: ProcessConfiguration) {
    self.configuration = configuration
  }

  func loadShellConfiguration(in containerID: String) -> ProcessConfiguration {
    containerIDs.append(containerID)
    return configuration
  }
}

private enum ShellProbeOutcome: Sendable {
  case exit(Int32)
  case failure
  case cancellation
}

private actor ShellProbeExecutor: RuntimeCommandExecuting {
  private let outcomes: [String: ShellProbeOutcome]
  private(set) var executables: [String] = []
  private(set) var arguments: [[String]] = []
  private(set) var timeoutSeconds: [Int] = []

  init(outcomes: [String: ShellProbeOutcome]) {
    self.outcomes = outcomes
  }

  func execute(
    in containerID: String,
    configuration: ProcessConfiguration,
    timeoutSeconds: Int
  ) throws -> ContainerCommandResult {
    executables.append(configuration.executable)
    arguments.append(configuration.arguments)
    self.timeoutSeconds.append(timeoutSeconds)

    switch outcomes[configuration.executable] ?? .failure {
    case .exit(let exitCode):
      return ContainerCommandResult(
        exitCode: exitCode,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false,
        duration: .zero
      )
    case .failure:
      throw ShellProbeError.unavailable
    case .cancellation:
      throw CancellationError()
    }
  }
}

private enum ShellProbeError: Error {
  case unavailable
}

private actor RecordingShellDiscovery: ContainerShellDiscovering {
  private let executable: String
  private(set) var containerIDs: [String] = []

  init(executable: String) {
    self.executable = executable
  }

  func discoverShell(in id: String) -> ContainerShell {
    containerIDs.append(id)
    return ContainerShell(executable: executable, source: .fallback)
  }
}

private actor RecordingResolvedTerminalLauncher: ContainerTerminalProcessLaunching {
  private let process: any ContainerTerminalProcess
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ResolvedContainerTerminalRequest] = []

  init(process: any ContainerTerminalProcess) {
    self.process = process
  }

  func makeProcess(
    containerID: String,
    request: ResolvedContainerTerminalRequest,
    standardInput: FileHandle,
    standardOutput: FileHandle
  ) -> any ContainerTerminalProcess {
    containerIDs.append(containerID)
    requests.append(request)
    return process
  }
}

private actor ShellTerminalProcess: ContainerTerminalProcess {
  private(set) var startCount = 0
  private var exitCode: Int32?

  func start() {
    startCount += 1
  }

  func wait() async throws -> Int32 {
    while exitCode == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    return exitCode ?? 0
  }

  func kill(_ signal: Int32) {
    exitCode = 128 + signal
  }

  func resize(to size: ContainerTerminalSize) {}
}
