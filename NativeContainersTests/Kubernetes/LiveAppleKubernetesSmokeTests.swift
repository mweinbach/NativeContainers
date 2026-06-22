import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleKubernetesSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_KUBERNETES"]
        == "1",
      "Set NATIVECONTAINERS_LIVE_KUBERNETES=1 with Apple container services running and kubectl installed."
    )
  )
  func provisionsWorkloadRestartsAndDeletesPinnedCluster() async throws {
    let identifier =
      "nativecontainers-k3s-\(UUID().uuidString.lowercased().prefix(8))"
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-KubernetesLive-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let kubeconfigURL = temporaryRoot.appending(
      path: "kubeconfig.yaml",
      directoryHint: .notDirectory
    )
    let descriptorRoot = temporaryRoot.appending(
      path: "Descriptor",
      directoryHint: .isDirectory
    )
    let namespace =
      "nativecontainers-smoke-\(UUID().uuidString.lowercased().prefix(8))"
    let graph = LiveKubernetesServiceGraph(
      descriptorRoot: descriptorRoot
    )

    do {
      let snapshot = try await graph.cluster.provision(
        try KubernetesClusterProvisionRequest(
          machineName: identifier,
          cpuCount: 2,
          memoryBytes: KubernetesClusterProvisionRequest.minimumMemoryBytes
        )
      ) { _ in }

      #expect(snapshot.state == .ready)
      #expect(snapshot.machine?.id == identifier)
      #expect(snapshot.machine?.homeMount == LinuxMachineHomeMount.none)
      #expect(snapshot.nodeCount == 1)
      #expect(snapshot.readyNodeCount == 1)
      #expect(snapshot.k3sVersion?.contains(KubernetesDistribution.current.version) == true)

      try FileManager.default.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try await writeKubeconfig(
        try await graph.cluster.exportKubeconfig(),
        to: kubeconfigURL
      )
      try await graph.waitForHostAPI(kubeconfigURL: kubeconfigURL)

      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: ["create", "namespace", namespace]
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "wait", "--for=create",
          "serviceaccount/default", "--timeout=90s",
        ],
        timeout: .seconds(120)
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "create", "deployment", "inventory",
          "--image=docker.io/library/alpine:3.22",
          "--", "/bin/sh", "-c", "sleep 300",
        ]
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "wait", "--for=condition=Available",
          "deployment/inventory", "--timeout=240s",
        ],
        timeout: .seconds(270)
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "expose", "deployment", "inventory",
          "--port=8080", "--target-port=8080",
        ]
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "run", "smoke",
          "--image=docker.io/library/alpine:3.22",
          "--restart=Never",
          "--command", "--",
          "/bin/sh", "-c", "echo nativecontainers-k3s-live; sleep 300",
        ]
      )
      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "--namespace", namespace,
          "wait", "--for=condition=Ready",
          "pod/smoke", "--timeout=240s",
        ],
        timeout: .seconds(270)
      )
      let logs = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: ["--namespace", namespace, "logs", "smoke"]
      )
      #expect(logs.contains("nativecontainers-k3s-live"))

      let inventory = try await graph.cluster.loadResourceInventory()
      #expect(
        inventory.workloads.contains {
          $0.namespace == namespace
            && $0.name == "inventory"
            && $0.kind == .deployment
            && $0.readyCount == 1
        }
      )
      #expect(
        inventory.pods.contains {
          $0.namespace == namespace
            && $0.name == "smoke"
            && $0.phase == .running
        }
      )
      #expect(
        inventory.services.contains {
          $0.namespace == namespace
            && $0.name == "inventory"
            && $0.ports.contains { $0.port == 8_080 }
        }
      )

      _ = try await graph.kubectl(
        kubeconfigURL: kubeconfigURL,
        arguments: [
          "delete", "namespace", namespace,
          "--wait=true", "--timeout=180s",
        ],
        timeout: .seconds(210)
      )

      let stopped = try await graph.cluster.stop()
      #expect(stopped.state == .stopped)
      let restarted = try await graph.cluster.start()
      #expect(restarted.state == .ready)

      try await writeKubeconfig(
        try await graph.cluster.exportKubeconfig(),
        to: kubeconfigURL
      )
      try await graph.waitForHostAPI(kubeconfigURL: kubeconfigURL)

      try await graph.cluster.delete()
      #expect(try await graph.runtime.snapshot(id: identifier) == nil)
      try FileManager.default.removeItem(at: temporaryRoot)
    } catch {
      let operationError = error
      let diagnostics = await graph.diagnostics(machineID: identifier)
      do {
        try await graph.cleanUp(machineID: identifier)
        try? FileManager.default.removeItem(at: temporaryRoot)
      } catch {
        throw LiveKubernetesSmokeError(
          operation: operationError.localizedDescription,
          diagnostics: diagnostics,
          cleanup: error.localizedDescription
        )
      }
      throw LiveKubernetesOperationError(
        operation: operationError.localizedDescription,
        diagnostics: diagnostics
      )
    }
  }

  private func writeKubeconfig(
    _ export: KubernetesKubeconfigExport,
    to url: URL
  ) async throws {
    try export.data.write(to: url, options: [.atomic])
    guard Darwin.chmod(url.nativeContainersPOSIXPath, mode_t(0o600)) == 0 else {
      throw KubernetesClusterError.ioFailure("secure its live kubeconfig")
    }
  }
}

