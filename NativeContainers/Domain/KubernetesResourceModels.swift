import Foundation

enum KubernetesWorkloadKind: String, CaseIterable, Codable, Equatable, Sendable {
  case deployment
  case statefulSet
  case daemonSet
  case job

  var title: LocalizedStringResource {
    switch self {
    case .deployment:
      "Deployment"
    case .statefulSet:
      "StatefulSet"
    case .daemonSet:
      "DaemonSet"
    case .job:
      "Job"
    }
  }

  var supportsScaling: Bool {
    switch self {
    case .deployment, .statefulSet:
      true
    case .daemonSet, .job:
      false
    }
  }

  var supportsRestart: Bool {
    switch self {
    case .deployment, .statefulSet, .daemonSet:
      true
    case .job:
      false
    }
  }
}

struct KubernetesWorkloadRecord: Identifiable, Equatable, Sendable {
  let uid: String
  let resourceVersion: String
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind
  let desiredCount: Int
  let readyCount: Int
  let availableCount: Int
  let failedCount: Int

  var id: String {
    uid
  }

  init(
    uid: String,
    resourceVersion: String,
    namespace: String,
    name: String,
    kind: KubernetesWorkloadKind,
    desiredCount: Int,
    readyCount: Int,
    availableCount: Int,
    failedCount: Int
  ) {
    self.uid = uid
    self.resourceVersion = resourceVersion
    self.namespace = namespace
    self.name = name
    self.kind = kind
    self.desiredCount = max(0, desiredCount)
    self.readyCount = max(0, readyCount)
    self.availableCount = max(0, availableCount)
    self.failedCount = max(0, failedCount)
  }
}

struct KubernetesWorkloadScaleRequest: Equatable, Sendable {
  static let maximumReplicaCount = 1_000

  let workloadUID: String
  let resourceVersion: String
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind
  let currentReplicas: Int
  let targetReplicas: Int

  init(
    workload: KubernetesWorkloadRecord,
    targetReplicas: Int
  ) throws {
    guard workload.kind.supportsScaling else {
      throw KubernetesClusterError.workloadNotScalable
    }
    guard
      KubernetesResourceReferenceValidator.isUID(workload.uid),
      KubernetesResourceReferenceValidator.isResourceVersion(
        workload.resourceVersion
      ),
      KubernetesResourceReferenceValidator.isNamespace(workload.namespace),
      KubernetesResourceReferenceValidator.isResourceName(workload.name),
      (0...Self.maximumReplicaCount).contains(workload.desiredCount),
      (0...Self.maximumReplicaCount).contains(targetReplicas),
      targetReplicas != workload.desiredCount
    else {
      throw KubernetesClusterError.invalidWorkloadScaleRequest
    }

    workloadUID = workload.uid
    resourceVersion = workload.resourceVersion
    namespace = workload.namespace
    name = workload.name
    kind = workload.kind
    currentReplicas = workload.desiredCount
    self.targetReplicas = targetReplicas
  }
}

struct KubernetesWorkloadScaleResult: Equatable, Sendable {
  let request: KubernetesWorkloadScaleRequest
  let resourceVersion: String
  let observedReplicas: Int
  let capturedAt: Date
}

struct KubernetesWorkloadRestartRequest: Equatable, Sendable {
  let workloadUID: String
  let resourceVersion: String
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind

  init(workload: KubernetesWorkloadRecord) throws {
    guard workload.kind.supportsRestart else {
      throw KubernetesClusterError.workloadNotRestartable
    }
    guard
      KubernetesResourceReferenceValidator.isUID(workload.uid),
      KubernetesResourceReferenceValidator.isResourceVersion(
        workload.resourceVersion
      ),
      KubernetesResourceReferenceValidator.isNamespace(workload.namespace),
      KubernetesResourceReferenceValidator.isResourceName(workload.name)
    else {
      throw KubernetesClusterError.invalidWorkloadRestartRequest
    }

    workloadUID = workload.uid
    resourceVersion = workload.resourceVersion
    namespace = workload.namespace
    name = workload.name
    kind = workload.kind
  }
}

struct KubernetesWorkloadRestartResult: Equatable, Sendable {
  let request: KubernetesWorkloadRestartRequest
  let resourceVersion: String
  let capturedAt: Date
}

struct KubernetesWorkloadDeleteRequest: Equatable, Sendable {
  let workloadUID: String
  let resourceVersion: String
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind

