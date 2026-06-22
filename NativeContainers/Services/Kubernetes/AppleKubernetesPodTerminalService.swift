import ContainerAPIClient
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import MachineAPIClient

struct KubernetesRunningClusterTarget: Equatable, Sendable {
  let descriptor: KubernetesClusterDescriptor
  let machine: LinuxMachineRecord
}

protocol KubernetesRunningClusterTargetResolving: Sendable {
  func resolveRunningTarget(
    expectedMachine: LinuxMachineIdentity?
  ) async throws -> KubernetesRunningClusterTarget
}

actor AppleKubernetesRunningClusterTargetResolver:
  KubernetesRunningClusterTargetResolving
{
  private let store: any KubernetesClusterDescriptorStoring
  private let machineInventory: any LinuxMachineInventoryLoading

  init(
    store: any KubernetesClusterDescriptorStoring,
    machineInventory: any LinuxMachineInventoryLoading
  ) {
    self.store = store
    self.machineInventory = machineInventory
  }

  func resolveRunningTarget(
    expectedMachine: LinuxMachineIdentity?
  ) async throws -> KubernetesRunningClusterTarget {
    guard let descriptor = try await store.load() else {
      throw KubernetesClusterError.machineMissing(
        KubernetesClusterProvisionRequest.defaultMachineName
      )
    }
    guard descriptor.phase == .ready else {
      throw KubernetesClusterError.setupNotRetryable
    }
    if let expectedMachine {
      guard
        expectedMachine.hasStableCreationIdentity,
        descriptor.machine == expectedMachine
      else {
        throw KubernetesClusterError.machineIdentityChanged(expectedMachine.id)
      }
    }

    let machines = try await machineInventory.loadMachines()
    guard let machine = machines.first(where: { $0.id == descriptor.machine.id }) else {
      throw KubernetesClusterError.machineMissing(descriptor.machine.id)
    }
    guard LinuxMachineIdentity(machine: machine) == descriptor.machine else {
      throw KubernetesClusterError.machineIdentityChanged(descriptor.machine.id)
    }
    guard machine.state.isRunning else {
      throw KubernetesClusterError.machineNotRunning(machine.id)
    }
    return KubernetesRunningClusterTarget(
      descriptor: descriptor,
      machine: machine
    )
  }
}

