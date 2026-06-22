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
    #expect(bootstrap.command.contains("iptables ip6tables jq"))
    #expect(bootstrap.command.contains("iptables jq"))
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
  func loadsBoundedResourcesFromTheExactRunningMachine() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let service = makeService(runtime: runtime, commands: commands, store: store)

    let inventory = try await service.loadResourceInventory()

    #expect(inventory == readyResourceInventory())
    let invocation = try #require(
      await commands.commands.first(where: {
        $0.command.contains(KubernetesResourceInventoryParser.workloadsMarker)
      })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 90)
    #expect(invocation.command.contains("deployments.apps"))
    #expect(invocation.command.contains("services --all-namespaces"))
    #expect(invocation.command.contains("jq --compact-output"))
    #expect(invocation.command.contains("uid: .metadata.uid"))
    #expect(invocation.command.contains("resourceVersion: .metadata.resourceVersion"))
    #expect(invocation.command.contains("(.spec.containers // [])"))
    #expect(!invocation.command.contains(".spec.env"))
    #expect(!invocation.command.contains(".metadata.annotations"))
    #expect(!invocation.command.contains("secret"))

    await runtime.setMachine(
      makeMachine(createdAt: Date(timeIntervalSince1970: 1_700_000_500))
    )
    await #expect(
      throws: KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    ) {
      _ = try await service.loadResourceInventory()
    }
    #expect(
      await commands.commands.filter {
        $0.command.contains(KubernetesResourceInventoryParser.workloadsMarker)
      }.count == 1
    )
  }

  @Test
  func loadsBoundedLogsForAValidatedPodContainer() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let service = makeService(runtime: runtime, commands: commands, store: store)
    let request = KubernetesPodLogRequest(
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api"
    )

    let snapshot = try await service.loadPodLogs(request)

    #expect(snapshot.request == request)
    #expect(snapshot.text.contains("test log output"))
    #expect(snapshot.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
    #expect(!snapshot.isTruncated)
    let invocation = try #require(
      await commands.commands.first(where: { $0.command.contains("kubectl logs") })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 75)
    #expect(invocation.command.contains("--namespace=default"))
    #expect(invocation.command.contains("--container=api"))
    #expect(invocation.command.contains("--timestamps=true"))
    #expect(invocation.command.contains("--tail=2000"))
    #expect(invocation.command.contains("--limit-bytes=524289"))
    #expect(invocation.command.contains("--request-timeout=60s"))
    #expect(invocation.command.contains("get pod"))
    #expect(invocation.command.contains("{.metadata.uid}"))
    #expect(invocation.command.contains(request.podUID))
    #expect(
      invocation.command.components(separatedBy: "kubectl get pod").count - 1
        == 2
    )
    #expect(
      invocation.command.components(separatedBy: "--request-timeout=5s").count - 1
        == 2
    )
    #expect(invocation.command.contains(AppleKubernetesClusterService.podLogIdentityMarker))

    await commands.setPodLogOutput(
      String(
        repeating: "x",
        count: AppleKubernetesClusterService.maximumPodLogBytes + 1
      )
    )
    let truncated = try await service.loadPodLogs(request)
    #expect(truncated.isTruncated)
    #expect(
      truncated.text.utf8.count
        == AppleKubernetesClusterService.maximumPodLogBytes
    )

    await commands.setPodLogUID("22222222-2222-4222-8222-222222222222")
    await #expect(throws: KubernetesClusterError.invalidPodLogSnapshot) {
      _ = try await service.loadPodLogs(request)
    }

    let unsafeRequests = [
      KubernetesPodLogRequest(
        podUID: "$(touch-pwned)",
        namespace: "default",
        podName: "api-abc",
        containerName: "api"
      ),
      KubernetesPodLogRequest(
        podUID: "11111111-1111-4111-8111-111111111111",
        namespace: "default;touch-pwned",
        podName: "api-abc",
        containerName: "api"
      ),
      KubernetesPodLogRequest(
        podUID: "11111111-1111-4111-8111-111111111111",
        namespace: "default",
        podName: "api-abc$(touch-pwned)",
        containerName: "api"
      ),
      KubernetesPodLogRequest(
        podUID: "11111111-1111-4111-8111-111111111111",
        namespace: "default",
        podName: "api-abc",
        containerName: "api --previous"
      ),
    ]
    for unsafeRequest in unsafeRequests {
      await #expect(
        throws: KubernetesClusterError.invalidKubernetesResourceReference
      ) {
        _ = try await service.loadPodLogs(unsafeRequest)
      }
    }
    #expect(
      await commands.commands.filter { $0.command.contains("kubectl logs") }.count
        == 3
    )
  }

  @Test
  func podCommandRequestEnforcesBoundedArgumentsAndTimeout() throws {
    let identity = (
      machine: stableIdentity(),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api"
    )

    _ = try KubernetesPodCommandRequest(
      machine: identity.machine,
      podUID: identity.podUID,
      namespace: identity.namespace,
      podName: identity.podName,
      containerName: identity.containerName,
      executable: "env",
      arguments: ["NAME=value"],
      timeoutSeconds: KubernetesPodCommandRequest.maximumTimeoutSeconds
    )

    let invalidRequests: [() throws -> KubernetesPodCommandRequest] = [
      {
        try KubernetesPodCommandRequest(
          machine: LinuxMachineIdentity(
            id: identity.machine.id,
            imageReference: identity.machine.imageReference,
            platform: identity.machine.platform,
            createdAt: nil
          ),
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env"
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "  "
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env",
          arguments: Array(
            repeating: "value",
            count: KubernetesPodCommandRequest.maximumArgumentCount + 1
          )
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env",
          arguments: [
            String(
              repeating: "x",
              count: KubernetesPodCommandRequest.maximumArgumentBytes + 1
            )
          ]
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env",
          arguments: Array(
            repeating: String(
              repeating: "x",
              count: KubernetesPodCommandRequest.maximumArgumentBytes
            ),
            count: 9
          )
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env\0bad"
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: "default; unsafe",
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env"
        )
      },
      {
        try KubernetesPodCommandRequest(
          machine: identity.machine,
          podUID: identity.podUID,
          namespace: identity.namespace,
          podName: identity.podName,
          containerName: identity.containerName,
          executable: "env",
          timeoutSeconds: KubernetesPodCommandRequest.maximumTimeoutSeconds + 1
        )
      },
    ]
    for invalidRequest in invalidRequests {
      #expect(throws: KubernetesClusterError.invalidPodCommandRequest) {
        _ = try invalidRequest()
      }
    }
  }

  @Test
  func executesOneBoundedCommandAgainstTheExactPodContainer() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let store = InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    let service = makeService(runtime: runtime, commands: commands, store: store)
    let request = try KubernetesPodCommandRequest(
      machine: descriptor.machine,
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api",
      executable: "tool; touch /tmp/pwned",
      arguments: ["$(touch /tmp/pwned)", "quote'value"],
      timeoutSeconds: 30
    )
    await commands.setPodCommandResult(
      exitCode: 23,
      standardOutput: "command output\n",
      standardError: "command warning\n",
      outputWasTruncated: true
    )

    let commandResult = try await service.executePodCommand(request)

    #expect(commandResult.request == request)
    #expect(commandResult.process.exitCode == 23)
    #expect(commandResult.process.standardOutput == "command output\n")
    #expect(commandResult.process.standardError == "command warning\n")
    #expect(commandResult.process.outputWasTruncated)
    #expect(commandResult.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
    let invocation = try #require(
      await commands.commands.first(where: {
        $0.command.contains(AppleKubernetesClusterService.podCommandResultMarker)
      })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 50)
    #expect(invocation.command.contains("--namespace=default"))
    #expect(invocation.command.contains("--container=api"))
    #expect(invocation.command.contains("--pod-running-timeout=15s"))
    #expect(invocation.command.contains("--request-timeout=30s"))
    #expect(invocation.command.contains("-- 'tool; touch /tmp/pwned'"))
    #expect(invocation.command.contains("'$(touch /tmp/pwned)'"))
    #expect(invocation.command.contains("'quote'\"'\"'value'"))
    #expect(!invocation.command.contains("--stdin"))
    #expect(!invocation.command.contains("--tty"))
    #expect(
      invocation.command.components(separatedBy: "kubectl get pod").count - 1
        == 2
    )

    let replacementMachine = LinuxMachineIdentity(
      id: descriptor.machine.id,
      imageReference: descriptor.machine.imageReference,
      platform: descriptor.machine.platform,
      createdAt: Date(timeIntervalSince1970: 1_700_000_500)
    )
    let replacementRequest = try KubernetesPodCommandRequest(
      machine: replacementMachine,
      podUID: request.podUID,
      namespace: request.namespace,
      podName: request.podName,
      containerName: request.containerName,
      executable: request.executable,
      arguments: request.arguments,
      timeoutSeconds: request.timeoutSeconds
    )
    let invocationCount = await commands.commands.count
    await #expect(
      throws: KubernetesClusterError.machineIdentityChanged(replacementMachine.id)
    ) {
      _ = try await service.executePodCommand(replacementRequest)
    }
    #expect(await commands.commands.count == invocationCount)

    await commands.setPodCommandResult(
      exitCode: -1,
      standardOutput: "invalid status\n",
      standardError: "",
      outputWasTruncated: false
    )
    await #expect(throws: KubernetesClusterError.invalidPodCommandResult) {
      _ = try await service.executePodCommand(request)
    }

    await commands.setPodCommandUID("22222222-2222-4222-8222-222222222222")
    await #expect(throws: KubernetesClusterError.invalidPodCommandResult) {
      _ = try await service.executePodCommand(request)
    }

    await commands.setPodCommandWrapperExitCode(66)
    await #expect(throws: KubernetesClusterError.podIdentityChanged(request.podName)) {
      _ = try await service.executePodCommand(request)
    }
  }

  @Test
  func scalesOnlyTheReviewedWorkloadVersionAndConfirmsTheResult() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let service = makeService(
      runtime: runtime,
      commands: commands,
      store: InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    )
    let workload = try #require(readyResourceInventory().workloads.first)
    let request = try KubernetesWorkloadScaleRequest(
      workload: workload,
      targetReplicas: 3
    )

    let result = try await service.scaleWorkload(request)

    #expect(result.request == request)
    #expect(result.resourceVersion == "102")
    #expect(result.observedReplicas == 3)
    #expect(result.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
    let invocation = try #require(
      await commands.commands.first(where: { $0.command.contains("kubectl scale") })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 45)
    #expect(invocation.command.contains("expected_uid='\(workload.uid)'"))
    #expect(invocation.command.contains("expected_resource_version='101'"))
    #expect(invocation.command.contains("current_replicas=2"))
    #expect(invocation.command.contains("target_replicas=3"))
    #expect(invocation.command.contains("--current-replicas=\"$current_replicas\""))
    #expect(invocation.command.contains("--resource-version=\"$resource_version\""))
    #expect(invocation.command.contains("--replicas=\"$target_replicas\""))
    #expect(
      invocation.command.components(separatedBy: "kubectl get").count - 1
        == 2
    )

    await commands.setWorkloadScaleExitCode(66)
    await #expect(
      throws: KubernetesClusterError.workloadIdentityChanged(workload.name)
    ) {
      _ = try await service.scaleWorkload(request)
    }
    await commands.setWorkloadScaleExitCode(67)
    await #expect(
      throws: KubernetesClusterError.workloadReplicaCountChanged(workload.name)
    ) {
      _ = try await service.scaleWorkload(request)
    }
    await commands.setWorkloadScaleExitCode(68)
    await #expect(
      throws: KubernetesClusterError.workloadScaleNotApplied(workload.name)
    ) {
      _ = try await service.scaleWorkload(request)
    }
    await commands.setWorkloadScaleExitCode(0)
    await commands.setWorkloadScaleOutput(
      "\(AppleKubernetesClusterService.workloadScaleMarker)bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\t102\t3\n"
    )
    await #expect(throws: KubernetesClusterError.invalidWorkloadScaleResult) {
      _ = try await service.scaleWorkload(request)
    }
  }

  @Test
  func scaleRequestRejectsUnsupportedUnsafeAndNoOpChanges() throws {
    let workload = try #require(readyResourceInventory().workloads.first)

    #expect(throws: KubernetesClusterError.invalidWorkloadScaleRequest) {
      _ = try KubernetesWorkloadScaleRequest(
        workload: workload,
        targetReplicas: workload.desiredCount
      )
    }
    #expect(throws: KubernetesClusterError.invalidWorkloadScaleRequest) {
      _ = try KubernetesWorkloadScaleRequest(
        workload: workload,
        targetReplicas: KubernetesWorkloadScaleRequest.maximumReplicaCount + 1
      )
    }

    let job = KubernetesWorkloadRecord(
      uid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      resourceVersion: "202",
      namespace: "default",
      name: "migration",
      kind: .job,
      desiredCount: 1,
      readyCount: 0,
      availableCount: 1,
      failedCount: 0
    )
    #expect(throws: KubernetesClusterError.workloadNotScalable) {
      _ = try KubernetesWorkloadScaleRequest(
        workload: job,
        targetReplicas: 2
      )
    }
  }

  @Test
  func restartsOnlyTheReviewedWorkloadVersionWithAnOptimisticReplace() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let service = makeService(
      runtime: runtime,
      commands: commands,
      store: InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    )
    let workload = try #require(readyResourceInventory().workloads.first)
    let request = try KubernetesWorkloadRestartRequest(workload: workload)

    let result = try await service.restartWorkload(request)

    #expect(result.request == request)
    #expect(result.resourceVersion == "102")
    #expect(result.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
    let invocation = try #require(
      await commands.commands.first(where: { $0.command.contains("kubectl replace") })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 45)
    #expect(invocation.command.contains("resource='deployment'"))
    #expect(invocation.command.contains("expected_api_version='apps/v1'"))
    #expect(invocation.command.contains("expected_kind='Deployment'"))
    #expect(invocation.command.contains("expected_uid='\(workload.uid)'"))
    #expect(invocation.command.contains("expected_resource_version='101'"))
    #expect(invocation.command.contains("restarted_at='2023-11-14T22:15:00.000Z'"))
    #expect(
      invocation.command.contains(
        #".spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]"#
      )
    )
    #expect(invocation.command.contains("del(.status, .metadata.managedFields)"))
    #expect(invocation.command.contains("--filename=-"))
    #expect(invocation.command.contains("--namespace=\"$namespace\""))
    #expect(invocation.command.contains("--output=json"))
    #expect(invocation.command.contains("2>/dev/null"))
    #expect(
      invocation.command.components(separatedBy: "kubectl get").count - 1
        == 1
    )
    #expect(
      invocation.command.components(separatedBy: "kubectl replace").count - 1
        == 1
    )
    #expect(!invocation.command.contains("rollout restart"))
    #expect(!invocation.command.contains("kubectl patch"))

    await commands.setWorkloadRestartExitCode(66)
    await #expect(
      throws: KubernetesClusterError.workloadIdentityChanged(workload.name)
    ) {
      _ = try await service.restartWorkload(request)
    }
    await commands.setWorkloadRestartExitCode(68)
    await #expect(
      throws: KubernetesClusterError.workloadRestartNotConfirmed(workload.name)
    ) {
      _ = try await service.restartWorkload(request)
    }
    await commands.setWorkloadRestartExitCode(67)
    await #expect(
      throws: KubernetesClusterError.workloadRestartRejected(workload.name)
    ) {
      _ = try await service.restartWorkload(request)
    }
    await commands.setWorkloadRestartExitCode(0)
    await commands.setWorkloadRestartOutput(
      "\(AppleKubernetesClusterService.workloadRestartMarker)bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\t102\t2023-11-14T22:15:00.000Z\n"
    )
    await #expect(throws: KubernetesClusterError.invalidWorkloadRestartResult) {
      _ = try await service.restartWorkload(request)
    }
  }

  @Test
  func restartRequestRejectsJobsAndUnsafeIdentity() throws {
    let workload = try #require(readyResourceInventory().workloads.first)
    let unsafe = KubernetesWorkloadRecord(
      uid: workload.uid,
      resourceVersion: "101\nunsafe",
      namespace: workload.namespace,
      name: workload.name,
      kind: workload.kind,
      desiredCount: workload.desiredCount,
      readyCount: workload.readyCount,
      availableCount: workload.availableCount,
      failedCount: workload.failedCount
    )
    #expect(throws: KubernetesClusterError.invalidWorkloadRestartRequest) {
      _ = try KubernetesWorkloadRestartRequest(workload: unsafe)
    }

    let job = KubernetesWorkloadRecord(
      uid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      resourceVersion: "202",
      namespace: "default",
      name: "migration",
      kind: .job,
      desiredCount: 1,
      readyCount: 0,
      availableCount: 1,
      failedCount: 0
    )
    #expect(throws: KubernetesClusterError.workloadNotRestartable) {
      _ = try KubernetesWorkloadRestartRequest(workload: job)
    }
  }

  @Test
  func deletesOnlyTheReviewedWorkloadWithForegroundPreconditions() async throws {
    let machine = makeMachine()
    let runtime = KubernetesMachineRuntimeDouble(machine: machine)
    let commands = KubernetesRootCommandDouble()
    let descriptor = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(machine: machine),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let service = makeService(
      runtime: runtime,
      commands: commands,
      store: InMemoryKubernetesDescriptorStore(descriptor: descriptor)
    )
    let workload = try #require(readyResourceInventory().workloads.first)
    let request = try KubernetesWorkloadDeleteRequest(workload: workload)

    let result = try await service.deleteWorkload(request)

    #expect(result.request == request)
    #expect(result.outcome == .deleted)
    #expect(result.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
    let invocation = try #require(
      await commands.commands.first(where: {
        $0.command.contains("kubectl delete --raw")
      })
    )
    #expect(invocation.target == descriptor.machine)
    #expect(invocation.timeoutSeconds == 75)
    #expect(invocation.command.contains("resource='deployment'"))
    #expect(invocation.command.contains("expected_api_version='apps/v1'"))
    #expect(invocation.command.contains("expected_kind='Deployment'"))
    #expect(
      invocation.command.contains(
        "api_path='/apis/apps/v1/namespaces/default/deployments/api'"
      )
    )
    #expect(invocation.command.contains("expected_uid='\(workload.uid)'"))
    #expect(invocation.command.contains("expected_resource_version='101'"))
    #expect(
      invocation.command.contains(
        "preconditions: {uid: $uid, resourceVersion: $resource_version}"
      )
    )
    #expect(invocation.command.contains("propagationPolicy: \"Foreground\""))
    #expect(invocation.command.contains("--raw=\"$api_path\""))
    #expect(invocation.command.contains("--filename=-"))
    #expect(invocation.command.contains("--ignore-not-found=true"))
    #expect(invocation.command.contains("2>/dev/null"))
    #expect(!invocation.command.contains("--force"))
    #expect(!invocation.command.contains("--grace-period"))

    for (kind, resource, apiVersion, kindName, apiPath) in [
      (
        KubernetesWorkloadKind.statefulSet,
        "statefulset",
        "apps/v1",
        "StatefulSet",
        "/apis/apps/v1/namespaces/default/statefulsets/api"
      ),
      (
        KubernetesWorkloadKind.daemonSet,
        "daemonset",
        "apps/v1",
        "DaemonSet",
        "/apis/apps/v1/namespaces/default/daemonsets/api"
      ),
      (
        KubernetesWorkloadKind.job,
        "job",
        "batch/v1",
        "Job",
        "/apis/batch/v1/namespaces/default/jobs/api"
      ),
    ] {
      let variant = KubernetesWorkloadRecord(
        uid: workload.uid,
        resourceVersion: workload.resourceVersion,
        namespace: workload.namespace,
        name: workload.name,
        kind: kind,
        desiredCount: workload.desiredCount,
        readyCount: workload.readyCount,
        availableCount: workload.availableCount,
        failedCount: workload.failedCount
      )
      _ = try await service.deleteWorkload(
        KubernetesWorkloadDeleteRequest(workload: variant)
      )
      let command = try #require(await commands.commands.last?.command)
      #expect(command.contains("resource='\(resource)'"))
      #expect(command.contains("expected_api_version='\(apiVersion)'"))
      #expect(command.contains("expected_kind='\(kindName)'"))
      #expect(command.contains("api_path='\(apiPath)'"))
    }

    await commands.setWorkloadDeleteOutput(
      "\(AppleKubernetesClusterService.workloadDeleteMarker)\(workload.uid)\treplacementPresent\n"
    )
    #expect(try await service.deleteWorkload(request).outcome == .replacementPresent)
    await commands.setWorkloadDeleteOutput(
      "\(AppleKubernetesClusterService.workloadDeleteMarker)\(workload.uid)\tpendingFinalizers\n"
    )
    #expect(try await service.deleteWorkload(request).outcome == .pendingFinalizers)

    for (exitCode, expectedError) in [
      (Int32(66), KubernetesClusterError.workloadIdentityChanged(workload.name)),
      (Int32(67), KubernetesClusterError.workloadDeleteRejected(workload.name)),
      (Int32(68), KubernetesClusterError.workloadDeleteNotConfirmed(workload.name)),
      (
        Int32(69),
        KubernetesClusterError.workloadDeleteVerificationFailed(workload.name)
      ),
    ] {
      await commands.setWorkloadDeleteExitCode(exitCode)
      await #expect(throws: expectedError) {
        _ = try await service.deleteWorkload(request)
      }
    }
    await commands.setWorkloadDeleteExitCode(0)
    await commands.setWorkloadDeleteOutput("invalid")
    await #expect(throws: KubernetesClusterError.invalidWorkloadDeleteResult) {
      _ = try await service.deleteWorkload(request)
    }
  }

  @Test
  func deleteRequestRejectsUnsafeIdentity() throws {
    let workload = try #require(readyResourceInventory().workloads.first)
    let unsafe = KubernetesWorkloadRecord(
      uid: workload.uid,
      resourceVersion: "101\tunsafe",
      namespace: workload.namespace,
      name: workload.name,
      kind: workload.kind,
      desiredCount: workload.desiredCount,
      readyCount: workload.readyCount,
      availableCount: workload.availableCount,
      failedCount: workload.failedCount
    )

    #expect(throws: KubernetesClusterError.invalidWorkloadDeleteRequest) {
      _ = try KubernetesWorkloadDeleteRequest(workload: unsafe)
    }
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
  func loadsReadOnlyResourcesWithoutPublishingAClusterMutation() async {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: snapshot)
    let mutations = KubernetesMutationCounter()
    let model = KubernetesClusterModel(
      service: service,
      initialSnapshot: snapshot
    ) {
      mutations.count += 1
    }

    await model.loadResources()

    #expect(model.resourceInventory == readyResourceInventory())
    #expect(model.resourceErrorMessage == nil)
    #expect(!model.isLoadingResources)
    #expect(await service.resourceLoadCount == 1)
    #expect(mutations.count == 0)
  }

  @Test
  func scalesReviewedWorkloadAndReloadsAuthoritativeResources() async {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: snapshot)
    let model = KubernetesClusterModel(
      service: service,
      initialSnapshot: snapshot
    )
    await model.loadResources()
    guard let workload = model.resourceInventory?.workloads.first else {
      Issue.record("The fixture did not load its workload.")
      return
    }
    await service.setResourceInventory(
      readyResourceInventory(desiredCount: 3, resourceVersion: "102")
    )

    let scaled = await model.scaleWorkload(
      workload,
      to: 3
    )

    #expect(scaled)
    #expect(model.resourceInventory?.workloads.first?.desiredCount == 3)
    #expect(model.resourceInventory?.workloads.first?.resourceVersion == "102")
    #expect(model.resourceErrorMessage == nil)
    #expect(await service.resourceLoadCount == 2)
    let request = await service.scaleRequests.first
    #expect(request?.resourceVersion == "101")
    #expect(request?.currentReplicas == 2)
    #expect(request?.targetReplicas == 3)
  }

  @Test
  func restartsReviewedWorkloadAndReloadsAuthoritativeResources() async {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: snapshot)
    let model = KubernetesClusterModel(
      service: service,
      initialSnapshot: snapshot
    )
    await model.loadResources()
    guard let workload = model.resourceInventory?.workloads.first else {
      Issue.record("The fixture did not load its workload.")
      return
    }
    await service.setResourceInventory(
      readyResourceInventory(resourceVersion: "102")
    )

    let restarted = await model.restartWorkload(workload)

    #expect(restarted)
    #expect(model.resourceInventory?.workloads.first?.resourceVersion == "102")
    #expect(model.resourceErrorMessage == nil)
    #expect(await service.resourceLoadCount == 2)
    let request = await service.restartRequests.first
    #expect(request?.workloadUID == workload.uid)
    #expect(request?.resourceVersion == "101")
  }

  @Test
  func deletesReviewedWorkloadAndReloadsAuthoritativeResources() async {
    let snapshot = readyKubernetesSnapshot()
    let service = KubernetesModelServiceDouble(snapshot: snapshot)
    let model = KubernetesClusterModel(
      service: service,
      initialSnapshot: snapshot
    )
    await model.loadResources()
    guard let workload = model.resourceInventory?.workloads.first else {
      Issue.record("The fixture did not load its workload.")
      return
    }
    await service.setResourceInventory(
      readyResourceInventory(includesWorkload: false)
    )

    let deleted = await model.deleteWorkload(workload)

    #expect(deleted)
    #expect(model.resourceInventory?.workloads.isEmpty == true)
    #expect(model.resourceErrorMessage == nil)
    #expect(await service.resourceLoadCount == 2)
    let request = await service.deleteRequests.first
    #expect(request?.workloadUID == workload.uid)
    #expect(request?.resourceVersion == "101")
  }

  @Test
  func podLogsModelLoadsFiltersAndSwitchesExplicitContainers() async {
    let pod = KubernetesPodRecord(
      uid: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      name: "api-abc",
      phase: .running,
      readyContainerCount: 2,
      containerNames: ["api", "metrics"],
      restartCount: 0,
      nodeName: "nativecontainers-kubernetes"
    )
    let model = KubernetesPodLogsModel(pod: pod) { request in
      KubernetesPodLogSnapshot(
        request: request,
        text: "\(request.containerName) ready\nnoise\n",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
        isTruncated: false
      )
    }

    await model.refresh()

    #expect(model.snapshot?.request.containerName == "api")
    #expect(model.visibleText == "api ready\nnoise\n")
    model.searchText = "ready"
    #expect(model.visibleText == "api ready")
    #expect(model.matchCount == 1)

    model.searchText = "   "
    #expect(!model.hasSearchText)
    #expect(model.visibleText == "api ready\nnoise\n")

    model.selectedContainerName = "metrics"
    #expect(model.snapshot == nil)
    await model.refresh()
    #expect(model.snapshot?.request.containerName == "metrics")
    #expect(model.visibleText == "metrics ready\nnoise\n")
  }

  @Test
  func podLogsModelDiscardsAStaleContainerResponse() async {
    let pod = KubernetesPodRecord(
      uid: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      name: "api-abc",
      phase: .running,
      readyContainerCount: 2,
      containerNames: ["api", "metrics"],
      restartCount: 0,
      nodeName: "nativecontainers-kubernetes"
    )
    let gate = KubernetesPodLogLoaderGate()
    let model = KubernetesPodLogsModel(pod: pod) { request in
      await gate.load(request)
    }

    let firstRefresh = Task { await model.refresh() }
    await gate.waitUntilStarted(containerName: "api")

    model.selectedContainerName = "metrics"
    let secondRefresh = Task { await model.refresh() }
    await gate.waitUntilStarted(containerName: "metrics")
    await gate.complete(containerName: "metrics", text: "metrics current\n")
    await secondRefresh.value

    await gate.complete(containerName: "api", text: "api stale\n")
    await firstRefresh.value

    #expect(model.snapshot?.request.containerName == "metrics")
    #expect(model.visibleText == "metrics current\n")
    #expect(!model.isLoading)
    #expect(model.errorMessage == nil)
  }

  @Test
  func podCommandModelPublishesTheIdentityBoundResult() async {
    let model = KubernetesPodCommandModel(
      machine: stableIdentity(),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api"
    ) { request in
      KubernetesPodCommandResult(
        request: request,
        process: ContainerCommandResult(
          exitCode: 7,
          standardOutput: "stdout\n",
          standardError: "stderr\n",
          outputWasTruncated: false,
          duration: .milliseconds(25)
        ),
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
      )
    }

    await model.execute(
      executable: "env",
      arguments: ["NAME=value"],
      timeoutSeconds: 30
    )

    #expect(!model.isRunning)
    #expect(model.errorMessage == nil)
    #expect(model.result?.request.containerName == "api")
    #expect(model.result?.request.executable == "env")
    #expect(model.result?.process.exitCode == 7)
    #expect(model.result?.process.standardOutput == "stdout\n")

    let cancelledModel = KubernetesPodCommandModel(
      machine: stableIdentity(),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api"
    ) { _ in
      throw CancellationError()
    }
    await cancelledModel.execute(
      executable: "env",
      arguments: [],
      timeoutSeconds: 30
    )
    #expect(cancelledModel.result == nil)
    #expect(
      cancelledModel.errorMessage
        == String(localized: "The Pod command was cancelled.")
    )
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

