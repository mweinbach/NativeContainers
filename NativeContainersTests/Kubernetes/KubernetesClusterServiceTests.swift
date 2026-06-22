import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct KubernetesClusterServiceTests {
  @Test
  func provisionRequestEnforcesK3sResourcesAndSafeImageReference() throws {
    #expect(throws: KubernetesClusterError.insufficientCPU) {
      _ = try KubernetesClusterProvisionRequest(cpuCount: 1)
    }
    #expect(throws: KubernetesClusterError.insufficientMemory) {
      _ = try KubernetesClusterProvisionRequest(
        memoryBytes: KubernetesClusterProvisionRequest.minimumMemoryBytes - 1
      )
    }
    #expect(throws: KubernetesClusterError.invalidImageReference) {
      _ = try KubernetesClusterProvisionRequest(imageReference: "alpine:latest; bad")
    }

    let request = try KubernetesClusterProvisionRequest()
    let machine = try request.machineCreationRequest()
    #expect(machine.architecture == .arm64)
    #expect(machine.homeMount == .none)
    #expect(machine.startAfterCreation)
    #expect(machine.cpuCount == 4)
    #expect(machine.memoryBytes == KubernetesClusterProvisionRequest.defaultMemoryBytes)
  }

  @Test
  func rootCommandUsesAppleProcessTransportAsUIDZero() async throws {
    let identity = stableIdentity()
    let target = LinuxMachineProcessTarget(
      identity: identity,
      backingContainerID: "backing-container",
      user: .id(uid: 501, gid: 20),
      homeDirectory: "/home/developer"
    )
    let resolver = StaticKubernetesTargetResolver(target: target)
    let executor = CapturingKubernetesCommandExecutor()
    let service = AppleKubernetesMachineRootCommandService(
      targetResolver: resolver,
      commandExecutor: executor
    )

    _ = try await service.executeRootCommand(
      "id -u",
      in: identity,
      timeoutSeconds: 12
    )

    let capture = try #require(await executor.capture)
    #expect(capture.containerID == "backing-container")
    #expect(capture.timeoutSeconds == 12)
    #expect(capture.configuration.user == .id(uid: 0, gid: 0))
    #expect(capture.configuration.terminal == false)
    #expect(capture.configuration.workingDirectory == "/")
    #expect(capture.configuration.arguments == ["-s", "id -u"])
  }

  @Test
  func provisionsPinnedClusterExportsKubeconfigAndOwnsLifecycle() async throws {
    let runtime = KubernetesMachineRuntimeDouble()
    let commands = KubernetesRootCommandDouble()
    let store = InMemoryKubernetesDescriptorStore()
    let service = makeService(runtime: runtime, commands: commands, store: store)
    let progress = KubernetesProgressRecorder()
    let request = try KubernetesClusterProvisionRequest(
      operationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    let snapshot = try await service.provision(request) { update in
      await progress.append(update)
    }

    #expect(snapshot.state == .ready)
    #expect(snapshot.k3sVersion == "k3s version v1.36.1+k3s1 (test)")
    #expect(snapshot.nodeCount == 1)
    #expect(snapshot.readyNodeCount == 1)
    #expect(snapshot.podCount == 2)
    #expect(snapshot.runningPodCount == 1)

    let creation = try #require(await runtime.creationRequests.first)
    #expect(creation.name == KubernetesClusterProvisionRequest.defaultMachineName)
    #expect(creation.homeMount == .none)
    #expect(creation.memoryBytes == KubernetesClusterProvisionRequest.defaultMemoryBytes)

    let descriptor = try #require(await store.descriptor)
    #expect(descriptor.phase == .ready)
    #expect(descriptor.operationID == request.operationID)
    #expect(descriptor.distribution == .current)

    let bootstrap = try #require(
      await commands.commands.first(where: {
        $0.command.contains("nativecontainers-k3s-install.sh")
      })
    )
    #expect(
      bootstrap.command.contains(KubernetesDistribution.current.installScriptSHA256)
    )
    #expect(bootstrap.command.contains(KubernetesDistribution.current.version))
    #expect(bootstrap.command.contains("--secrets-encryption"))
    #expect(bootstrap.command.contains("--write-kubeconfig-mode=600"))
    #expect(bootstrap.command.contains("INSTALL_K3S_SKIP_ENABLE=true"))
    #expect(bootstrap.command.contains("NativeContainers prepares cgroup v2"))
    #expect(bootstrap.command.contains("rc-update del k3s default"))
    #expect(bootstrap.command.contains("systemctl enable k3s"))
    #expect(bootstrap.timeoutSeconds == 900)

    let activation = try #require(
      await commands.commands.first(where: {
        $0.command.contains("touch /run/openrc/softlevel")
      })
    )
    #expect(activation.command.contains("nativecontainers-system"))
    #expect(activation.command.contains("cgroup.procs"))
    #expect(activation.command.contains("cgroup.subtree_control"))
    #expect(activation.command.contains("/etc/init.d/k3s status"))
    #expect(activation.command.contains("/etc/init.d/k3s stop"))
    #expect(activation.command.contains("/etc/init.d/k3s start"))
    #expect(activation.command.contains("systemctl start k3s"))
    #expect(activation.timeoutSeconds == 60)

    let readiness = try #require(
      await commands.commands.first(where: {
        $0.command.contains("get --raw=/readyz")
      })
    )
    #expect(readiness.command.contains("/etc/rancher/k3s/k3s.yaml"))
    #expect(readiness.command.contains("/run/flannel/subnet.env"))
    #expect(readiness.command.contains("get serviceaccount default"))
    #expect(readiness.command.contains("get nodes --no-headers"))
    #expect(readiness.command.contains("+Ready"))
    #expect(readiness.command.contains("stat -c '%a'"))

    let observation = try #require(
      await commands.commands.first(where: {
        $0.command.contains("__NATIVECONTAINERS_K3S_VERSION__")
      })
    )
    #expect(observation.command.contains(#"{"\t"}"#))
    #expect(observation.command.contains(#"{"\n"}"#))

    let phases = await progress.updates.map(\.phase)
    #expect(phases.contains(.creatingMachine))
    #expect(phases.contains(.preparingGuest))
    #expect(phases.contains(.installingK3s))
    #expect(phases.contains(.waitingForReadiness))
    #expect(phases.last == .completed)

    let exported = try await service.exportKubeconfig()
    let kubeconfig = try #require(String(data: exported.data, encoding: .utf8))
    #expect(kubeconfig.contains("server: https://192.168.64.42:6443"))
    #expect(!kubeconfig.contains("server: https://127.0.0.1:6443"))
    #expect(exported.fileName == "NativeContainers-nativecontainers-kubernetes-kubeconfig.yaml")

    let stopped = try await service.stop()
    #expect(stopped.state == .stopped)
    let started = try await service.start()
    #expect(started.state == .ready)
    #expect(
      await commands.commands.filter {
        $0.command.contains("touch /run/openrc/softlevel")
      }.count == 2
    )
    let forced = try await service.forceStop()
    #expect(forced.state == .stopped)
    #expect(await runtime.forceStopCount == 1)

    try await service.delete()
    #expect(await store.descriptor == nil)
    #expect(await runtime.currentMachine == nil)
  }

  @Test
  func failedBootstrapRetainsExactPendingDescriptorForRetry() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble(bootstrapFailures: 1)
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .provisioning,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let service = makeService(runtime: runtime, commands: commands, store: store)

    await #expect(throws: KubernetesClusterError.self) {
      _ = try await service.retryProvisioning { _ in }
    }
    #expect(await store.descriptor?.phase == .provisioning)

    let snapshot = try await service.retryProvisioning { _ in }
    #expect(snapshot.state == .ready)
    #expect(await store.descriptor?.phase == .ready)
    #expect(await commands.bootstrapInvocationCount == 2)
  }

  @Test
  func staleMachineIdentityIsVisibleAndNeverAddressed() async throws {
    let descriptorMachine = makeMachine()
    let replacement = makeMachine(
      createdAt: Date(timeIntervalSince1970: 1_700_000_500)
    )
    let runtime = KubernetesMachineRuntimeDouble(machine: replacement)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: descriptorMachine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let service = makeService(runtime: runtime, commands: commands, store: store)

    let snapshot = try await service.load()
    #expect(snapshot.state == .stale)
    #expect(snapshot.machine == replacement)

    await #expect(
      throws: KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    ) {
      _ = try await service.start()
    }
    #expect(await runtime.startCount == 0)
    #expect(await commands.commands.isEmpty)

    try await service.forget()
    #expect(await store.descriptor == nil)
    #expect(await runtime.currentMachine == replacement)
  }

  @Test
  func kubeconfigExportRejectsMissingAddressAndMalformedSecretDocument() async throws {
    let machine = makeMachine(ipAddress: nil)
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let commands = KubernetesRootCommandDouble()
    let service = makeService(runtime: runtime, commands: commands, store: store)

    await #expect(throws: KubernetesClusterError.missingIPAddress) {
      _ = try await service.exportKubeconfig()
    }

    await runtime.setMachine(makeMachine())
    await commands.setKubeconfig("apiVersion: v1\nclusters: []\n")
    await #expect(throws: KubernetesClusterError.invalidKubeconfig) {
      _ = try await service.exportKubeconfig()
    }
  }

  private func makeService(
    runtime: KubernetesMachineRuntimeDouble,
    commands: KubernetesRootCommandDouble,
    store: InMemoryKubernetesDescriptorStore
  ) -> AppleKubernetesClusterService {
    AppleKubernetesClusterService(
      machineCreator: runtime,
      machineLifecycle: runtime,
      machineInventory: runtime,
      rootCommands: commands,
      store: store,
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
  }
}

