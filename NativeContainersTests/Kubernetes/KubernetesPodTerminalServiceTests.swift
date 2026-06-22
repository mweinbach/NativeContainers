import ContainerResource
import Foundation
import MachineAPIClient
import Testing

@testable import NativeContainers

@Suite("Kubernetes Pod terminal")
struct KubernetesPodTerminalServiceTests {
  @Test
  func runningTargetResolverRequiresExactReadyRunningMachine() async throws {
    let machine = podTerminalMachine()
    let descriptor = podTerminalDescriptor(machine: machine)
    let store = PodTerminalDescriptorStore(descriptor: descriptor)
    let inventory = PodTerminalMachineInventory(machines: [machine])
    let resolver = AppleKubernetesRunningClusterTargetResolver(
      store: store,
      machineInventory: inventory
    )

    let target = try await resolver.resolveRunningTarget(
      expectedMachine: descriptor.machine
    )

    #expect(target.descriptor == descriptor)
    #expect(target.machine == machine)

    let replacement = LinuxMachineIdentity(
      id: descriptor.machine.id,
      imageReference: descriptor.machine.imageReference,
      platform: descriptor.machine.platform,
      createdAt: Date(timeIntervalSince1970: 1_700_000_999)
    )
    await #expect(
      throws: KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    ) {
      _ = try await resolver.resolveRunningTarget(expectedMachine: replacement)
    }

