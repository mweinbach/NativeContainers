import Foundation

struct KubernetesDistribution: Codable, Equatable, Sendable {
  let version: String
  let installScriptURL: URL
  let installScriptSHA256: String

  static let current = KubernetesDistribution(
    version: "v1.36.1+k3s1",
    installScriptURL: URL(
      string:
        "https://raw.githubusercontent.com/k3s-io/k3s/v1.36.1%2Bk3s1/install.sh"
    )!,
    installScriptSHA256:
      "46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
  )
}

enum KubernetesClusterDescriptorPhase: String, Codable, Equatable, Sendable {
  case provisioning
  case ready
}

struct KubernetesClusterDescriptor: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let operationID: UUID
  let machine: LinuxMachineIdentity
  let distribution: KubernetesDistribution
  let phase: KubernetesClusterDescriptorPhase
  let createdAt: Date

  init(
    operationID: UUID,
    machine: LinuxMachineIdentity,
    distribution: KubernetesDistribution,
    phase: KubernetesClusterDescriptorPhase,
    createdAt: Date
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.operationID = operationID
    self.machine = machine
    self.distribution = distribution
    self.phase = phase
    self.createdAt = createdAt
  }

  func withPhase(_ phase: KubernetesClusterDescriptorPhase) -> Self {
    Self(
      operationID: operationID,
      machine: machine,
      distribution: distribution,
      phase: phase,
      createdAt: createdAt
    )
  }
}

struct KubernetesClusterProvisionRequest: Equatable, Sendable {
  static let defaultMachineName = "nativecontainers-kubernetes"
  static let defaultImageReference = "docker.io/library/alpine:3.22"
  static let minimumCPUCount = 2
  static let minimumMemoryBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
  static let defaultMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

  let operationID: UUID
  let machineName: String
  let imageReference: String
  let cpuCount: Int
  let memoryBytes: UInt64

  init(
    operationID: UUID = UUID(),
    machineName: String = defaultMachineName,
    imageReference: String = defaultImageReference,
    cpuCount: Int = 4,
    memoryBytes: UInt64 = defaultMemoryBytes
  ) throws {
    guard cpuCount >= Self.minimumCPUCount else {
      throw KubernetesClusterError.insufficientCPU
    }
    guard memoryBytes >= Self.minimumMemoryBytes else {
      throw KubernetesClusterError.insufficientMemory
    }

    let imageReference = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !imageReference.isEmpty,
      imageReference.count <= 512,
      !imageReference.contains(where: \.isWhitespace),
      imageReference.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw KubernetesClusterError.invalidImageReference
    }

    _ = try LinuxMachineCreationRequest(
      name: machineName,
      imageReference: imageReference,
      architecture: .arm64,
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      homeMount: .none,
      startAfterCreation: true
    )

    self.operationID = operationID
    self.machineName = machineName
    self.imageReference = imageReference
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
  }

  func machineCreationRequest() throws -> LinuxMachineCreationRequest {
    try LinuxMachineCreationRequest(
      name: machineName,
      imageReference: imageReference,
      architecture: .arm64,
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      homeMount: .none,
      startAfterCreation: true
    )
  }
}

enum KubernetesClusterProvisionPhase: String, Equatable, Sendable {
  case creatingMachine
  case preparingGuest
  case installingK3s
  case waitingForReadiness
  case completed

  var title: LocalizedStringResource {
    switch self {
    case .creatingMachine:
      "Creating the dedicated Linux machine"
    case .preparingGuest:
      "Preparing the Linux guest"
    case .installingK3s:
      "Installing the pinned K3s release"
    case .waitingForReadiness:
      "Waiting for the Kubernetes API"
    case .completed:
      "Kubernetes is ready"
    }
  }
}

struct KubernetesClusterProgress: Equatable, Sendable {
  let phase: KubernetesClusterProvisionPhase
  let detail: String?
  let fractionCompleted: Double?
}