@MainActor
@Suite("Kubernetes cluster model")
struct KubernetesClusterModelTests {
  @Test
  func publishesProgressAndRefreshesTheAppAfterProvisioning() async throws {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: .absent)
    await service.setProvisionedSnapshot(snapshot)
    let mutations = KubernetesMutationCounter()
    let model = KubernetesClusterModel(service: service) {
      mutations.count += 1
    }

    let result = await model.provision(
      try KubernetesClusterProvisionRequest()
    )

    #expect(result)
    #expect(model.snapshot == snapshot)
    #expect(model.progress?.phase == .completed)
    #expect(model.errorMessage == nil)
    #expect(mutations.count == 1)
  }

  @Test
  func failedMutationKeepsTheErrorAndReloadsAuthoritativeState() async {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: snapshot)
    await service.setStopError(.readinessTimedOut)
    let model = KubernetesClusterModel(
      service: service,
      initialSnapshot: snapshot
    )

    let result = await model.stop()

    #expect(!result)
    #expect(model.snapshot == snapshot)
    #expect(model.errorMessage == KubernetesClusterError.readinessTimedOut.localizedDescription)
    #expect(await service.loadCount == 1)
  }
}

private actor InMemoryKubernetesDescriptorStore:
  KubernetesClusterDescriptorStoring
{
  var descriptor: KubernetesClusterDescriptor?

  init(descriptor: KubernetesClusterDescriptor? = nil) {
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
}

private actor KubernetesModelServiceDouble: KubernetesClusterManaging {
  private(set) var loadCount = 0
  private var snapshot: KubernetesClusterSnapshot
  private var provisionedSnapshot: KubernetesClusterSnapshot
  private var stopError: KubernetesClusterError?

  init(snapshot: KubernetesClusterSnapshot) {
    self.snapshot = snapshot
    provisionedSnapshot = snapshot
  }

  func load() -> KubernetesClusterSnapshot {
    loadCount += 1
    return snapshot
  }

  func provision(
    _ request: KubernetesClusterProvisionRequest,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    await progress(
      KubernetesClusterProgress(
        phase: .completed,
        detail: KubernetesDistribution.current.version,
        fractionCompleted: 1
      )
    )
    snapshot = provisionedSnapshot
    return snapshot
  }

  func retryProvisioning(
    progress: @escaping KubernetesClusterProgressHandler
  ) -> KubernetesClusterSnapshot {
    snapshot
  }

  func start() -> KubernetesClusterSnapshot {
    snapshot
  }

  func stop() throws -> KubernetesClusterSnapshot {
    if let stopError {
      throw stopError
    }
    return snapshot
  }

  func forceStop() -> KubernetesClusterSnapshot {
    snapshot
  }

  func delete() {
    snapshot = .absent
  }

  func forget() {
    snapshot = .absent
  }

  func exportKubeconfig() -> KubernetesKubeconfigExport {
    KubernetesKubeconfigExport(
      fileName: "kubeconfig.yaml",
      data: Data("apiVersion: v1\n".utf8)
    )
  }

  func setProvisionedSnapshot(_ snapshot: KubernetesClusterSnapshot) {
    provisionedSnapshot = snapshot
  }

  func setStopError(_ error: KubernetesClusterError?) {
    stopError = error
  }
}

@MainActor
private final class KubernetesMutationCounter {
  var count = 0
}

private actor KubernetesMachineRuntimeDouble:
  MachineCreating,
  MachineLifecycleManaging,
  LinuxMachineInventoryLoading
{
  private(set) var currentMachine: LinuxMachineRecord?
  private(set) var creationRequests: [LinuxMachineCreationRequest] = []
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var forceStopCount = 0

  init(machine: LinuxMachineRecord? = nil) {
    currentMachine = machine
  }

  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    creationRequests.append(request)
    await progress(
      ContainerOperationProgress(
        phase: .creating,
        message: "Creating machine",
        completedItems: 1,
        totalItems: 1
      )
    )
    let machine = makeMachine(
      name: request.name,
      imageReference: request.imageReference,
      state: request.startAfterCreation ? .running : .stopped,
      cpuCount: request.cpuCount,
      memoryBytes: request.memoryBytes
    )
    currentMachine = machine
    return LinuxMachineCreationResult(
      identity: LinuxMachineIdentity(machine: machine),
      state: machine.state,
      isInitialized: machine.isInitialized
    )
  }

  func startMachine(_ target: LinuxMachineIdentity) throws {
    let machine = try require(target)
    startCount += 1
    currentMachine = copy(machine, state: .running)
  }

  func stopMachine(_ target: LinuxMachineIdentity) throws {
    let machine = try require(target)
    stopCount += 1
    currentMachine = copy(machine, state: .stopped)
  }

  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) throws {
    let machine = try require(target)
    guard authorization == .confirmed(for: target) else {
      throw KubernetesClusterError.machineIdentityChanged(target.id)
    }
    forceStopCount += 1
    currentMachine = copy(machine, state: .stopped)
  }

  func deleteMachine(_ target: LinuxMachineIdentity) throws {
    _ = try require(target)
    currentMachine = nil
  }

  func loadMachines() -> [LinuxMachineRecord] {
    currentMachine.map { [$0] } ?? []
  }

  func setMachine(_ machine: LinuxMachineRecord?) {
    currentMachine = machine
  }

  private func require(_ target: LinuxMachineIdentity) throws -> LinuxMachineRecord {
    guard let machine = currentMachine else {
      throw KubernetesClusterError.machineMissing(target.id)
    }
    guard LinuxMachineIdentity(machine: machine) == target else {
      throw KubernetesClusterError.machineIdentityChanged(target.id)
    }
    return machine
  }

  private func copy(
    _ machine: LinuxMachineRecord,
    state: RuntimeState
  ) -> LinuxMachineRecord {
    LinuxMachineRecord(
      id: machine.id,
      imageReference: machine.imageReference,
      platform: machine.platform,
      state: state,
      ipAddress: machine.ipAddress,
      createdAt: machine.createdAt,
      startedAt: state == .running ? Date(timeIntervalSince1970: 1_700_000_200) : nil,
      diskSizeBytes: machine.diskSizeBytes,
      cpuCount: machine.cpuCount,
      memoryBytes: machine.memoryBytes,
      homeMount: machine.homeMount,
      isInitialized: machine.isInitialized
    )
  }
}