    await inventory.replace(
      machines: [podTerminalMachine(state: .stopped)]
    )
    await #expect(
      throws: KubernetesClusterError.machineNotRunning(descriptor.machine.id)
    ) {
      _ = try await resolver.resolveRunningTarget(
        expectedMachine: descriptor.machine
      )
    }

    await store.replace(
      descriptor: podTerminalDescriptor(
        machine: machine,
        phase: .provisioning
      )
    )
    await #expect(throws: KubernetesClusterError.setupNotRetryable) {
      _ = try await resolver.resolveRunningTarget(
        expectedMachine: descriptor.machine
      )
    }
  }

  @Test
  func opensExplicitContainerPTYWithPinnedPodIdentity() async throws {
    let machine = podTerminalMachine()
    let identity = podTerminalIdentity(machine: machine)
    let runningResolver = PodTerminalRunningTargetResolver(
      target: KubernetesRunningClusterTarget(
        descriptor: podTerminalDescriptor(machine: machine),
        machine: machine
      )
    )
    let rootCommands = PodTerminalRootCommandRecorder(
      result: podTerminalCommandResult(
        standardOutput:
          "\(AppleKubernetesPodTerminalService.shellDiscoveryMarker)/bin/ash\n"
      )
    )
    let processResolver = PodTerminalProcessTargetResolver(
      target: LinuxMachineProcessTarget(
        identity: LinuxMachineIdentity(machine: machine),
        backingContainerID: "fresh-k3s-backing-container",
        user: .id(uid: 501, gid: 20),
        homeDirectory: "/home/developer"
      )
    )
    let launcher = PodTerminalSessionLauncherRecorder()
    let service = AppleKubernetesPodTerminalService(
      runningTargetResolver: runningResolver,
      rootCommands: rootCommands,
      machineProcessTargetResolver: processResolver,
      sessionLauncher: launcher
    )
    let request = try ContainerTerminalRequest(
      initialSize: ContainerTerminalSize(columns: 132, rows: 48),
      maximumRetainedOutputBytes: 2 * 1_024 * 1_024
    )

    _ = try await service.openTerminal(in: identity, request: request)

    #expect(
      await runningResolver.expectedMachines
        == [identity.machine, identity.machine]
    )
    #expect(await processResolver.requestedTargets == [identity.machine])

    let discovery = try #require(await rootCommands.invocations.first)
    #expect(discovery.target == identity.machine)
    #expect(discovery.timeoutSeconds == 45)
    #expect(discovery.command.contains("kubectl get pod"))
    #expect(
      discovery.command.components(separatedBy: "kubectl get pod").count - 1
        == 2
    )
    #expect(discovery.command.contains(identity.podUID))
    #expect(discovery.command.contains("--namespace=default"))
    #expect(discovery.command.contains("--container=api"))
    #expect(discovery.command.contains("--pod-running-timeout=5s"))
    #expect(discovery.command.contains("/bin/ash"))

    let capture = try #require(await launcher.captures.first)
    #expect(capture.backingContainerID == "fresh-k3s-backing-container")
    #expect(capture.request == request)
    #expect(
      capture.configuration.executable
        == "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)"
    )
    #expect(capture.configuration.arguments.first == "-s")
    #expect(capture.configuration.terminal)
    #expect(capture.configuration.user == .id(uid: 0, gid: 0))
    #expect(capture.configuration.workingDirectory == "/")

    let command = try #require(capture.configuration.arguments.last)
    #expect(command.contains("kubectl get pod"))
    #expect(command.contains(identity.podUID))
    #expect(command.contains("kubectl exec"))
    #expect(command.contains("--namespace=default"))
    #expect(command.contains("--container=api"))
    #expect(command.contains("--stdin=true"))
    #expect(command.contains("--tty=true"))
    #expect(command.contains("--pod-running-timeout=15s"))
    #expect(command.contains("api-abc"))
    #expect(command.contains("-- /bin/ash"))
  }

  @Test
  func rejectsUnsafeIdentityAndCustomCommandBeforeGuestAccess() async throws {
    let machine = podTerminalMachine()
    let runningResolver = PodTerminalRunningTargetResolver(
      target: KubernetesRunningClusterTarget(
        descriptor: podTerminalDescriptor(machine: machine),
        machine: machine
      )
    )
    let rootCommands = PodTerminalRootCommandRecorder(
      result: podTerminalCommandResult(
        standardOutput:
          "\(AppleKubernetesPodTerminalService.shellDiscoveryMarker)/bin/sh\n"
      )
    )
    let launcher = PodTerminalSessionLauncherRecorder()
    let service = AppleKubernetesPodTerminalService(
      runningTargetResolver: runningResolver,
      rootCommands: rootCommands,
      machineProcessTargetResolver: PodTerminalProcessTargetResolver(
        target: podTerminalProcessTarget(machine: machine)
      ),
      sessionLauncher: launcher
    )
    let unsafe = KubernetesPodTerminalIdentity(
      machine: LinuxMachineIdentity(machine: machine),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc$(touch-pwned)",
      containerName: "api"
    )

    await #expect(
      throws: KubernetesClusterError.invalidKubernetesResourceReference
    ) {
      _ = try await service.openTerminal(
        in: unsafe,
        request: try ContainerTerminalRequest()
      )
    }

    await #expect(
      throws: KubernetesClusterError.unsupportedPodTerminalRequest
    ) {
      _ = try await service.openTerminal(
        in: podTerminalIdentity(machine: machine),
        request: try ContainerTerminalRequest(arguments: ["-l"])
      )
    }

    #expect(await runningResolver.expectedMachines.isEmpty)
    #expect(await rootCommands.invocations.isEmpty)
    #expect(await launcher.captures.isEmpty)
  }

  @Test
  func rejectsUntrustedShellDiscoveryResultsAndPodReplacement() async throws {
    let machine = podTerminalMachine()
    let rootCommands = PodTerminalRootCommandRecorder(
      result: podTerminalCommandResult(
        standardOutput:
          "\(AppleKubernetesPodTerminalService.shellDiscoveryMarker)/bin/fish\n"
      )
    )
    let launcher = PodTerminalSessionLauncherRecorder()
    let service = AppleKubernetesPodTerminalService(
      runningTargetResolver: PodTerminalRunningTargetResolver(
        target: KubernetesRunningClusterTarget(
          descriptor: podTerminalDescriptor(machine: machine),
          machine: machine
        )
      ),
      rootCommands: rootCommands,
      machineProcessTargetResolver: PodTerminalProcessTargetResolver(
        target: podTerminalProcessTarget(machine: machine)
      ),
      sessionLauncher: launcher
    )
    let identity = podTerminalIdentity(machine: machine)
    let request = try ContainerTerminalRequest()

    await #expect(
      throws: KubernetesClusterError.invalidPodShellDiscovery
    ) {
      _ = try await service.openTerminal(in: identity, request: request)
    }

    await rootCommands.replace(
      result: podTerminalCommandResult(exitCode: 66)
    )
    await #expect(
      throws: KubernetesClusterError.podIdentityChanged(identity.podName)
    ) {
      _ = try await service.openTerminal(in: identity, request: request)
    }

    await rootCommands.replace(
      result: podTerminalCommandResult(exitCode: 67)
    )
    await #expect(throws: KubernetesClusterError.podShellUnavailable) {
      _ = try await service.openTerminal(in: identity, request: request)
    }

    await rootCommands.replace(
      result: podTerminalCommandResult(
        standardOutput:
          "\(AppleKubernetesPodTerminalService.shellDiscoveryMarker)/bin/sh\n",
        outputWasTruncated: true
      )
    )
    await #expect(throws: KubernetesClusterError.guestOutputTooLarge) {
      _ = try await service.openTerminal(in: identity, request: request)
    }

    #expect(await launcher.captures.isEmpty)
  }
}

private actor PodTerminalDescriptorStore:
  KubernetesClusterDescriptorStoring
{
  private var descriptor: KubernetesClusterDescriptor?

  init(descriptor: KubernetesClusterDescriptor?) {
    self.descriptor = descriptor
  }

  func load() -> KubernetesClusterDescriptor? {
    descriptor
  }

  func save(_ descriptor: KubernetesClusterDescriptor) {
    self.descriptor = descriptor
  }

  func remove() {
    descriptor = nil
  }

  func replace(descriptor: KubernetesClusterDescriptor?) {
    self.descriptor = descriptor
  }
}

private actor PodTerminalMachineInventory: LinuxMachineInventoryLoading {
  private var machines: [LinuxMachineRecord]

  init(machines: [LinuxMachineRecord]) {
    self.machines = machines
  }

  func loadMachines() -> [LinuxMachineRecord] {
    machines
  }

  func replace(machines: [LinuxMachineRecord]) {
    self.machines = machines
  }
}