protocol KubernetesPodTerminalOpening: Sendable {
  func openTerminal(
    in target: KubernetesPodTerminalIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession
}

struct UnavailableKubernetesPodTerminalService:
  KubernetesPodTerminalOpening
{
  func openTerminal(
    in target: KubernetesPodTerminalIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    throw TerminalWorkspaceError.terminalServiceUnavailable
  }
}

protocol KubernetesPodTerminalSessionLaunching: Sendable {
  func openSession(
    backingContainerID: String,
    configuration: ProcessConfiguration,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession
}

struct AppleKubernetesPodTerminalSessionLauncher:
  KubernetesPodTerminalSessionLaunching
{
  private let processClient: any AppleRuntimeProcessCreating

  init(
    processClient: any AppleRuntimeProcessCreating =
      AppleContainerProcessXPCClient()
  ) {
    self.processClient = processClient
  }

  func openSession(
    backingContainerID: String,
    configuration: ProcessConfiguration,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    let transport = PipeContainerTerminalTransport()
    do {
      let process = try await processClient.createRuntimeProcess(
        containerID: backingContainerID,
        processID: UUID().uuidString.lowercased(),
        configuration: configuration,
        standardIO: [
          transport.childStandardInput,
          transport.childStandardOutput,
          nil,
        ]
      )
      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: request.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: request.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }
}

actor AppleKubernetesPodTerminalService: KubernetesPodTerminalOpening {
  static let shellDiscoveryMarker =
    "__NATIVECONTAINERS_K3S_POD_SHELL__"
  static let supportedShells = [
    "/bin/sh",
    "/bin/bash",
    "/bin/ash",
    "/usr/bin/bash",
    "/bin/zsh",
    "/usr/bin/zsh",
  ]

  private let runningTargetResolver: any KubernetesRunningClusterTargetResolving
  private let rootCommands: any KubernetesMachineRootCommandRunning
  private let machineProcessTargetResolver: any LinuxMachineProcessTargetResolving
  private let sessionLauncher: any KubernetesPodTerminalSessionLaunching

  init(
    runningTargetResolver:
      any KubernetesRunningClusterTargetResolving,
    rootCommands: any KubernetesMachineRootCommandRunning,
    machineProcessTargetResolver:
      any LinuxMachineProcessTargetResolving,
    sessionLauncher:
      any KubernetesPodTerminalSessionLaunching =
      AppleKubernetesPodTerminalSessionLauncher()
  ) {
    self.runningTargetResolver = runningTargetResolver
    self.rootCommands = rootCommands
    self.machineProcessTargetResolver = machineProcessTargetResolver
    self.sessionLauncher = sessionLauncher
  }

  func openTerminal(
    in target: KubernetesPodTerminalIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    try Self.validate(target)
    try Self.validate(request)

    _ = try await runningTargetResolver.resolveRunningTarget(
      expectedMachine: target.machine
    )
    let shell = try await discoverShell(in: target)
    _ = try await runningTargetResolver.resolveRunningTarget(
      expectedMachine: target.machine
    )
    let processTarget = try await machineProcessTargetResolver.resolve(
      target.machine
    )
    guard processTarget.identity == target.machine else {
      throw KubernetesClusterError.machineIdentityChanged(target.machine.id)
    }

    let configuration = try Self.processConfiguration(
      target: target,
      shell: shell
    )
    return try await sessionLauncher.openSession(
      backingContainerID: processTarget.backingContainerID,
      configuration: configuration,
      request: request
    )
  }

  private func discoverShell(
    in target: KubernetesPodTerminalIdentity
  ) async throws -> String {
    let result = try await rootCommands.executeRootCommand(
      Self.shellDiscoveryCommand(target),
      in: target.machine,
      timeoutSeconds: 45
    )
    guard !result.outputWasTruncated else {
      throw KubernetesClusterError.guestOutputTooLarge
    }
    guard result.exitCode == 0 else {
      if result.exitCode == 66 {
        throw KubernetesClusterError.podIdentityChanged(target.podName)
      }
      throw KubernetesClusterError.podShellUnavailable
    }

    let output = result.standardOutput.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard output.hasPrefix(Self.shellDiscoveryMarker) else {
      throw KubernetesClusterError.invalidPodShellDiscovery
    }
    let shell = String(output.dropFirst(Self.shellDiscoveryMarker.count))
    guard Self.supportedShells.contains(shell) else {
      throw KubernetesClusterError.invalidPodShellDiscovery
    }
    return shell
  }

  private static func validate(
    _ target: KubernetesPodTerminalIdentity
  ) throws {
    guard
      target.machine.hasStableCreationIdentity,
      KubernetesResourceReferenceValidator.isPodUID(target.podUID),
      KubernetesResourceReferenceValidator.isNamespace(target.namespace),
      KubernetesResourceReferenceValidator.isResourceName(target.podName),
      KubernetesResourceReferenceValidator.isContainerName(
        target.containerName
      )
    else {
      throw KubernetesClusterError.invalidKubernetesResourceReference
    }
  }

  private static func validate(
    _ request: ContainerTerminalRequest
  ) throws {
    guard
      request.program == .preferredShell,
      request.arguments.isEmpty,
      request.environment.isEmpty,
      request.workingDirectory == nil
    else {
      throw KubernetesClusterError.unsupportedPodTerminalRequest
    }
  }

  private static func shellDiscoveryCommand(
    _ target: KubernetesPodTerminalIdentity
  ) -> String {
    let candidates =
      supportedShells
      .map { "'\($0)'" }
      .joined(separator: " ")
    return """
      set -eu
      pod_uid=$(/usr/local/bin/k3s kubectl get pod --namespace=\(target.namespace) --output=jsonpath='{.metadata.uid}' --request-timeout=5s \(target.podName))
      if [ "$pod_uid" != '\(target.podUID)' ]; then
        exit 66
      fi
      for shell in \(candidates); do
        if /usr/local/bin/k3s kubectl exec --namespace=\(target.namespace) --container=\(target.containerName) --pod-running-timeout=5s --request-timeout=5s \(target.podName) -- "$shell" -c 'exit 0' >/dev/null 2>&1; then
          pod_uid=$(/usr/local/bin/k3s kubectl get pod --namespace=\(target.namespace) --output=jsonpath='{.metadata.uid}' --request-timeout=5s \(target.podName))
          if [ "$pod_uid" != '\(target.podUID)' ]; then
            exit 66
          fi
          printf '\(shellDiscoveryMarker)%s\n' "$shell"
          exit 0
        fi
      done
      exit 67
      """
  }

  private static func processConfiguration(
    target: KubernetesPodTerminalIdentity,
    shell: String
  ) throws -> ProcessConfiguration {
    ProcessConfiguration(
      executable:
        "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
      arguments: [
        "-s",
        terminalCommand(target: target, shell: shell),
      ],
      environment: try Parser.allEnv(
        imageEnvs: [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ],
        envFiles: [],
        envs: []
      ),
      workingDirectory: "/",
      terminal: true,
      user: .id(uid: 0, gid: 0)
    )
  }

  private static func terminalCommand(
    target: KubernetesPodTerminalIdentity,
    shell: String
  ) -> String {
    """
    set -eu
    pod_uid=$(/usr/local/bin/k3s kubectl get pod --namespace=\(target.namespace) --output=jsonpath='{.metadata.uid}' --request-timeout=5s \(target.podName))
    if [ "$pod_uid" != '\(target.podUID)' ]; then
      echo 'The selected Pod identity changed.' >&2
      exit 66
    fi
    exec /usr/local/bin/k3s kubectl exec --namespace=\(target.namespace) --container=\(target.containerName) --stdin=true --tty=true --pod-running-timeout=15s \(target.podName) -- \(shell)
    """
  }
}