private actor KubernetesPodLogLoaderGate {
  private var startedContainers: Set<String> = []
  private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var loadContinuations: [String: CheckedContinuation<KubernetesPodLogSnapshot, Never>] =
    [:]

  func load(_ request: KubernetesPodLogRequest) async -> KubernetesPodLogSnapshot {
    startedContainers.insert(request.containerName)
    let waiters = startWaiters.removeValue(forKey: request.containerName) ?? []
    for waiter in waiters {
      waiter.resume()
    }

    return await withCheckedContinuation { continuation in
      loadContinuations[request.containerName] = continuation
    }
  }

  func waitUntilStarted(containerName: String) async {
    guard !startedContainers.contains(containerName) else { return }
    await withCheckedContinuation { continuation in
      startWaiters[containerName, default: []].append(continuation)
    }
  }

  func complete(containerName: String, text: String) {
    guard let continuation = loadContinuations.removeValue(forKey: containerName) else {
      Issue.record("No pending Pod log load for \(containerName)")
      return
    }
    let request = KubernetesPodLogRequest(
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: containerName
    )
    continuation.resume(
      returning: KubernetesPodLogSnapshot(
        request: request,
        text: text,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
        isTruncated: false
      )
    )
  }
}

private actor KubernetesModelServiceDouble: KubernetesClusterManaging {
  private(set) var loadCount = 0
  private(set) var resourceLoadCount = 0
  private var snapshot: KubernetesClusterSnapshot
  private var provisionedSnapshot: KubernetesClusterSnapshot
  private var resourceInventory = readyResourceInventory()
  private var stopError: KubernetesClusterError?
  private(set) var scaleRequests: [KubernetesWorkloadScaleRequest] = []
  private(set) var restartRequests: [KubernetesWorkloadRestartRequest] = []
  private(set) var deleteRequests: [KubernetesWorkloadDeleteRequest] = []

  init(snapshot: KubernetesClusterSnapshot) {
    self.snapshot = snapshot
    provisionedSnapshot = snapshot
  }

  func load() -> KubernetesClusterSnapshot {
    loadCount += 1
    return snapshot
  }

  func loadResourceInventory() -> KubernetesResourceInventory {
    resourceLoadCount += 1
    return resourceInventory
  }

  func loadPodLogs(
    _ request: KubernetesPodLogRequest
  ) -> KubernetesPodLogSnapshot {
    KubernetesPodLogSnapshot(
      request: request,
      text: "test log output\n",
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
      isTruncated: false
    )
  }

  func executePodCommand(
    _ request: KubernetesPodCommandRequest
  ) -> KubernetesPodCommandResult {
    KubernetesPodCommandResult(
      request: request,
      process: ContainerCommandResult(
        exitCode: 0,
        standardOutput: "test command output\n",
        standardError: "",
        outputWasTruncated: false,
        duration: .milliseconds(1)
      ),
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
  }

  func scaleWorkload(
    _ request: KubernetesWorkloadScaleRequest
  ) -> KubernetesWorkloadScaleResult {
    scaleRequests.append(request)
    return KubernetesWorkloadScaleResult(
      request: request,
      resourceVersion: "102",
      observedReplicas: request.targetReplicas,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
  }

  func restartWorkload(
    _ request: KubernetesWorkloadRestartRequest
  ) -> KubernetesWorkloadRestartResult {
    restartRequests.append(request)
    return KubernetesWorkloadRestartResult(
      request: request,
      resourceVersion: "102",
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
  }

  func deleteWorkload(
    _ request: KubernetesWorkloadDeleteRequest
  ) -> KubernetesWorkloadDeleteResult {
    deleteRequests.append(request)
    return KubernetesWorkloadDeleteResult(
      request: request,
      outcome: .deleted,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
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

  func setResourceInventory(_ inventory: KubernetesResourceInventory) {
    resourceInventory = inventory
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
  private var podLogOutput: String
  private var podLogUID: String
  private var podCommandExitCode: Int32 = 0
  private var podCommandOutput = "command output\n"
  private var podCommandError = ""
  private var podCommandUID: String
  private var podCommandOutputWasTruncated = false
  private var podCommandWrapperExitCode: Int32 = 0
  private var workloadScaleExitCode: Int32 = 0
  private var workloadScaleOutput =
    "\(AppleKubernetesClusterService.workloadScaleMarker)aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\t102\t3\n"
  private var workloadRestartExitCode: Int32 = 0
  private var workloadRestartOutput =
    "\(AppleKubernetesClusterService.workloadRestartMarker)aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\t102\t2023-11-14T22:15:00.000Z\n"
  private var workloadDeleteExitCode: Int32 = 0
  private var workloadDeleteOutput =
    "\(AppleKubernetesClusterService.workloadDeleteMarker)aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\tdeleted\n"

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
    """,
    podLogOutput: String = "2026-06-22T13:30:00Z test log output\n",
    podLogUID: String = "11111111-1111-4111-8111-111111111111"
  ) {
    self.bootstrapFailures = bootstrapFailures
    self.kubeconfig = kubeconfig
    self.podLogOutput = podLogOutput
    self.podLogUID = podLogUID
    podCommandUID = podLogUID
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
    if command.contains(KubernetesResourceInventoryParser.workloadsMarker) {
      return result(standardOutput: testKubernetesResourceInventoryOutput())
    }
    if command.contains(AppleKubernetesClusterService.podCommandResultMarker) {
      if podCommandWrapperExitCode != 0 {
        return result(
          exitCode: podCommandWrapperExitCode,
          standardError: "Pod identity changed"
        )
      }
      return result(
        standardOutput:
          podCommandOutput
          + "\n\(AppleKubernetesClusterService.podCommandResultMarker)\(podCommandUID)\t\(podCommandExitCode)\n",
        standardError: podCommandError,
        outputWasTruncated: podCommandOutputWasTruncated
      )
    }
    if command.contains("kubectl logs") {
      return result(
        standardOutput:
          podLogOutput + "\n\(AppleKubernetesClusterService.podLogIdentityMarker)\(podLogUID)\n"
      )
    }
    if command.contains("kubectl scale") {
      if workloadScaleExitCode != 0 {
        return result(exitCode: workloadScaleExitCode)
      }
      return result(standardOutput: workloadScaleOutput)
    }
    if command.contains("kubectl replace") {
      if workloadRestartExitCode != 0 {
        return result(exitCode: workloadRestartExitCode)
      }
      return result(standardOutput: workloadRestartOutput)
    }
    if command.contains("kubectl delete --raw") {
      if workloadDeleteExitCode != 0 {
        return result(exitCode: workloadDeleteExitCode)
      }
      return result(standardOutput: workloadDeleteOutput)
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

  func setPodLogOutput(_ value: String) {
    podLogOutput = value
  }

  func setPodLogUID(_ value: String) {
    podLogUID = value
  }

  func setPodCommandResult(
    exitCode: Int32,
    standardOutput: String,
    standardError: String,
    outputWasTruncated: Bool
  ) {
    podCommandExitCode = exitCode
    podCommandOutput = standardOutput
    podCommandError = standardError
    podCommandOutputWasTruncated = outputWasTruncated
  }

  func setPodCommandUID(_ value: String) {
    podCommandUID = value
  }

  func setPodCommandWrapperExitCode(_ value: Int32) {
    podCommandWrapperExitCode = value
  }

  func setWorkloadScaleExitCode(_ value: Int32) {
    workloadScaleExitCode = value
  }

  func setWorkloadScaleOutput(_ value: String) {
    workloadScaleOutput = value
  }

  func setWorkloadRestartExitCode(_ value: Int32) {
    workloadRestartExitCode = value
  }

  func setWorkloadRestartOutput(_ value: String) {
    workloadRestartOutput = value
  }

  func setWorkloadDeleteExitCode(_ value: Int32) {
    workloadDeleteExitCode = value
  }

  func setWorkloadDeleteOutput(_ value: String) {
    workloadDeleteOutput = value
  }

  private func result(
    exitCode: Int32 = 0,
    standardOutput: String = "",
    standardError: String = "",
    outputWasTruncated: Bool = false
  ) -> ContainerCommandResult {
    ContainerCommandResult(
      exitCode: exitCode,
      standardOutput: standardOutput,
      standardError: standardError,
      outputWasTruncated: outputWasTruncated,
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

private func readyResourceInventory(
  desiredCount: Int = 2,
  resourceVersion: String = "101",
  includesWorkload: Bool = true
) -> KubernetesResourceInventory {
  KubernetesResourceInventory(
    workloads:
      includesWorkload
      ? [
        KubernetesWorkloadRecord(
          uid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          resourceVersion: resourceVersion,
          namespace: "default",
          name: "api",
          kind: .deployment,
          desiredCount: desiredCount,
          readyCount: desiredCount,
          availableCount: desiredCount,
          failedCount: 0
        )
      ]
      : [],
    pods: [
      KubernetesPodRecord(
        uid: "11111111-1111-4111-8111-111111111111",
        namespace: "default",
        name: "api-abc",
        phase: .running,
        readyContainerCount: 1,
        containerNames: ["api"],
        restartCount: 0,
        nodeName: "nativecontainers-kubernetes"
      )
    ],
    services: [
      KubernetesServiceRecord(
        namespace: "default",
        name: "api",
        type: "ClusterIP",
        clusterIP: "10.43.20.10",
        ports: [
          KubernetesServicePortRecord(
            name: "http",
            protocolName: "TCP",
            port: 80,
            targetPort: "8080",
            nodePort: nil
          )
        ]
      )
    ],
    capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
  )
}

private func testKubernetesResourceInventoryOutput() -> String {
  """
  \(KubernetesResourceInventoryParser.workloadsMarker)
  {
    "items": [
      {
        "kind": "Deployment",
        "metadata": {
          "uid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "resourceVersion": "101",
          "namespace": "default",
          "name": "api"
        },
        "spec": {"replicas": 2},
        "status": {
          "replicas": 2,
          "readyReplicas": 2,
          "availableReplicas": 2
        }
      }
    ]
  }
  \(KubernetesResourceInventoryParser.podsMarker)
  {
    "items": [
      {
        "metadata": {
          "uid": "11111111-1111-4111-8111-111111111111",
          "namespace": "default",
          "name": "api-abc"
        },
        "spec": {
          "nodeName": "nativecontainers-kubernetes",
          "containers": [{"name": "api"}]
        },
        "status": {
          "phase": "Running",
          "containerStatuses": [{"ready": true, "restartCount": 0}]
        }
      }
    ]
  }
  \(KubernetesResourceInventoryParser.servicesMarker)
  {
    "items": [
      {
        "metadata": {"namespace": "default", "name": "api"},
        "spec": {
          "type": "ClusterIP",
          "clusterIP": "10.43.20.10",
          "ports": [
            {
              "name": "http",
              "protocol": "TCP",
              "port": 80,
              "targetPort": 8080
            }
          ]
        }
      }
    ]
  }
  """
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