private actor PodTerminalRunningTargetResolver:
  KubernetesRunningClusterTargetResolving
{
  let target: KubernetesRunningClusterTarget
  private(set) var expectedMachines: [LinuxMachineIdentity?] = []

  init(target: KubernetesRunningClusterTarget) {
    self.target = target
  }

  func resolveRunningTarget(
    expectedMachine: LinuxMachineIdentity?
  ) -> KubernetesRunningClusterTarget {
    expectedMachines.append(expectedMachine)
    return target
  }
}

private actor PodTerminalRootCommandRecorder:
  KubernetesMachineRootCommandRunning
{
  struct Invocation: Sendable {
    let command: String
    let target: LinuxMachineIdentity
    let timeoutSeconds: Int
  }

  private var result: ContainerCommandResult
  private(set) var invocations: [Invocation] = []

  init(result: ContainerCommandResult) {
    self.result = result
  }

  func executeRootCommand(
    _ command: String,
    in target: LinuxMachineIdentity,
    timeoutSeconds: Int
  ) -> ContainerCommandResult {
    invocations.append(
      Invocation(
        command: command,
        target: target,
        timeoutSeconds: timeoutSeconds
      )
    )
    return result
  }

  func replace(result: ContainerCommandResult) {
    self.result = result
  }
}

private actor PodTerminalProcessTargetResolver:
  LinuxMachineProcessTargetResolving
{
  let target: LinuxMachineProcessTarget
  private(set) var requestedTargets: [LinuxMachineIdentity] = []

  init(target: LinuxMachineProcessTarget) {
    self.target = target
  }

  func resolve(_ target: LinuxMachineIdentity) -> LinuxMachineProcessTarget {
    requestedTargets.append(target)
    return self.target
  }
}

private actor PodTerminalSessionLauncherRecorder:
  KubernetesPodTerminalSessionLaunching
{
  struct Capture: Sendable {
    let backingContainerID: String
    let configuration: ProcessConfiguration
    let request: ContainerTerminalRequest
  }

  private(set) var captures: [Capture] = []

  func openSession(
    backingContainerID: String,
    configuration: ProcessConfiguration,
    request: ContainerTerminalRequest
  ) -> any ContainerTerminalSession {
    captures.append(
      Capture(
        backingContainerID: backingContainerID,
        configuration: configuration,
        request: request
      )
    )
    return PodTerminalTestSession()
  }
}

private actor PodTerminalTestSession: ContainerTerminalSession {
  nonisolated let output = AsyncStream<Data> { continuation in
    continuation.finish()
  }

  func sendInput(_ data: Data) {}

  func resize(to size: ContainerTerminalSize) {}

  func sendSignal(_ signal: ContainerTerminalSignal) {}

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: .running,
      retainedOutput: Data(),
      outputWasTruncated: false
    )
  }

  func wait() -> Int32 {
    0
  }

  func close() {}
}

private func podTerminalMachine(
  state: RuntimeState = .running
) -> LinuxMachineRecord {
  LinuxMachineRecord(
    id: KubernetesClusterProvisionRequest.defaultMachineName,
    imageReference: KubernetesClusterProvisionRequest.defaultImageReference,
    platform: "linux/arm64",
    state: state,
    ipAddress: "192.168.64.42",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    startedAt:
      state == .running
      ? Date(timeIntervalSince1970: 1_700_000_050)
      : nil,
    diskSizeBytes: 20 * 1_024 * 1_024 * 1_024,
    cpuCount: 4,
    memoryBytes: KubernetesClusterProvisionRequest.defaultMemoryBytes,
    homeMount: .none,
    isInitialized: true
  )
}

private func podTerminalDescriptor(
  machine: LinuxMachineRecord,
  phase: KubernetesClusterDescriptorPhase = .ready
) -> KubernetesClusterDescriptor {
  KubernetesClusterDescriptor(
    operationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
    machine: LinuxMachineIdentity(machine: machine),
    distribution: .current,
    phase: phase,
    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
  )
}

private func podTerminalIdentity(
  machine: LinuxMachineRecord
) -> KubernetesPodTerminalIdentity {
  KubernetesPodTerminalIdentity(
    machine: LinuxMachineIdentity(machine: machine),
    podUID: "11111111-1111-4111-8111-111111111111",
    namespace: "default",
    podName: "api-abc",
    containerName: "api"
  )
}

private func podTerminalProcessTarget(
  machine: LinuxMachineRecord
) -> LinuxMachineProcessTarget {
  LinuxMachineProcessTarget(
    identity: LinuxMachineIdentity(machine: machine),
    backingContainerID: "fresh-k3s-backing-container",
    user: .id(uid: 501, gid: 20),
    homeDirectory: "/home/developer"
  )
}

private func podTerminalCommandResult(
  exitCode: Int32 = 0,
  standardOutput: String = "",
  outputWasTruncated: Bool = false
) -> ContainerCommandResult {
  ContainerCommandResult(
    exitCode: exitCode,
    standardOutput: standardOutput,
    standardError: "",
    outputWasTruncated: outputWasTruncated,
    duration: .zero
  )
}