private actor KubernetesRootCommandDouble: KubernetesMachineRootCommandRunning {
  struct Invocation: Sendable {
    let command: String
    let target: LinuxMachineIdentity
    let timeoutSeconds: Int
  }

  private(set) var commands: [Invocation] = []
  private(set) var bootstrapInvocationCount = 0
  private var bootstrapFailures: Int
  private var kubeconfig: String

  init(
    bootstrapFailures: Int = 0,
    kubeconfig: String = """
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: Q0E=
        server: https://127.0.0.1:6443
      name: default
    contexts:
    - context:
        cluster: default
        user: default
      name: default
    current-context: default
    kind: Config
    users:
    - name: default
      user:
        client-certificate-data: Q0VSVA==
        client-key-data: S0VZ
    """
  ) {
    self.bootstrapFailures = bootstrapFailures
    self.kubeconfig = kubeconfig
  }

  func executeRootCommand(
    _ command: String,
    in target: LinuxMachineIdentity,
    timeoutSeconds: Int
  ) -> ContainerCommandResult {
    commands.append(
      Invocation(
        command: command,
        target: target,
        timeoutSeconds: timeoutSeconds
      )
    )

    if command.contains("nativecontainers-k3s-install.sh") {
      bootstrapInvocationCount += 1
      if bootstrapFailures > 0 {
        bootstrapFailures -= 1
        return result(exitCode: 1, standardError: "bootstrap failed")
      }
      return result()
    }
    if command.contains("touch /run/openrc/softlevel") {
      return result()
    }
    if command.contains("get --raw=/readyz") {
      return result(standardOutput: "ok\n")
    }
    if command.contains("__NATIVECONTAINERS_K3S_VERSION__") {
      return result(
        standardOutput: """
          __NATIVECONTAINERS_K3S_VERSION__
          k3s version v1.36.1+k3s1 (test)
          __NATIVECONTAINERS_K3S_NODES__
          nativecontainers-kubernetes\tTrue
          __NATIVECONTAINERS_K3S_PODS__
          Running
          Pending

          """
      )
    }
    if command.contains("/etc/rancher/k3s/k3s.yaml") {
      return result(standardOutput: kubeconfig)
    }
    return result(exitCode: 127, standardError: "unexpected command")
  }

  func setKubeconfig(_ value: String) {
    kubeconfig = value
  }

  private func result(
    exitCode: Int32 = 0,
    standardOutput: String = "",
    standardError: String = ""
  ) -> ContainerCommandResult {
    ContainerCommandResult(
      exitCode: exitCode,
      standardOutput: standardOutput,
      standardError: standardError,
      outputWasTruncated: false,
      duration: .zero
    )
  }
}