typealias KubernetesClusterProgressHandler =
  @Sendable (KubernetesClusterProgress) async -> Void

enum KubernetesClusterState: String, Codable, Equatable, Sendable {
  case absent
  case provisioning
  case stopped
  case ready
  case degraded
  case missing
  case stale

  var title: LocalizedStringResource {
    switch self {
    case .absent:
      "Not configured"
    case .provisioning:
      "Setup incomplete"
    case .stopped:
      "Stopped"
    case .ready:
      "Ready"
    case .degraded:
      "Needs attention"
    case .missing:
      "Machine missing"
    case .stale:
      "Machine identity changed"
    }
  }
}

struct KubernetesClusterSnapshot: Equatable, Sendable {
  let state: KubernetesClusterState
  let descriptor: KubernetesClusterDescriptor?
  let machine: LinuxMachineRecord?
  let k3sVersion: String?
  let nodeCount: Int
  let readyNodeCount: Int
  let podCount: Int
  let runningPodCount: Int
  let detail: String?

  init(
    state: KubernetesClusterState,
    descriptor: KubernetesClusterDescriptor? = nil,
    machine: LinuxMachineRecord? = nil,
    k3sVersion: String? = nil,
    nodeCount: Int = 0,
    readyNodeCount: Int = 0,
    podCount: Int = 0,
    runningPodCount: Int = 0,
    detail: String? = nil
  ) {
    self.state = state
    self.descriptor = descriptor
    self.machine = machine
    self.k3sVersion = k3sVersion
    self.nodeCount = max(0, nodeCount)
    self.readyNodeCount = max(0, min(readyNodeCount, nodeCount))
    self.podCount = max(0, podCount)
    self.runningPodCount = max(0, min(runningPodCount, podCount))
    self.detail = detail
  }

  static let absent = KubernetesClusterSnapshot(state: .absent)
}

struct KubernetesKubeconfigExport: Equatable, Sendable {
  let fileName: String
  let data: Data
}

protocol KubernetesClusterDescriptorStoring: Sendable {
  func load() async throws -> KubernetesClusterDescriptor?
  func save(_ descriptor: KubernetesClusterDescriptor) async throws
  func remove() async throws
}

protocol KubernetesMachineRootCommandRunning: Sendable {
  func executeRootCommand(
    _ command: String,
    in target: LinuxMachineIdentity,
    timeoutSeconds: Int
  ) async throws -> ContainerCommandResult
}