private struct LiveKubernetesServiceGraph {
  let cluster: AppleKubernetesClusterService
  let runtime: AppleMachineRuntimeClient
  let machineService: AppleMachineManagementService
  let rootCommands: AppleKubernetesMachineRootCommandService
  let descriptorStore: KubernetesClusterDescriptorStore

  private let hostCommands = FoundationHostCommandExecutor()

  init(descriptorRoot: URL) {
    let machineTransport = AppleMachineXPCTransport()
    let processClient = AppleContainerProcessXPCClient()
    let cleanupClient = AppleContainerCleanupClient()
    runtime = AppleMachineRuntimeClient(
      machineTransport: machineTransport,
      processClient: processClient,
      containerKillClient: cleanupClient
    )
    machineService = AppleMachineManagementService(
      runtime: runtime,
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let targetResolver = AppleLinuxMachineProcessTargetResolver(
      lifecycle: machineService,
      machineTransport: machineTransport
    )
    rootCommands = AppleKubernetesMachineRootCommandService(
      targetResolver: targetResolver,
      commandExecutor: AppleRuntimeCommandExecutor(
        processClient: processClient
      )
    )
    descriptorStore = KubernetesClusterDescriptorStore(rootURL: descriptorRoot)
    cluster = AppleKubernetesClusterService(
      machineCreator: machineService,
      machineLifecycle: machineService,
      machineInventory: AppleLinuxMachineInventoryService(
        machineTransport: machineTransport
      ),
      rootCommands: rootCommands,
      store: descriptorStore
    )
  }

  func kubectl(
    kubeconfigURL: URL,
    arguments: [String],
    timeout: Duration = .seconds(60)
  ) async throws -> String {
    let result = try await hostCommands.execute(
      executableURL: URL(filePath: "/usr/local/bin/kubectl"),
      arguments: [
        "--kubeconfig", kubeconfigURL.nativeContainersPOSIXPath,
      ] + arguments,
      environment: nil,
      timeout: timeout
    )
    guard !result.outputWasTruncated, result.exitCode == 0 else {
      let detail =
        result.standardError.isEmpty
        ? result.standardOutput
        : result.standardError
      throw LiveKubernetesCommandError(
        arguments: arguments,
        exitCode: result.exitCode,
        detail: String(detail.prefix(2_000))
      )
    }
    return result.standardOutput
  }

  func waitForHostAPI(kubeconfigURL: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(90))
    var lastFailure = "kubectl did not return an ok response."

    repeat {
      do {
        let readyz = try await kubectl(
          kubeconfigURL: kubeconfigURL,
          arguments: ["get", "--raw=/readyz"],
          timeout: .seconds(10)
        )
        if readyz.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
          return
        }
      } catch {
        lastFailure = error.localizedDescription
        if clock.now >= deadline {
          throw error
        }
      }
      try await Task.sleep(for: .seconds(1))
    } while clock.now < deadline

