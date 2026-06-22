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
}

struct KubernetesWorkloadRecord: Identifiable, Equatable, Sendable {
  let namespace: String
  let name: String
  let kind: KubernetesWorkloadKind
  let desiredCount: Int
  let readyCount: Int
  let availableCount: Int
  let failedCount: Int

  var id: String {
    "\(namespace)/\(kind.rawValue)/\(name)"
  }

  init(
    namespace: String,
    name: String,
    kind: KubernetesWorkloadKind,
    desiredCount: Int,
    readyCount: Int,
    availableCount: Int,
    failedCount: Int
  ) {
    self.namespace = namespace
    self.name = name
    self.kind = kind
    self.desiredCount = max(0, desiredCount)
    self.readyCount = max(0, readyCount)
    self.availableCount = max(0, availableCount)
    self.failedCount = max(0, failedCount)
  }
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
  let namespace: String
  let name: String
  let phase: KubernetesPodPhase
  let readyContainerCount: Int
  let containerCount: Int
  let restartCount: Int
  let nodeName: String?

  var id: String {
    "\(namespace)/\(name)"
  }

  init(
    namespace: String,
    name: String,
    phase: KubernetesPodPhase,
    readyContainerCount: Int,
    containerCount: Int,
    restartCount: Int,
    nodeName: String?
  ) {
    self.namespace = namespace
    self.name = name
    self.phase = phase
    self.containerCount = max(0, containerCount)
    self.readyContainerCount = max(
      0,
      min(readyContainerCount, self.containerCount)
    )
    self.restartCount = max(0, restartCount)
    self.nodeName = nodeName
  }
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
