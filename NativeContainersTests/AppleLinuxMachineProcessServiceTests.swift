import ContainerPersistence
import ContainerResource
import Darwin
import Foundation
import MachineAPIClient
import Testing

@testable import NativeContainers

@Suite("Linux machine process configuration")
struct LinuxMachineProcessConfigurationTests {
  @Test
  func commandUsesMachineShellMappedUserHomeAndExplicitEnvironment() throws {
    let target = makeProcessTarget()
    let request = try LinuxMachineCommandRequest(
      command: "printf '%s\\n' \"$HOME\"",
      environment: [
        try ContainerEnvironmentVariable(key: "PATH", value: "/custom/bin"),
        try ContainerEnvironmentVariable(key: "EXPLICIT", value: "yes"),
      ]
    )

    let configuration = try LinuxMachineProcessConfigurationFactory.command(
      target: target,
      request: request
    )

    #expect(configuration.executable == "/sbin.machine/init")
    #expect(configuration.arguments == ["-s", "printf '%s\\n' \"$HOME\""])
    #expect(configuration.user == .id(uid: 501, gid: 20))
    #expect(configuration.workingDirectory == "/home/developer")
    #expect(!configuration.terminal)
    #expect(Set(configuration.environment) == ["PATH=/custom/bin", "EXPLICIT=yes"])
  }

  @Test
  func terminalDiscoversGuestShellAndHonorsExplicitWorkingDirectory() throws {
    let request = try LinuxMachineTerminalRequest(
      environment: [try ContainerEnvironmentVariable(key: "TERM", value: "xterm-256color")],
      workingDirectory: "/workspace",
      initialSize: try ContainerTerminalSize(columns: 144, rows: 48)
    )

    let configuration = try LinuxMachineProcessConfigurationFactory.terminal(
      target: makeProcessTarget(),
      request: request
    )

    #expect(configuration.executable == "/sbin.machine/init")
    #expect(configuration.arguments == ["-s"])
    #expect(configuration.workingDirectory == "/workspace")
    #expect(configuration.user == .id(uid: 501, gid: 20))
    #expect(configuration.terminal)
    #expect(Set(configuration.environment).contains("TERM=xterm-256color"))
  }

  @Test
  func requestValidationModelsShellCommandsRatherThanExactArgv() {
    #expect(throws: LinuxMachineToolError.missingCommand) {
      try LinuxMachineCommandRequest(command: "  ")
    }
    #expect(throws: LinuxMachineToolError.invalidWorkingDirectory("relative")) {
      try LinuxMachineCommandRequest(command: "true", workingDirectory: "relative")
    }
  }
}

@Suite("Linux machine process target resolver")
struct LinuxMachineProcessTargetResolverTests {
  @Test
  func startsThenReinspectsTheStableMachineForItsFreshBackingContainer() async throws {
    let snapshot = try makeMachineSnapshot(initialized: true)
    let lifecycle = RecordingMachineLifecycle()
    let transport = ResolvingMachineTransport(snapshot: snapshot)
    let resolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: lifecycle,
      machineTransport: transport
    )
    let identity = machineIdentity(snapshot)

    let target = try await resolver.resolve(identity)