protocol KubernetesClusterManaging: Sendable {
  func load() async throws -> KubernetesClusterSnapshot
  func loadResourceInventory() async throws -> KubernetesResourceInventory
  func loadPodLogs(
    _ request: KubernetesPodLogRequest
  ) async throws -> KubernetesPodLogSnapshot
  func scaleWorkload(
    _ request: KubernetesWorkloadScaleRequest
  ) async throws -> KubernetesWorkloadScaleResult
  func restartWorkload(
    _ request: KubernetesWorkloadRestartRequest
  ) async throws -> KubernetesWorkloadRestartResult
  func deleteWorkload(
    _ request: KubernetesWorkloadDeleteRequest
  ) async throws -> KubernetesWorkloadDeleteResult
  func provision(
    _ request: KubernetesClusterProvisionRequest,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot
  func retryProvisioning(
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot
  func start() async throws -> KubernetesClusterSnapshot
  func stop() async throws -> KubernetesClusterSnapshot
  func forceStop() async throws -> KubernetesClusterSnapshot
  func delete() async throws
  func forget() async throws
  func exportKubeconfig() async throws -> KubernetesKubeconfigExport
}

struct UnavailableKubernetesClusterService: KubernetesClusterManaging {
  func load() async throws -> KubernetesClusterSnapshot {
    .absent
  }

  func loadResourceInventory() async throws -> KubernetesResourceInventory {
    throw KubernetesClusterError.unavailable
  }

  func loadPodLogs(
    _ request: KubernetesPodLogRequest
  ) async throws -> KubernetesPodLogSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func scaleWorkload(
    _ request: KubernetesWorkloadScaleRequest
  ) async throws -> KubernetesWorkloadScaleResult {
    throw KubernetesClusterError.unavailable
  }

  func restartWorkload(
    _ request: KubernetesWorkloadRestartRequest
  ) async throws -> KubernetesWorkloadRestartResult {
    throw KubernetesClusterError.unavailable
  }

  func deleteWorkload(
    _ request: KubernetesWorkloadDeleteRequest
  ) async throws -> KubernetesWorkloadDeleteResult {
    throw KubernetesClusterError.unavailable
  }

  func provision(
    _ request: KubernetesClusterProvisionRequest,
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func retryProvisioning(
    progress: @escaping KubernetesClusterProgressHandler
  ) async throws -> KubernetesClusterSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func start() async throws -> KubernetesClusterSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func stop() async throws -> KubernetesClusterSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func forceStop() async throws -> KubernetesClusterSnapshot {
    throw KubernetesClusterError.unavailable
  }

  func delete() async throws {
    throw KubernetesClusterError.unavailable
  }

  func forget() async throws {
    throw KubernetesClusterError.unavailable
  }

  func exportKubeconfig() async throws -> KubernetesKubeconfigExport {
    throw KubernetesClusterError.unavailable
  }
}

enum KubernetesClusterError: LocalizedError, Equatable, Sendable {
  case unavailable
  case insufficientCPU
  case insufficientMemory
  case invalidImageReference
  case alreadyConfigured
  case descriptorUnsafe
  case descriptorInvalid
  case machineMissing(String)
  case machineIdentityChanged(String)
  case setupNotRetryable
  case machineNotRunning(String)
  case guestCommandFailed(operation: String, detail: String)
  case guestOutputTooLarge
  case resourceInventoryTooLarge
  case invalidResourceInventory
  case invalidKubernetesResourceReference
  case invalidPodLogSnapshot
  case invalidWorkloadScaleRequest
  case workloadNotScalable
  case workloadIdentityChanged(String)
  case workloadReplicaCountChanged(String)
  case workloadScaleNotApplied(String)
  case invalidWorkloadScaleResult
  case invalidWorkloadRestartRequest
  case workloadNotRestartable
  case workloadRestartRejected(String)
  case workloadRestartNotConfirmed(String)
  case invalidWorkloadRestartResult
  case invalidWorkloadDeleteRequest
  case workloadDeleteRejected(String)
  case workloadDeleteNotConfirmed(String)
  case workloadDeleteVerificationFailed(String)
  case invalidWorkloadDeleteResult
  case invalidPodShellDiscovery
  case podShellUnavailable
  case podIdentityChanged(String)
  case podIdentityVerificationFailed
  case unsupportedPodTerminalRequest
  case readinessTimedOut
  case missingIPAddress
  case invalidKubeconfig
  case deleteNotConfirmed
  case ioFailure(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      String(localized: "Kubernetes management is unavailable in this app context.")
    case .insufficientCPU:
      String(localized: "K3s requires at least 2 virtual CPUs.")
    case .insufficientMemory:
      String(localized: "K3s requires at least 2 GiB of memory.")
    case .invalidImageReference:
      String(localized: "Enter one OCI image reference without spaces or control characters.")
    case .alreadyConfigured:
      String(localized: "A NativeContainers Kubernetes cluster is already configured.")
    case .descriptorUnsafe:
      String(localized: "The private Kubernetes cluster record is not safe to use.")
    case .descriptorInvalid:
      String(localized: "The private Kubernetes cluster record is invalid.")
    case .machineMissing(let name):
      String(localized: "The dedicated Kubernetes machine “\(name)” no longer exists.")
    case .machineIdentityChanged(let name):
      String(
        localized:
          "The Linux machine named “\(name)” was replaced. NativeContainers refused to address it."
      )
    case .setupNotRetryable:
      String(localized: "There is no incomplete Kubernetes setup to retry.")
    case .machineNotRunning(let name):
      String(localized: "The Kubernetes machine “\(name)” is not running.")
    case .guestCommandFailed(let operation, let detail):
      String(localized: "\(operation) failed in the Kubernetes machine: \(detail)")
    case .guestOutputTooLarge:
      String(localized: "The Kubernetes machine returned more output than the safe limit.")
    case .resourceInventoryTooLarge:
      String(localized: "The Kubernetes resource inventory exceeds the safe item limit.")
    case .invalidResourceInventory:
      String(localized: "K3s returned an invalid Kubernetes resource inventory.")
    case .invalidKubernetesResourceReference:
      String(localized: "The Kubernetes resource reference is invalid.")
    case .invalidPodLogSnapshot:
      String(localized: "K3s returned an invalid Pod log snapshot.")
    case .invalidWorkloadScaleRequest:
      String(localized: "The Kubernetes workload scale request is invalid.")
    case .workloadNotScalable:
      String(localized: "Only Deployments and StatefulSets can be scaled.")
    case .workloadIdentityChanged(let name):
      String(localized: "Workload “\(name)” changed after it was reviewed.")
    case .workloadReplicaCountChanged(let name):
      String(localized: "Workload “\(name)” has a different replica count now.")
    case .workloadScaleNotApplied(let name):
      String(localized: "K3s did not confirm the requested scale for “\(name)”.")
    case .invalidWorkloadScaleResult:
      String(localized: "K3s returned an invalid workload scale result.")
    case .invalidWorkloadRestartRequest:
      String(localized: "The Kubernetes workload restart request is invalid.")
    case .workloadNotRestartable:
      String(localized: "Only Deployments, StatefulSets, and DaemonSets can be restarted.")
    case .workloadRestartRejected(let name):
      String(
        localized:
          "K3s rejected the reviewed restart for “\(name)”. Refresh resources and try again.")
    case .workloadRestartNotConfirmed(let name):
      String(localized: "K3s could not confirm the restart for “\(name)”.")
    case .invalidWorkloadRestartResult:
      String(localized: "K3s returned an invalid workload restart result.")
    case .invalidWorkloadDeleteRequest:
      String(localized: "The Kubernetes workload deletion request is invalid.")
    case .workloadDeleteRejected(let name):
      String(
        localized:
          "K3s rejected deletion of the reviewed workload “\(name)”. Refresh resources and try again."
      )
    case .workloadDeleteNotConfirmed(let name):
      String(localized: "K3s did not confirm deletion of the reviewed workload “\(name)”.")
    case .workloadDeleteVerificationFailed(let name):
      String(
        localized: "Deletion of “\(name)” was accepted, but K3s could not verify its current state."
      )
    case .invalidWorkloadDeleteResult:
      String(localized: "K3s returned an invalid workload deletion result.")
    case .invalidPodShellDiscovery:
      String(localized: "K3s returned an invalid Pod shell discovery result.")
    case .podShellUnavailable:
      String(localized: "The selected container does not have a supported interactive shell.")
    case .podIdentityChanged(let name):
      String(localized: "Pod “\(name)” was replaced after it was selected.")
    case .podIdentityVerificationFailed:
      String(localized: "K3s could not verify the selected Pod while opening its terminal.")
    case .unsupportedPodTerminalRequest:
      String(localized: "Kubernetes Pod terminals use the discovered container shell.")
    case .readinessTimedOut:
      String(localized: "The Kubernetes API did not become ready before the bounded deadline.")
    case .missingIPAddress:
      String(localized: "The Kubernetes machine has no current IP address for kubeconfig export.")
    case .invalidKubeconfig:
      String(localized: "K3s returned an invalid kubeconfig.")
    case .deleteNotConfirmed:
      String(localized: "The dedicated Kubernetes machine did not confirm deletion.")
    case .ioFailure(let operation):
      String(localized: "Kubernetes storage could not \(operation).")
    }
  }
}