  init(workload: KubernetesWorkloadRecord) throws {
    guard
      KubernetesResourceReferenceValidator.isUID(workload.uid),
      KubernetesResourceReferenceValidator.isResourceVersion(
        workload.resourceVersion
      ),
      KubernetesResourceReferenceValidator.isNamespace(workload.namespace),
      KubernetesResourceReferenceValidator.isResourceName(workload.name)
    else {
      throw KubernetesClusterError.invalidWorkloadDeleteRequest
    }

    workloadUID = workload.uid
    resourceVersion = workload.resourceVersion
    namespace = workload.namespace
    name = workload.name
    kind = workload.kind
  }
}

enum KubernetesWorkloadDeleteOutcome: String, Equatable, Sendable {
  case deleted
  case replacementPresent
  case pendingFinalizers
}

struct KubernetesWorkloadDeleteResult: Equatable, Sendable {
  let request: KubernetesWorkloadDeleteRequest
  let outcome: KubernetesWorkloadDeleteOutcome
  let capturedAt: Date
}

enum KubernetesPodPhase: String, CaseIterable, Codable, Equatable, Sendable {
  case pending
  case running
  case succeeded
  case failed
  case unknown

  var title: LocalizedStringResource {
    switch self {
    case .pending:
      "Pending"
    case .running:
      "Running"
    case .succeeded:
      "Succeeded"
    case .failed:
      "Failed"
    case .unknown:
      "Unknown"
    }
  }
}

struct KubernetesPodRecord: Identifiable, Equatable, Sendable {
  let uid: String
  let namespace: String
  let name: String
  let phase: KubernetesPodPhase
  let readyContainerCount: Int
  let containerNames: [String]
  let restartCount: Int
  let nodeName: String?

  var id: String {
    uid
  }

  var containerCount: Int {
    containerNames.count
  }

  init(
    uid: String,
    namespace: String,
    name: String,
    phase: KubernetesPodPhase,
    readyContainerCount: Int,
    containerNames: [String],
    restartCount: Int,
    nodeName: String?
  ) {
    self.uid = uid
    self.namespace = namespace
    self.name = name
    self.phase = phase
    self.containerNames = containerNames
    self.readyContainerCount = max(
      0,
      min(readyContainerCount, containerNames.count)
    )
    self.restartCount = max(0, restartCount)
    self.nodeName = nodeName
  }
}

struct KubernetesPodLogRequest: Equatable, Sendable {
  let podUID: String
  let namespace: String
  let podName: String
  let containerName: String
}

struct KubernetesPodLogSnapshot: Equatable, Sendable {
  let request: KubernetesPodLogRequest
  let text: String
  let capturedAt: Date
  let isTruncated: Bool
}

struct KubernetesServicePortRecord: Identifiable, Equatable, Sendable {
  let name: String?
  let protocolName: String
  let port: Int
  let targetPort: String
  let nodePort: Int?

  var id: String {
    "\(name ?? "")|\(protocolName)|\(port)|\(targetPort)"
  }
}

struct KubernetesServiceRecord: Identifiable, Equatable, Sendable {
  let namespace: String
  let name: String
  let type: String
  let clusterIP: String?
  let ports: [KubernetesServicePortRecord]

  var id: String {
    "\(namespace)/\(name)"
  }
}

struct KubernetesResourceInventory: Equatable, Sendable {
  let workloads: [KubernetesWorkloadRecord]
  let pods: [KubernetesPodRecord]
  let services: [KubernetesServiceRecord]
  let capturedAt: Date
}

enum KubernetesResourceReferenceValidator {
  static func isNamespace(_ value: String) -> Bool {
    isDNSLabel(value)
  }

  static func isResourceName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 253 else { return false }
    return value.split(separator: ".", omittingEmptySubsequences: false)
      .allSatisfy { isDNSLabel(String($0)) }
  }

  static func isContainerName(_ value: String) -> Bool {
    isDNSLabel(value)
  }

  static func isPodUID(_ value: String) -> Bool {
    isUID(value)
  }

  static func isUID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
  }

  static func isResourceVersion(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    return bytes.allSatisfy { (33...126).contains($0) }
  }

  private static func isDNSLabel(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard
      !bytes.isEmpty,
      bytes.count <= 63,
      let first = bytes.first,
      let last = bytes.last,
      isLowercaseAlphanumeric(first),
      isLowercaseAlphanumeric(last)
    else {
      return false
    }
    return bytes.allSatisfy {
      isLowercaseAlphanumeric($0) || $0 == 45
    }
  }

  private static func isLowercaseAlphanumeric(_ byte: UInt8) -> Bool {
    (97...122).contains(byte) || (48...57).contains(byte)
  }
}
