import Foundation

struct KubernetesResourceInventoryParser: Sendable {
  static let workloadsMarker = "__NATIVECONTAINERS_K8S_WORKLOADS__"
  static let podsMarker = "__NATIVECONTAINERS_K8S_PODS__"
  static let servicesMarker = "__NATIVECONTAINERS_K8S_SERVICES__"
  static let maximumItemsPerSection = 500

  static let inventoryCommand = """
    set -eu
    command -v jq >/dev/null

    printf '%s\n' '\(workloadsMarker)'
    /usr/local/bin/k3s kubectl get deployments.apps,statefulsets.apps,daemonsets.apps,jobs.batch --all-namespaces --chunk-size=\(maximumItemsPerSection) --output=json |
      jq --compact-output '{
        items: [
          .items[] |
          {
            kind: .kind,
            metadata: {
              namespace: .metadata.namespace,
              name: .metadata.name
            },
            spec: {
              replicas: .spec.replicas,
              completions: .spec.completions,
              parallelism: .spec.parallelism
            },
            status: {
              replicas: .status.replicas,
              readyReplicas: .status.readyReplicas,
              availableReplicas: .status.availableReplicas,
              desiredNumberScheduled: .status.desiredNumberScheduled,
              numberReady: .status.numberReady,
              numberAvailable: .status.numberAvailable,
              succeeded: .status.succeeded,
              active: .status.active,
              failed: .status.failed
            }
          }
        ]
      }'

    printf '%s\n' '\(podsMarker)'
    /usr/local/bin/k3s kubectl get pods --all-namespaces --chunk-size=\(maximumItemsPerSection) --output=json |
      jq --compact-output '{
        items: [
          .items[] |
          {
            metadata: {
              namespace: .metadata.namespace,
              name: .metadata.name
            },
            spec: {
              nodeName: .spec.nodeName,
              containers: [
                (.spec.containers // [])[] | {}
              ]
            },
            status: {
              phase: .status.phase,
              containerStatuses: [
                (.status.containerStatuses // [])[] |
                {
                  ready: (.ready // false),
                  restartCount: (.restartCount // 0)
                }
              ]
            }
          }
        ]
      }'

    printf '%s\n' '\(servicesMarker)'
    /usr/local/bin/k3s kubectl get services --all-namespaces --chunk-size=\(maximumItemsPerSection) --output=json |
      jq --compact-output '{
        items: [
          .items[] |
          {
            metadata: {
              namespace: .metadata.namespace,
              name: .metadata.name
            },
            spec: {
              type: .spec.type,
              clusterIP: .spec.clusterIP,
              ports: [
                (.spec.ports // [])[] |
                {
                  name: .name,
                  protocol: .protocol,
                  port: .port,
                  targetPort: .targetPort,
                  nodePort: .nodePort
                }
              ]
            }
          }
        ]
      }'
    """

  func parse(
    _ output: String,
    capturedAt: Date
  ) throws -> KubernetesResourceInventory {
    do {
      let sections = try split(output)
      let workloadList: APIList<WorkloadItem> = try decode(
        sections[.workloads]
      )
      let podList: APIList<PodItem> = try decode(sections[.pods])
      let serviceList: APIList<ServiceItem> = try decode(
        sections[.services]
      )

      try enforceLimit(workloadList.items)
      try enforceLimit(podList.items)
      try enforceLimit(serviceList.items)

      let workloads = try workloadList.items.map(parseWorkload).sorted(
        by: Self.workloadSort
      )
      let pods = try podList.items.map(parsePod).sorted(by: Self.podSort)
      let services = try serviceList.items.map(parseService).sorted(
        by: Self.serviceSort
      )

      try requireUniqueIDs(workloads)
      try requireUniqueIDs(pods)
      try requireUniqueIDs(services)

      return KubernetesResourceInventory(
        workloads: workloads,
        pods: pods,
        services: services,
        capturedAt: capturedAt
      )
    } catch let error as KubernetesClusterError {
      throw error
    } catch {
      throw KubernetesClusterError.invalidResourceInventory
    }
  }

  private enum Section: CaseIterable, Hashable {
    case workloads
    case pods
    case services

    var marker: String {
      switch self {
      case .workloads:
        KubernetesResourceInventoryParser.workloadsMarker
      case .pods:
        KubernetesResourceInventoryParser.podsMarker
      case .services:
        KubernetesResourceInventoryParser.servicesMarker
      }
    }
  }

  private func split(_ output: String) throws -> [Section: String] {
    var currentSection: Section?
    var seenSections = Set<Section>()
    var linesBySection: [Section: [String]] = [:]

    for rawLine in output.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if let section = Section.allCases.first(where: { $0.marker == trimmed }) {
        guard seenSections.insert(section).inserted else {
          throw KubernetesClusterError.invalidResourceInventory
        }
        currentSection = section
      } else if let currentSection {
        linesBySection[currentSection, default: []].append(line)
      }
    }

    guard seenSections.count == Section.allCases.count else {
      throw KubernetesClusterError.invalidResourceInventory
    }

