import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import Network

actor AppleKubernetesMachineRootCommandService:
  KubernetesMachineRootCommandRunning
{
  private let targetResolver: any LinuxMachineProcessTargetResolving
  private let commandExecutor: any RuntimeCommandExecuting

  init(
    targetResolver: any LinuxMachineProcessTargetResolving,
    commandExecutor: any RuntimeCommandExecuting
  ) {
    self.targetResolver = targetResolver
    self.commandExecutor = commandExecutor
  }

  func executeRootCommand(
    _ command: String,
    in target: LinuxMachineIdentity,
    timeoutSeconds: Int
  ) async throws -> ContainerCommandResult {
    let processTarget = try await targetResolver.resolve(target)
    let configuration = ProcessConfiguration(
      executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
      arguments: ["-s", command],
      environment: try Parser.allEnv(
        imageEnvs: [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ],
        envFiles: [],
        envs: []
      ),
      workingDirectory: "/",
      terminal: false,
      user: .id(uid: 0, gid: 0)
    )
    return try await commandExecutor.execute(
      in: processTarget.backingContainerID,
      configuration: configuration,
      timeoutSeconds: timeoutSeconds
    )
  }
}

actor AppleKubernetesClusterService: KubernetesClusterManaging {
  private struct Observation {
    let version: String
    let nodeCount: Int
    let readyNodeCount: Int
    let podCount: Int
    let runningPodCount: Int
  }

  private enum ObservationSection {
    case none
    case version
    case nodes
    case pods
  }

  private static let maximumKubeconfigBytes = 256 * 1_024
  private static let versionMarker = "__NATIVECONTAINERS_K3S_VERSION__"
  private static let nodesMarker = "__NATIVECONTAINERS_K3S_NODES__"
  private static let podsMarker = "__NATIVECONTAINERS_K3S_PODS__"

  private let machineCreator: any MachineCreating
  private let machineLifecycle: any MachineLifecycleManaging
  private let machineInventory: any LinuxMachineInventoryLoading
  private let rootCommands: any KubernetesMachineRootCommandRunning
  private let store: any KubernetesClusterDescriptorStoring
  private let now: @Sendable () -> Date

  init(
    machineCreator: any MachineCreating,
    machineLifecycle: any MachineLifecycleManaging,
    machineInventory: any LinuxMachineInventoryLoading,
    rootCommands: any KubernetesMachineRootCommandRunning,
    store: any KubernetesClusterDescriptorStoring = KubernetesClusterDescriptorStore(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.machineCreator = machineCreator
    self.machineLifecycle = machineLifecycle
    self.machineInventory = machineInventory
    self.rootCommands = rootCommands
    self.store = store
    self.now = now
  }

  func load() async throws -> KubernetesClusterSnapshot {
    guard let descriptor = try await store.load() else {
      return .absent
    }

    let machines = try await machineInventory.loadMachines()
    guard let machine = machines.first(where: { $0.id == descriptor.machine.id }) else {
      return KubernetesClusterSnapshot(
        state: .missing,
        descriptor: descriptor,
        detail: KubernetesClusterError.machineMissing(descriptor.machine.id).localizedDescription
      )
    }
    guard LinuxMachineIdentity(machine: machine) == descriptor.machine else {
      return KubernetesClusterSnapshot(
        state: .stale,
        descriptor: descriptor,
        machine: machine,
        detail:
          KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
          .localizedDescription
      )
    }
    guard machine.state.isRunning else {
      return KubernetesClusterSnapshot(
        state: descriptor.phase == .provisioning ? .provisioning : .stopped,
        descriptor: descriptor,
        machine: machine,
        detail:
          descriptor.phase == .provisioning
          ? String(localized: "Start or retry setup to finish installing K3s.")
          : nil
      )
    }

    do {
      let observation = try await observe(descriptor.machine)
      let readyDescriptor: KubernetesClusterDescriptor
      if descriptor.phase == .provisioning {
        readyDescriptor = descriptor.withPhase(.ready)
        try await store.save(readyDescriptor)
      } else {
        readyDescriptor = descriptor
      }
      return snapshot(
        descriptor: readyDescriptor,
        machine: machine,
        observation: observation
      )
    } catch {
      return KubernetesClusterSnapshot(
        state: descriptor.phase == .provisioning ? .provisioning : .degraded,
        descriptor: descriptor,
        machine: machine,
        detail: error.localizedDescription
      )
    }
  }

  func loadResourceInventory() async throws -> KubernetesResourceInventory {
    let descriptor = try await requireDescriptor()
    guard descriptor.phase == .ready else {
      throw KubernetesClusterError.setupNotRetryable
    }
    let machine = try await requireExactMachine(descriptor)
    guard machine.state.isRunning else {
      throw KubernetesClusterError.machineNotRunning(machine.id)
    }

    let result = try await rootCommands.executeRootCommand(
      KubernetesResourceInventoryParser.inventoryCommand,
      in: descriptor.machine,
      timeoutSeconds: 90
    )
    try validate(
      result,
      operation: String(localized: "Reading Kubernetes resources")
    )
    return try KubernetesResourceInventoryParser().parse(
      result.standardOutput,
      capturedAt: now()
    )
  }

  func provision(
    _ request: KubernetesClusterProvisionRequest,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    guard try await store.load() == nil else {
      throw KubernetesClusterError.alreadyConfigured
    }

    await progress(
      KubernetesClusterProgress(
        phase: .creatingMachine,
        detail: nil,
        fractionCompleted: nil
      )
    )

    let creationResult: LinuxMachineCreationResult
    do {
      creationResult = try await machineCreator.createMachine(
        request: try request.machineCreationRequest()
      ) { update in
        await progress(
          KubernetesClusterProgress(
            phase: .creatingMachine,
            detail: update.message,
            fractionCompleted: update.fractionCompleted
          )
        )
      }
    } catch let error as LinuxMachinePartialCompletionError {
      let descriptor = KubernetesClusterDescriptor(
        operationID: request.operationID,
        machine: error.result.identity,
        distribution: .current,
        phase: .provisioning,
        createdAt: now()
      )
      try await store.save(descriptor)
      throw error
    }

    let descriptor = KubernetesClusterDescriptor(
      operationID: request.operationID,
      machine: creationResult.identity,
      distribution: .current,
      phase: .provisioning,
      createdAt: now()
    )
    try await store.save(descriptor)
    return try await finishProvisioning(descriptor, progress: progress)
  }

  func retryProvisioning(
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    guard let descriptor = try await store.load(), descriptor.phase == .provisioning else {
      throw KubernetesClusterError.setupNotRetryable
    }
    _ = try await requireExactMachine(descriptor)
    try await machineLifecycle.startMachine(descriptor.machine)
    return try await finishProvisioning(descriptor, progress: progress)
  }

  func start() async throws -> KubernetesClusterSnapshot {
    let descriptor = try await requireDescriptor()
    _ = try await requireExactMachine(descriptor)
    try await machineLifecycle.startMachine(descriptor.machine)
    try await startK3s(descriptor.machine)
    try await waitForReadiness(descriptor.machine)

    let observation = try await observe(descriptor.machine)
    let readyDescriptor = descriptor.withPhase(.ready)
    if readyDescriptor != descriptor {
      try await store.save(readyDescriptor)
    }
    let machine = try await requireExactMachine(readyDescriptor)
    return snapshot(
      descriptor: readyDescriptor,
      machine: machine,
      observation: observation
    )
  }

  func stop() async throws -> KubernetesClusterSnapshot {
    let descriptor = try await requireDescriptor()
    _ = try await requireExactMachine(descriptor)
    try await machineLifecycle.stopMachine(descriptor.machine)
    let machine = try await requireExactMachine(descriptor)
    return KubernetesClusterSnapshot(
      state: descriptor.phase == .provisioning ? .provisioning : .stopped,
      descriptor: descriptor,
      machine: machine
    )
  }

  func forceStop() async throws -> KubernetesClusterSnapshot {
    let descriptor = try await requireDescriptor()
    _ = try await requireExactMachine(descriptor)
    try await machineLifecycle.forceStopMachine(
      descriptor.machine,
      authorization: .confirmed(for: descriptor.machine)
    )
    let machine = try await requireExactMachine(descriptor)
    return KubernetesClusterSnapshot(
      state: descriptor.phase == .provisioning ? .provisioning : .stopped,
      descriptor: descriptor,
      machine: machine
    )
  }

  func delete() async throws {
    let descriptor = try await requireDescriptor()
    let machines = try await machineInventory.loadMachines()
    guard let machine = machines.first(where: { $0.id == descriptor.machine.id }) else {
      try await store.remove()
      return
    }
    guard LinuxMachineIdentity(machine: machine) == descriptor.machine else {
      throw KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    }

    if machine.state != .stopped {
      try await machineLifecycle.stopMachine(descriptor.machine)
    }
    try await machineLifecycle.deleteMachine(descriptor.machine)

    let remaining = try await machineInventory.loadMachines()
    guard !remaining.contains(where: { $0.id == descriptor.machine.id }) else {
      throw KubernetesClusterError.deleteNotConfirmed
    }
    try await store.remove()
  }

  func forget() async throws {
    let descriptor = try await requireDescriptor()
    let machines = try await machineInventory.loadMachines()
    if let machine = machines.first(where: { $0.id == descriptor.machine.id }),
      LinuxMachineIdentity(machine: machine) == descriptor.machine
    {
      throw KubernetesClusterError.alreadyConfigured
    }
    try await store.remove()
  }

  func exportKubeconfig() async throws -> KubernetesKubeconfigExport {
    let descriptor = try await requireDescriptor()
    guard descriptor.phase == .ready else {
      throw KubernetesClusterError.setupNotRetryable
    }
    let machine = try await requireExactMachine(descriptor)
    guard machine.state.isRunning else {
      throw KubernetesClusterError.machineNotRunning(machine.id)
    }
    guard let address = machine.ipAddress else {
      throw KubernetesClusterError.missingIPAddress
    }
    let serverHost: String
    if IPv4Address(address) != nil {
      serverHost = address
    } else if IPv6Address(address) != nil {
      serverHost = "[\(address)]"
    } else {
      throw KubernetesClusterError.missingIPAddress
    }

    let result = try await rootCommands.executeRootCommand(
      "cat /etc/rancher/k3s/k3s.yaml",
      in: descriptor.machine,
      timeoutSeconds: 30
    )
    try validate(result, operation: String(localized: "Reading kubeconfig"))
    guard
      let data = result.standardOutput.data(using: .utf8),
      !data.isEmpty,
      data.count <= Self.maximumKubeconfigBytes
    else {
      throw KubernetesClusterError.invalidKubeconfig
    }

    let rewritten = try Self.rewriteKubeconfig(
      result.standardOutput,
      serverHost: serverHost
    )
    return KubernetesKubeconfigExport(
      fileName: "NativeContainers-\(machine.id)-kubeconfig.yaml",
      data: Data(rewritten.utf8)
    )
  }

  private func finishProvisioning(
    _ descriptor: KubernetesClusterDescriptor,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    await progress(
      KubernetesClusterProgress(
        phase: .preparingGuest,
        detail: String(localized: "Installing required guest packages"),
        fractionCompleted: 0.35
      )
    )

    await progress(
      KubernetesClusterProgress(
        phase: .installingK3s,
        detail: descriptor.distribution.version,
        fractionCompleted: 0.5
      )
    )

    let bootstrap = try await rootCommands.executeRootCommand(
      Self.bootstrapCommand(descriptor: descriptor),
      in: descriptor.machine,
      timeoutSeconds: 900
    )
    try validate(bootstrap, operation: String(localized: "K3s installation"))
    try await startK3s(descriptor.machine)

    await progress(
      KubernetesClusterProgress(
        phase: .waitingForReadiness,
        detail: nil,
        fractionCompleted: 0.8
      )
    )
    try await waitForReadiness(descriptor.machine)

    let observation = try await observe(descriptor.machine)
    let readyDescriptor = descriptor.withPhase(.ready)
    try await store.save(readyDescriptor)
    let machine = try await requireExactMachine(readyDescriptor)

    await progress(
      KubernetesClusterProgress(
        phase: .completed,
        detail: observation.version,
        fractionCompleted: 1
      )
    )
    return snapshot(
      descriptor: readyDescriptor,
      machine: machine,
      observation: observation
    )
  }

  private func startK3s(_ target: LinuxMachineIdentity) async throws {
    let command = """
      set -eu
      if [ -x /sbin/openrc-run ]; then
        test -x /etc/init.d/k3s
        mkdir -p /run/openrc
        touch /run/openrc/softlevel
        rc-update del k3s default >/dev/null 2>&1 || true
        rc-update del cgroups default >/dev/null 2>&1 || true
        if /etc/init.d/k3s status >/dev/null 2>&1; then
          /etc/init.d/k3s stop
        fi
        cgroups_ready=1
        for controller in cpu cpuset hugetlb memory pids; do
          grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control ||
            cgroups_ready=0
        done
        if [ "$cgroups_ready" -ne 1 ]; then
          system_cgroup=/sys/fs/cgroup/nativecontainers-system
          mkdir -p "$system_cgroup"
          for pid in $(cat /sys/fs/cgroup/cgroup.procs); do
            echo "$pid" >"$system_cgroup/cgroup.procs" 2>/dev/null || true
          done
          remaining=$(cat /sys/fs/cgroup/cgroup.procs)
          [ -z "$remaining" ]
          for controller in $(cat /sys/fs/cgroup/cgroup.controllers); do
            echo "+$controller" >/sys/fs/cgroup/cgroup.subtree_control
          done
        fi
        for controller in cpu cpuset hugetlb memory pids; do
          grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control || {
            echo "The cgroup $controller controller is unavailable." >&2
            exit 43
          }
        done
        /etc/init.d/k3s start
      elif command -v systemctl >/dev/null 2>&1; then
        test -f /etc/systemd/system/k3s.service
        systemctl start k3s
      else
        echo 'K3s installed without a supported service supervisor.' >&2
        exit 42
      fi
      """
    let result = try await rootCommands.executeRootCommand(
      command,
      in: target,
      timeoutSeconds: 60
    )
    try validate(result, operation: String(localized: "Starting K3s"))
  }

  private func waitForReadiness(_ target: LinuxMachineIdentity) async throws {
    let command = """
      attempt=0
      while [ "$attempt" -lt 30 ]; do
        if output=$(/usr/local/bin/k3s kubectl get --raw=/readyz 2>/dev/null) &&
          [ "$output" = "ok" ] &&
          test -s /run/flannel/subnet.env &&
          /usr/local/bin/k3s kubectl get serviceaccount default \
            --namespace default --output=name >/dev/null 2>&1 &&
          /usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null |
          grep -Eq '^[^[:space:]]+[[:space:]]+Ready([[:space:]]|$)' &&
          test -r /etc/rancher/k3s/k3s.yaml &&
          [ "$(stat -c '%a' /etc/rancher/k3s/k3s.yaml)" = "600" ]; then
          exit 0
        fi
        attempt=$((attempt + 1))
        sleep 2
      done
      exit 1
      """
    let result = try await rootCommands.executeRootCommand(
      command,
      in: target,
      timeoutSeconds: 75
    )
    guard !result.outputWasTruncated, result.exitCode == 0 else {
      throw KubernetesClusterError.readinessTimedOut
    }
  }

  private func observe(_ target: LinuxMachineIdentity) async throws -> Observation {
    let command = """
      set -eu
      printf '%s\n' '\(Self.versionMarker)'
      /usr/local/bin/k3s --version | head -n 1
      printf '%s\n' '\(Self.nodesMarker)'
      /usr/local/bin/k3s kubectl get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\\t"}{.status.conditions[?(@.type=="Ready")].status}{"\\n"}{end}'
      printf '%s\n' '\(Self.podsMarker)'
      /usr/local/bin/k3s kubectl get pods --all-namespaces -o 'jsonpath={range .items[*]}{.status.phase}{"\\n"}{end}'
      """
    let result = try await rootCommands.executeRootCommand(
      command,
      in: target,
      timeoutSeconds: 60
    )
    try validate(result, operation: String(localized: "Reading Kubernetes status"))
    return try Self.parseObservation(result.standardOutput)
  }

  private func requireDescriptor() async throws -> KubernetesClusterDescriptor {
    guard let descriptor = try await store.load() else {
      throw KubernetesClusterError.machineMissing(
        KubernetesClusterProvisionRequest.defaultMachineName
      )
    }
    return descriptor
  }

  private func requireExactMachine(
    _ descriptor: KubernetesClusterDescriptor
  ) async throws -> LinuxMachineRecord {
    let machines = try await machineInventory.loadMachines()
    guard let machine = machines.first(where: { $0.id == descriptor.machine.id }) else {
      throw KubernetesClusterError.machineMissing(descriptor.machine.id)
    }
    guard LinuxMachineIdentity(machine: machine) == descriptor.machine else {
      throw KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    }
    return machine
  }

  private func validate(
    _ result: ContainerCommandResult,
    operation: String
  ) throws {
    guard !result.outputWasTruncated else {
      throw KubernetesClusterError.guestOutputTooLarge
    }
    guard result.exitCode == 0 else {
      throw KubernetesClusterError.guestCommandFailed(
        operation: operation,
        detail: Self.sanitizedFailureDetail(result)
      )
    }
  }

  private func snapshot(
    descriptor: KubernetesClusterDescriptor,
    machine: LinuxMachineRecord,
    observation: Observation
  ) -> KubernetesClusterSnapshot {
    KubernetesClusterSnapshot(
      state: .ready,
      descriptor: descriptor,
      machine: machine,
      k3sVersion: observation.version,
      nodeCount: observation.nodeCount,
      readyNodeCount: observation.readyNodeCount,
      podCount: observation.podCount,
      runningPodCount: observation.runningPodCount
    )
  }

  private static func bootstrapCommand(
    descriptor: KubernetesClusterDescriptor
  ) -> String {
    let distribution = descriptor.distribution
    let scriptURL = shellQuote(distribution.installScriptURL.absoluteString)
    let expectedDigest = shellQuote(distribution.installScriptSHA256)
    let version = shellQuote(distribution.version)
    let nodeName = shellQuote(descriptor.machine.id)
    let installArguments = shellQuote(
      "server --secrets-encryption --write-kubeconfig-mode=600 --node-name \(descriptor.machine.id)"
    )

    return """
      set -eu
      if command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl openrc iptables ip6tables jq
      elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl iptables jq
        rm -rf /var/lib/apt/lists/*
      else
        echo 'The machine image needs apk or apt-get for K3s prerequisites.' >&2
        exit 41
      fi
      test -r /proc/cgroups
      script=/tmp/nativecontainers-k3s-install.sh
      trap 'rm -f "$script"' EXIT
      curl --fail --silent --show-error --location \(scriptURL) --output "$script"
      actual_digest=$(sha256sum "$script" | awk '{print $1}')
      test "$actual_digest" = \(expectedDigest)
      chmod 0700 "$script"
      export INSTALL_K3S_SKIP_ENABLE=true
      export INSTALL_K3S_VERSION=\(version)
      export INSTALL_K3S_EXEC=\(installArguments)
      "$script"
      test -x /usr/local/bin/k3s
      if [ -x /sbin/openrc-run ]; then
        test -x /etc/init.d/k3s
        sed -i 's/^[[:space:]]*want cgroups$/    # NativeContainers prepares cgroup v2 before K3s./' /etc/init.d/k3s
        ! grep -Eq '^[[:space:]]*want cgroups$' /etc/init.d/k3s
        rc-update del k3s default >/dev/null 2>&1 || true
        rc-update del cgroups default >/dev/null 2>&1 || true
      elif command -v systemctl >/dev/null 2>&1; then
        test -f /etc/systemd/system/k3s.service
        systemctl enable k3s >/dev/null
      else
        echo 'K3s installed without a supported service supervisor.' >&2
        exit 42
      fi
      printf '%s\n' \(nodeName) >/dev/null
      """
  }

  private static func parseObservation(_ output: String) throws -> Observation {
    var section = ObservationSection.none
    var version: String?
    var nodeCount = 0
    var readyNodeCount = 0
    var podCount = 0
    var runningPodCount = 0

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      switch line {
      case versionMarker:
        section = .version
      case nodesMarker:
        section = .nodes
      case podsMarker:
        section = .pods
      default:
        guard !line.isEmpty else { continue }
        switch section {
        case .none:
          continue
        case .version:
          if version == nil {
            version = line
          }
        case .nodes:
          let fields = line.split(whereSeparator: \.isWhitespace)
          guard fields.count >= 2 else {
            throw KubernetesClusterError.guestCommandFailed(
              operation: String(localized: "Parsing Kubernetes status"),
              detail: String(localized: "K3s returned an invalid node row.")
            )
          }
          nodeCount += 1
          if fields.last == "True" {
            readyNodeCount += 1
          }
        case .pods:
          podCount += 1
          if line == "Running" {
            runningPodCount += 1
          }
        }
      }
    }

    guard let version, !version.isEmpty, nodeCount > 0 else {
      throw KubernetesClusterError.guestCommandFailed(
        operation: String(localized: "Parsing Kubernetes status"),
        detail: String(localized: "K3s returned incomplete status output.")
      )
    }
    return Observation(
      version: version,
      nodeCount: nodeCount,
      readyNodeCount: readyNodeCount,
      podCount: podCount,
      runningPodCount: runningPodCount
    )
  }

  private static func rewriteKubeconfig(
    _ kubeconfig: String,
    serverHost: String
  ) throws -> String {
    guard
      kubeconfig.utf8.count <= maximumKubeconfigBytes,
      kubeconfig.contains("apiVersion:"),
      kubeconfig.contains("clusters:"),
      kubeconfig.contains("client-certificate-data:"),
      kubeconfig.contains("client-key-data:")
    else {
      throw KubernetesClusterError.invalidKubeconfig
    }

    var serverCount = 0
    let lines = kubeconfig.split(separator: "\n", omittingEmptySubsequences: false)
      .map { rawLine -> String in
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("server:") else { return line }

        let value = trimmed.dropFirst("server:".count)
          .trimmingCharacters(in: .whitespaces)
        guard
          let url = URL(string: value),
          url.scheme == "https",
          url.port == 6443,
          ["127.0.0.1", "localhost", "::1"].contains(url.host)
        else {
          return line
        }

        serverCount += 1
        let indentation = line.prefix(while: \.isWhitespace)
        return "\(indentation)server: https://\(serverHost):6443"
      }

    guard serverCount == 1 else {
      throw KubernetesClusterError.invalidKubeconfig
    }
    return lines.joined(separator: "\n")
  }

  private static func sanitizedFailureDetail(
    _ result: ContainerCommandResult
  ) -> String {
    let source =
      result.standardError.isEmpty
      ? result.standardOutput
      : result.standardError
    let collapsed =
      source
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    if collapsed.isEmpty {
      return String(localized: "The command exited with status \(result.exitCode).")
    }
    return String(collapsed.prefix(512))
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