    throw LiveKubernetesCommandError(
      arguments: ["get", "--raw=/readyz"],
      exitCode: -1,
      detail:
        "The host API did not become reachable within 90 seconds. Last failure: \(lastFailure)"
    )
  }

  func diagnostics(machineID: String) async -> String {
    guard let current = try? await runtime.snapshot(id: machineID) else {
      return "The disposable machine was not present for diagnostics."
    }
    let stored = (try? await descriptorStore.load())?.machine
    let identityDiagnostics = """
      __IDENTITY__
      stored.id=\(stored?.id ?? "nil")
      stored.image=\(stored?.imageReference ?? "nil")
      stored.platform=\(stored?.platform ?? "nil")
      stored.createdAt=\(stored?.createdAt?.timeIntervalSince1970.description ?? "nil")
      current.id=\(current.identity.id)
      current.image=\(current.identity.imageReference)
      current.platform=\(current.identity.platform)
      current.createdAt=\(current.identity.createdAt?.timeIntervalSince1970.description ?? "nil")
      identity.equal=\(stored == current.identity)
      id.equal=\(stored?.id == current.identity.id)
      image.equal=\(stored?.imageReference == current.identity.imageReference)
      platform.equal=\(stored?.platform == current.identity.platform)
      createdAt.equal=\(stored?.createdAt == current.identity.createdAt)
      stored.platform.debug=\(stored?.platform.debugDescription ?? "nil")
      current.platform.debug=\(current.identity.platform.debugDescription)
      stored.createdAt.referenceBits=\(stored?.createdAt?.timeIntervalSinceReferenceDate.bitPattern.description ?? "nil")
      current.createdAt.referenceBits=\(current.identity.createdAt?.timeIntervalSinceReferenceDate.bitPattern.description ?? "nil")
      """
    let command = """
      set +e
      echo '__K3S_SERVICE__'
      if [ -x /etc/init.d/k3s ]; then
        /etc/init.d/k3s status 2>&1
      elif command -v systemctl >/dev/null 2>&1; then
        systemctl status k3s --no-pager 2>&1
      fi
      echo '__K3S_VERSION__'
      /usr/local/bin/k3s --version 2>&1
      echo '__KUBECONFIG__'
      if [ -e /etc/rancher/k3s/k3s.yaml ]; then
        stat -c '%a %s' /etc/rancher/k3s/k3s.yaml 2>&1
      else
        echo 'missing'
      fi
      echo '__READYZ__'
      /usr/local/bin/k3s kubectl get --raw=/readyz 2>&1
      echo '__NETWORK__'
      ip -brief address 2>&1
      ss -lntp 2>&1
      iptables -S INPUT 2>&1
      echo '__K3S_LOG__'
      tail -n 80 /var/log/k3s.log 2>&1
      echo '__NODES__'
      /usr/local/bin/k3s kubectl get nodes -o wide 2>&1
      echo '__PODS__'
      /usr/local/bin/k3s kubectl get pods --all-namespaces -o wide 2>&1
      echo '__PROCESSES__'
      ps -ef 2>&1
      echo '__MEMORY__'
      head -n 12 /proc/meminfo 2>&1
      echo '__CGROUP__'
      cat /proc/self/cgroup 2>&1
      cat /proc/1/cgroup 2>&1
      grep cgroup /proc/mounts 2>&1
      echo 'controllers:'
      cat /sys/fs/cgroup/cgroup.controllers 2>&1
      echo 'subtree:'
      cat /sys/fs/cgroup/cgroup.subtree_control 2>&1
      echo 'type:'
      cat /sys/fs/cgroup/cgroup.type 2>&1
      ls -la /sys/fs/cgroup 2>&1
      echo '__KERNEL__'
      dmesg 2>&1 | tail -n 80
      sleep 5
      echo '__AFTER_5S__'
      /etc/init.d/k3s status 2>&1
      /usr/local/bin/k3s kubectl get --raw=/readyz 2>&1
      tail -n 120 /var/log/k3s.log 2>&1
      exit 0
      """
    guard
      let result = try? await rootCommands.executeRootCommand(
        command,
        in: current.identity,
        timeoutSeconds: 30
      )
    else {
      return "The disposable machine did not return diagnostics."
    }
    let combined = [result.standardOutput, result.standardError]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    return identityDiagnostics + "\n" + String(combined.suffix(30_000))
  }

  func cleanUp(machineID: String) async throws {
    guard var current = try await runtime.snapshot(id: machineID) else {
      return
    }

    if current.state != .stopped {
      do {
        try await machineService.stopMachine(current.identity)
      } catch {
        current = try await runtime.snapshot(id: machineID) ?? current
        if current.state != .stopped {
          try await machineService.forceStopMachine(
            current.identity,
            authorization: .confirmed(for: current.identity)
          )
        }
      }
    }

    guard let stopped = try await runtime.snapshot(id: machineID) else {
      return
    }
    guard stopped.state == .stopped else {
      throw LinuxMachineManagementError.forceStopNotConfirmed(machineID)
    }
    try await machineService.deleteMachine(stopped.identity)
    guard try await runtime.snapshot(id: machineID) == nil else {
      throw LinuxMachineManagementError.deletionNotConfirmed(machineID)
    }
  }
}

private struct LiveKubernetesCommandError: LocalizedError {
  let arguments: [String]
  let exitCode: Int32
  let detail: String

  var errorDescription: String? {
    "kubectl \(arguments.joined(separator: " ")) exited \(exitCode): \(detail)"
  }
}

private struct LiveKubernetesOperationError: LocalizedError {
  let operation: String
  let diagnostics: String

  var errorDescription: String? {
    "Kubernetes smoke failed: \(operation) Diagnostics: \(diagnostics)"
  }
}

private struct LiveKubernetesSmokeError: LocalizedError {
  let operation: String
  let diagnostics: String
  let cleanup: String

  var errorDescription: String? {
    "Kubernetes smoke failed: \(operation) Diagnostics: \(diagnostics) Cleanup also failed: \(cleanup)"
  }
}