private actor KubernetesProgressRecorder {
  private(set) var updates: [KubernetesClusterProgress] = []

  func append(_ update: KubernetesClusterProgress) {
    updates.append(update)
  }
}

private struct StaticKubernetesTargetResolver:
  LinuxMachineProcessTargetResolving
{
  let target: LinuxMachineProcessTarget

  func resolve(_ target: LinuxMachineIdentity) async throws -> LinuxMachineProcessTarget {
    guard target == self.target.identity else {
      throw KubernetesClusterError.machineIdentityChanged(target.id)
    }
    return self.target
  }
}

private actor CapturingKubernetesCommandExecutor: RuntimeCommandExecuting {
  struct Capture: Sendable {
    let containerID: String
    let configuration: ProcessConfiguration
    let timeoutSeconds: Int
  }

  private(set) var capture: Capture?

  func execute(
    in containerID: String,
    configuration: ProcessConfiguration,
    timeoutSeconds: Int
  ) -> ContainerCommandResult {
    capture = Capture(
      containerID: containerID,
      configuration: configuration,
      timeoutSeconds: timeoutSeconds
    )
    return ContainerCommandResult(
      exitCode: 0,
      standardOutput: "0\n",
      standardError: "",
      outputWasTruncated: false,
      duration: .zero
    )
  }
}