    #expect(target.identity == identity)
    #expect(target.backingContainerID == "dev-runtime")
    #expect(target.user == .id(uid: 501, gid: 20))
    #expect(target.homeDirectory == "/home/developer")
    #expect(await lifecycle.startedTargets == [identity])
    #expect(await transport.inspectedIDs == ["dev"])
  }

  @Test
  func refusesUnstableOrReplacedTargetsBeforeReturningAProcessAddress() async throws {
    let snapshot = try makeMachineSnapshot(initialized: true)
    let lifecycle = RecordingMachineLifecycle()
    let transport = ResolvingMachineTransport(snapshot: snapshot)
    let resolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: lifecycle,
      machineTransport: transport
    )
    let unstable = LinuxMachineIdentity(
      id: snapshot.id,
      imageReference: snapshot.configuration.image.reference,
      platform: String(describing: snapshot.platform),
      createdAt: nil
    )

    await #expect(throws: LinuxMachineManagementError.stableIdentityRequired("dev")) {
      try await resolver.resolve(unstable)
    }
    #expect(await lifecycle.startedTargets.isEmpty)
    #expect(await transport.inspectedIDs.isEmpty)

    let stale = LinuxMachineIdentity(
      id: snapshot.id,
      imageReference: snapshot.configuration.image.reference,
      platform: String(describing: snapshot.platform),
      createdAt: Date(timeIntervalSince1970: 99)
    )
    await #expect(throws: LinuxMachineManagementError.staleTarget("dev")) {
      try await resolver.resolve(stale)
    }
  }

  @Test
  func refusesUnreadyOrUnaddressablePostStartSnapshots() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let identity = machineIdentity(source)
    let lifecycle = RecordingMachineLifecycle()

    let stopped = MachineSnapshot(
      configuration: source.configuration,
      status: .stopped,
      bootConfig: source.bootConfig,
      createdDate: source.createdDate,
      diskSize: source.diskSize,
      initialized: true
    )
    let stoppedResolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: lifecycle,
      machineTransport: ResolvingMachineTransport(snapshot: stopped)
    )
    await #expect(throws: LinuxMachineManagementError.notRunning("dev")) {
      try await stoppedResolver.resolve(identity)
    }

    let noContainer = MachineSnapshot(
      configuration: source.configuration,
      status: .running,
      bootConfig: source.bootConfig,
      startedDate: source.startedDate,
      createdDate: source.createdDate,
      containerId: nil,
      ipAddress: source.ipAddress,
      diskSize: source.diskSize,
      initialized: true
    )
    let noContainerResolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: lifecycle,
      machineTransport: ResolvingMachineTransport(snapshot: noContainer)
    )
    await #expect(throws: LinuxMachineManagementError.backingContainerMissing("dev")) {
      try await noContainerResolver.resolve(identity)
    }
  }
}

@Suite("Apple Linux machine process service")
struct AppleLinuxMachineProcessServiceTests {
  @Test
  func commandDelegatesOnlyThePreparedBackingTarget() async throws {
    let target = makeProcessTarget()
    let resolver = FixedMachineProcessTargetResolver(target: target)
    let executor = RecordingCommandExecutor()
    let service = AppleLinuxMachineProcessService(
      targetResolver: resolver,
      commandExecutor: executor
    )
    let request = try LinuxMachineCommandRequest(command: "uname -a", timeoutSeconds: 17)

    let result = try await service.executeCommand(
      in: target.identity,
      request: request
    )

    #expect(result.exitCode == 0)
    #expect(await executor.containerIDs == ["dev-runtime"])
    #expect(await executor.timeoutSeconds == [17])
    #expect(await executor.configurations.first?.arguments == ["-s", "uname -a"])
  }

  @Test
  func terminalUsesSharedSessionLifecycleResizeAndKill() async throws {
    let target = makeProcessTarget()
    let processClient = RecordingMachineRuntimeProcessClient()
    let service = AppleLinuxMachineProcessService(
      targetResolver: FixedMachineProcessTargetResolver(target: target),
      processClient: processClient
    )
    let request = try LinuxMachineTerminalRequest(
      initialSize: try ContainerTerminalSize(columns: 101, rows: 37)
    )

    let session = try await service.openTerminal(in: target.identity, request: request)

    #expect(await processClient.containerIDs == ["dev-runtime"])
    #expect(await processClient.configurations.first?.arguments == ["-s"])
    #expect(await processClient.standardIOPresence == [[true, true, false]])
    #expect(await processClient.process.didStart)
    #expect(
      await processClient.process.sizes == [try ContainerTerminalSize(columns: 101, rows: 37)])

    try await session.sendSignal(.kill)
    #expect(try await session.wait() == 137)
    #expect(await processClient.process.signals == [SIGKILL])
  }
}