    var sections: [Section: String] = [:]
    for section in Section.allCases {
      let json = linesBySection[section, default: []]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !json.isEmpty else {
        throw KubernetesClusterError.invalidResourceInventory
      }
      sections[section] = json
    }
    return sections
  }

  private func decode<Value: Decodable>(_ json: String?) throws -> Value {
    guard let json, let data = json.data(using: .utf8) else {
      throw KubernetesClusterError.invalidResourceInventory
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func enforceLimit<Value>(_ items: [Value]) throws {
    guard items.count <= Self.maximumItemsPerSection else {
      throw KubernetesClusterError.resourceInventoryTooLarge
    }
  }

  private func parseWorkload(
    _ item: WorkloadItem
  ) throws -> KubernetesWorkloadRecord {
    let namespace = try validatedName(item.metadata.namespace, maximumLength: 63)
    let name = try validatedName(item.metadata.name)
    let kind: KubernetesWorkloadKind
    let desiredCount: Int
    let readyCount: Int
    let availableCount: Int
    let failedCount: Int

    switch item.kind {
    case "Deployment":
      kind = .deployment
      desiredCount = try validatedCount(item.spec?.replicas ?? item.status?.replicas ?? 0)
      readyCount = try validatedCount(item.status?.readyReplicas ?? 0)
      availableCount = try validatedCount(item.status?.availableReplicas ?? 0)
      failedCount = 0
    case "StatefulSet":
      kind = .statefulSet
      desiredCount = try validatedCount(item.spec?.replicas ?? item.status?.replicas ?? 0)
      readyCount = try validatedCount(item.status?.readyReplicas ?? 0)
      availableCount = try validatedCount(item.status?.availableReplicas ?? 0)
      failedCount = 0
    case "DaemonSet":
      kind = .daemonSet
      desiredCount = try validatedCount(item.status?.desiredNumberScheduled ?? 0)
      readyCount = try validatedCount(item.status?.numberReady ?? 0)
      availableCount = try validatedCount(item.status?.numberAvailable ?? 0)
      failedCount = 0
    case "Job":
      kind = .job
      desiredCount = try validatedCount(
        item.spec?.completions ?? item.spec?.parallelism ?? 1
      )
      readyCount = try validatedCount(item.status?.succeeded ?? 0)
      availableCount = try validatedCount(item.status?.active ?? 0)
      failedCount = try validatedCount(item.status?.failed ?? 0)
    default:
      throw KubernetesClusterError.invalidResourceInventory
    }

    return KubernetesWorkloadRecord(
      namespace: namespace,
      name: name,
      kind: kind,
      desiredCount: desiredCount,
      readyCount: readyCount,
      availableCount: availableCount,
      failedCount: failedCount
    )
  }

  private func parsePod(_ item: PodItem) throws -> KubernetesPodRecord {
    let namespace = try validatedName(item.metadata.namespace, maximumLength: 63)
    let name = try validatedName(item.metadata.name)
    let containerCount = item.spec?.containers?.count ?? 0
    guard containerCount <= 256 else {
      throw KubernetesClusterError.invalidResourceInventory
    }

    let statuses = item.status?.containerStatuses ?? []
    let readyContainerCount = statuses.filter(\.ready).count
    guard readyContainerCount <= containerCount else {
      throw KubernetesClusterError.invalidResourceInventory
    }

    var restartCount = 0
    for status in statuses {
      let count = try validatedCount(status.restartCount)
      let addition = restartCount.addingReportingOverflow(count)
      guard !addition.overflow else {
        throw KubernetesClusterError.invalidResourceInventory
      }
      restartCount = addition.partialValue
    }

    let phase: KubernetesPodPhase
    switch item.status?.phase {
    case "Pending":
      phase = .pending
    case "Running":
      phase = .running
    case "Succeeded":
      phase = .succeeded
    case "Failed":
      phase = .failed
    default:
      phase = .unknown
    }

    return KubernetesPodRecord(
      namespace: namespace,
      name: name,
      phase: phase,
      readyContainerCount: readyContainerCount,
      containerCount: containerCount,
      restartCount: restartCount,
      nodeName: try validatedOptionalText(
        item.spec?.nodeName,
        maximumLength: 253
      )
    )
  }

  private func parseService(
    _ item: ServiceItem
  ) throws -> KubernetesServiceRecord {
    let namespace = try validatedName(item.metadata.namespace, maximumLength: 63)
    let name = try validatedName(item.metadata.name)
    let serviceType = try validatedText(
      item.spec?.type ?? "ClusterIP",
      maximumLength: 64
    )
    let rawPorts = item.spec?.ports ?? []
    guard rawPorts.count <= 128 else {
      throw KubernetesClusterError.invalidResourceInventory
    }

    let ports = try rawPorts.map { port -> KubernetesServicePortRecord in
      guard (1...65_535).contains(port.port) else {
        throw KubernetesClusterError.invalidResourceInventory
      }
      if let nodePort = port.nodePort,
        !(1...65_535).contains(nodePort)
      {
        throw KubernetesClusterError.invalidResourceInventory
      }

      let targetPort: String
      switch port.targetPort {
      case .integer(let value):
        guard (1...65_535).contains(value) else {
          throw KubernetesClusterError.invalidResourceInventory
        }
        targetPort = String(value)
      case .string(let value):
        targetPort = try validatedText(value, maximumLength: 63)
      case nil:
        targetPort = String(port.port)
      }

      return KubernetesServicePortRecord(
        name: try validatedOptionalText(port.name, maximumLength: 63),
        protocolName: try validatedText(
          port.protocolName ?? "TCP",
          maximumLength: 16
        ),
        port: port.port,
        targetPort: targetPort,
        nodePort: port.nodePort
      )
    }
    try requireUniqueIDs(ports)

    return KubernetesServiceRecord(
      namespace: namespace,
      name: name,
      type: serviceType,
      clusterIP: try validatedOptionalText(
        item.spec?.clusterIP,
        maximumLength: 64
      ),
      ports: ports
    )
  }

  private func validatedName(
    _ value: String?,
    maximumLength: Int = 253
  ) throws -> String {
    guard let value else {
      throw KubernetesClusterError.invalidResourceInventory
    }
    return try validatedText(value, maximumLength: maximumLength)
  }

  private func validatedOptionalText(
    _ value: String?,
    maximumLength: Int
  ) throws -> String? {
    guard let value else { return nil }
    return try validatedText(value, maximumLength: maximumLength)
  }

  private func validatedText(
    _ value: String,
    maximumLength: Int
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      value == trimmed,
      !value.isEmpty,
      value.utf8.count <= maximumLength,
      value.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw KubernetesClusterError.invalidResourceInventory
    }
    return value
  }

  private func validatedCount(_ value: Int) throws -> Int {
    guard value >= 0 else {
      throw KubernetesClusterError.invalidResourceInventory
    }
    return value
  }

  private func requireUniqueIDs<Value: Identifiable>(
    _ values: [Value]
  ) throws where Value.ID: Hashable {
    var identifiers = Set<Value.ID>()
    for value in values {
      guard identifiers.insert(value.id).inserted else {
        throw KubernetesClusterError.invalidResourceInventory
      }
    }
  }

  private static func workloadSort(
    _ lhs: KubernetesWorkloadRecord,
    _ rhs: KubernetesWorkloadRecord
  ) -> Bool {
    (lhs.namespace, lhs.kind.rawValue, lhs.name)
      < (rhs.namespace, rhs.kind.rawValue, rhs.name)
  }

  private static func podSort(
    _ lhs: KubernetesPodRecord,
    _ rhs: KubernetesPodRecord
  ) -> Bool {
    (lhs.namespace, lhs.name) < (rhs.namespace, rhs.name)
  }

  private static func serviceSort(
    _ lhs: KubernetesServiceRecord,
    _ rhs: KubernetesServiceRecord
  ) -> Bool {
    (lhs.namespace, lhs.name) < (rhs.namespace, rhs.name)
  }
}