private func readyKubernetesSnapshot() -> KubernetesClusterSnapshot {
  let machine = makeMachine()
  let descriptor = KubernetesClusterDescriptor(
    operationID: UUID(),
    machine: LinuxMachineIdentity(machine: machine),
    distribution: .current,
    phase: .ready,
    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
  )
  return KubernetesClusterSnapshot(
    state: .ready,
    descriptor: descriptor,
    machine: machine,
    k3sVersion: "k3s version v1.36.1+k3s1",
    nodeCount: 1,
    readyNodeCount: 1,
    podCount: 2,
    runningPodCount: 2
  )
}

private func stableIdentity() -> LinuxMachineIdentity {
  LinuxMachineIdentity(machine: makeMachine())
}

private func makeMachine(
  name: String = KubernetesClusterProvisionRequest.defaultMachineName,
  imageReference: String = KubernetesClusterProvisionRequest.defaultImageReference,
  state: RuntimeState = .running,
  ipAddress: String? = "192.168.64.42",
  createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  cpuCount: Int = 4,
  memoryBytes: UInt64 = KubernetesClusterProvisionRequest.defaultMemoryBytes
) -> LinuxMachineRecord {
  LinuxMachineRecord(
    id: name,
    imageReference: imageReference,
    platform: "linux/arm64",
    state: state,
    ipAddress: ipAddress,
    createdAt: createdAt,
    startedAt: state == .running ? Date(timeIntervalSince1970: 1_700_000_050) : nil,
    diskSizeBytes: 20 * 1_024 * 1_024 * 1_024,
    cpuCount: cpuCount,
    memoryBytes: memoryBytes,
    homeMount: .none,
    isInitialized: true
  )
}