private func makeProcessTarget() -> LinuxMachineProcessTarget {
  LinuxMachineProcessTarget(
    identity: LinuxMachineIdentity(
      id: "dev",
      imageReference: "alpine:3.22",
      platform: "linux/arm64",
      createdAt: Date(timeIntervalSince1970: 1)
    ),
    backingContainerID: "dev-runtime",
    user: .id(uid: 501, gid: 20),
    homeDirectory: "/home/developer"
  )
}

private func machineIdentity(_ snapshot: MachineSnapshot) -> LinuxMachineIdentity {
  LinuxMachineIdentity(
    id: snapshot.id,
    imageReference: snapshot.configuration.image.reference,
    platform: String(describing: snapshot.platform),
    createdAt: snapshot.createdDate
  )
}

private actor RecordingMachineLifecycle: MachineLifecycleManaging {
  private(set) var startedTargets: [LinuxMachineIdentity] = []

  func startMachine(_ target: LinuxMachineIdentity) {
    startedTargets.append(target)
  }

  func stopMachine(_ target: LinuxMachineIdentity) {}
  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) {}
  func deleteMachine(_ target: LinuxMachineIdentity) {}
}

private actor ResolvingMachineTransport: AppleMachineTransport {
  private let snapshot: MachineSnapshot
  private(set) var inspectedIDs: [String] = []

  init(snapshot: MachineSnapshot) {
    self.snapshot = snapshot
  }

  func list() -> [MachineSnapshot] {
    [snapshot]
  }

  func inspect(id: String) -> MachineSnapshot {
    inspectedIDs.append(id)
    return snapshot
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) {}

  func boot(id: String, dynamicEnvironment: [String: String]) -> MachineSnapshot {
    snapshot
  }

  func stop(id: String) {}
  func delete(id: String) {}
}

private actor FixedMachineProcessTargetResolver: LinuxMachineProcessTargetResolving {
  let target: LinuxMachineProcessTarget

  init(target: LinuxMachineProcessTarget) {
    self.target = target
  }

  func resolve(_ target: LinuxMachineIdentity) -> LinuxMachineProcessTarget {
    self.target
  }
}

private actor RecordingCommandExecutor: RuntimeCommandExecuting {
  private(set) var containerIDs: [String] = []
  private(set) var configurations: [ProcessConfiguration] = []
  private(set) var timeoutSeconds: [Int] = []

  func execute(
    in containerID: String,
    configuration: ProcessConfiguration,
    timeoutSeconds: Int
  ) -> ContainerCommandResult {
    containerIDs.append(containerID)
    configurations.append(configuration)
    self.timeoutSeconds.append(timeoutSeconds)
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: "ok\\n",
      standardError: "",
      outputWasTruncated: false,
      duration: .zero
    )
  }
}

private actor RecordingMachineRuntimeProcessClient: AppleRuntimeProcessCreating {
  let process = RecordingMachineRuntimeProcess()
  private(set) var containerIDs: [String] = []
  private(set) var configurations: [ProcessConfiguration] = []
  private(set) var standardIOPresence: [[Bool]] = []

  func createRuntimeProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration,
    standardIO: [FileHandle?]
  ) -> any AppleRuntimeProcess {
    containerIDs.append(containerID)
    configurations.append(configuration)
    standardIOPresence.append(standardIO.map { $0 != nil })
    return process
  }
}

private actor RecordingMachineRuntimeProcess: AppleRuntimeProcess {
  private var waitContinuation: CheckedContinuation<Int32, any Error>?
  private(set) var didStart = false
  private(set) var sizes: [ContainerTerminalSize] = []
  private(set) var signals: [Int32] = []

  func start() {
    didStart = true
  }

  func wait() async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
      waitContinuation = continuation
    }
  }

  func kill(_ signal: Int32) {
    signals.append(signal)
    waitContinuation?.resume(returning: 128 + signal)
    waitContinuation = nil
  }

  func resize(to size: ContainerTerminalSize) {
    sizes.append(size)
  }
}