private struct APIList<Item: Decodable>: Decodable {
  let items: [Item]
}

private struct ResourceMetadata: Decodable {
  let namespace: String?
  let name: String?
}

private struct WorkloadItem: Decodable {
  let kind: String
  let metadata: ResourceMetadata
  let spec: WorkloadSpec?
  let status: WorkloadStatus?
}

private struct WorkloadSpec: Decodable {
  let replicas: Int?
  let completions: Int?
  let parallelism: Int?
}

private struct WorkloadStatus: Decodable {
  let replicas: Int?
  let readyReplicas: Int?
  let availableReplicas: Int?
  let desiredNumberScheduled: Int?
  let numberReady: Int?
  let numberAvailable: Int?
  let succeeded: Int?
  let active: Int?
  let failed: Int?
}

private struct PodItem: Decodable {
  let metadata: ResourceMetadata
  let spec: PodSpec?
  let status: PodStatus?
}

private struct PodSpec: Decodable {
  let nodeName: String?
  let containers: [PodContainer]?
}

private struct PodContainer: Decodable {}

private struct PodStatus: Decodable {
  let phase: String?
  let containerStatuses: [PodContainerStatus]?
}

private struct PodContainerStatus: Decodable {
  let ready: Bool
  let restartCount: Int
}

private struct ServiceItem: Decodable {
  let metadata: ResourceMetadata
  let spec: ServiceSpec?
}

private struct ServiceSpec: Decodable {
  let type: String?
  let clusterIP: String?
  let ports: [ServicePort]?
}

private struct ServicePort: Decodable {
  let name: String?
  let protocolName: String?
  let port: Int
  let targetPort: KubernetesIntOrString?
  let nodePort: Int?

  private enum CodingKeys: String, CodingKey {
    case name
    case protocolName = "protocol"
    case port
    case targetPort
    case nodePort
  }
}

private enum KubernetesIntOrString: Decodable {
  case integer(Int)
  case string(String)

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }
}
