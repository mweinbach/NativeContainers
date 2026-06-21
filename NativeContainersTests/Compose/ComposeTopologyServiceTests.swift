import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose topology")
struct ComposeTopologyServiceTests {
  private let service = ComposeTopologyService()

  @Test
  func groupsCanonicalLabelsIntoServicesResourcesAndReverseIndexes() throws {
    let inventory = makeInventory(
      containers: [
        makeContainer(
          id: "web-2",
          project: "shop",
          service: "web",
          replicaNumber: "2",
          state: .running
        ),
        makeContainer(
          id: "migrate",
          project: "shop",
          service: "migrate",
          oneOff: "TRUE",
          state: .stopped
        ),
        makeContainer(
          id: "web-1",
          project: "shop",
          service: "web",
          replicaNumber: "1",
          state: .running,
          extraLabels: [
            ComposeLabelKey.workingDirectory: "/Users/example/shop",
            ComposeLabelKey.configFiles: "/Users/example/shop/compose.yaml",
            ComposeLabelKey.version: "2.38.1",
          ]
        ),
        makeContainer(id: "unclassified", project: "shop", state: .unknown),
      ],
      volumes: [
        makeVolume(
          id: "data-id",
          name: "my-app-data",
          project: "shop",
          logicalName: "db-data"
        )
      ],
      networks: [
        makeNetwork(
          id: "network-id",
          name: "my-app-network",
          project: "shop",
          logicalName: "default"
        )
      ]
    )

    let topology = service.derive(from: inventory)
    let project = try #require(topology.projects.first)

    #expect(topology.projects.map(\.name) == ["shop"])
    #expect(project.services.map(\.name) == ["migrate", "web"])
    #expect(project.services[1].instances.map(\.id) == ["web-1", "web-2"])
    #expect(project.services[0].instances.first?.isOneOff == true)
    #expect(project.unclassifiedContainers.map(\.id) == ["unclassified"])
    #expect(project.containerCount == 3)
    #expect(project.runningContainerCount == 2)
    #expect(project.oneOffContainerCount == 1)
    #expect(project.observedState == .partiallyRunning)
    #expect(project.volumes.map(\.id) == ["data-id"])
    #expect(project.networks.map(\.id) == ["network-id"])
    #expect(project.volumes.first?.logicalName == "db-data")
    #expect(project.volumes.first?.volume.name == "my-app-data")
    #expect(project.networks.first?.logicalName == "default")
    #expect(project.networks.first?.network.name == "my-app-network")
    #expect(project.metadata.workingDirectories == ["/Users/example/shop"])
    #expect(project.metadata.configFileValues == ["/Users/example/shop/compose.yaml"])
    #expect(project.metadata.composeVersions == ["2.38.1"])
    #expect(topology.projectNameByContainerID["web-1"] == "shop")
    #expect(topology.serviceNameByContainerID["web-1"] == "web")
    #expect(topology.projectNameByContainerID["unclassified"] == nil)
    #expect(topology.serviceNameByContainerID["unclassified"] == nil)
    #expect(topology.projectNameByVolumeID["data-id"] == "shop")
    #expect(topology.projectNameByNetworkID["network-id"] == "shop")
    #expect(topology.containerAssociationsByID["web-1"]?.serviceName == "web")
    #expect(topology.volumeAssociationsByID["data-id"]?.logicalName == "db-data")
    #expect(topology.networkAssociationsByID["network-id"]?.logicalName == "default")
    #expect(topology.project(containingContainerID: "migrate")?.name == "shop")
  }

  @Test
  func includesOnlyCanonicalProjectsAndReportsSuspectLabelEvidence() {
    let inventory = makeInventory(
      containers: [
        makeContainer(id: "missing-project"),
        makeContainer(id: "empty-project", project: ""),
        makeContainer(id: "service-only", service: "web"),
        makeContainer(id: "spaced-project", project: " Team ", service: " API "),
        makeContainer(id: "lowercase-project", project: "team", service: "api"),
        makeContainer(id: "invalid-service", project: "team", service: "bad service"),
      ],
      volumes: [
        makeVolume(
          id: "cache",
          name: "cache",
          project: "resources",
          extraLabels: [
            ComposeLabelKey.workingDirectory: "/untrusted-volume-path",
            ComposeLabelKey.version: "5.1.4",
          ]
        ),
        makeVolume(
          id: "anonymous-volume",
          name: "anonymous",
          project: "resources",
          isAnonymous: true
        ),
        makeVolume(
          id: "invalid-volume",
          name: "bad volume",
          project: "resources"
        ),
        makeVolume(
          id: "project-only-volume",
          name: "orphan",
          project: "resources",
          includeResourceLabel: false
        ),
      ],
      networks: [
        makeNetwork(
          id: "edge",
          name: "edge",
          project: "resources",
          extraLabels: [ComposeLabelKey.configFiles: "/untrusted-network-file"]
        ),
        makeNetwork(
          id: "builtin-network",
          name: "default",
          project: "resources",
          isBuiltin: true
        ),
        makeNetwork(
          id: "invalid-network",
          name: "bad network",
          project: "resources"
        ),
        makeNetwork(
          id: "project-only-network",
          name: "orphan",
          project: "resources",
          includeResourceLabel: false
        ),
      ]
    )

    let topology = service.derive(from: inventory)

    #expect(topology.projects.map(\.name) == ["resources", "team"])
    #expect(topology.project(named: "resources")?.observedState == .noContainers)
    #expect(topology.project(named: "resources")?.volumes.map(\.id) == ["cache"])
    #expect(topology.project(named: "resources")?.networks.map(\.id) == ["edge"])
    #expect(topology.project(named: "resources")?.metadata.workingDirectories.isEmpty == true)
    #expect(topology.project(named: "resources")?.metadata.configFileValues.isEmpty == true)
    #expect(topology.project(named: "resources")?.metadata.composeVersions == ["5.1.4"])
    #expect(topology.projectNameByContainerID["missing-project"] == nil)
    #expect(topology.projectNameByContainerID["empty-project"] == nil)
    #expect(topology.projectNameByContainerID["service-only"] == nil)
    #expect(topology.projectNameByContainerID["spaced-project"] == nil)
    #expect(
      topology.project(named: "team")?.unclassifiedContainers.map(\.id) == ["invalid-service"])
    #expect(topology.notices.count == 9)
    #expect(
      topology.notices.contains {
        $0.kind == .invalidProjectName && $0.resourceID == "empty-project"
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .invalidProjectName && $0.resourceID == "spaced-project"
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .anonymousVolume && $0.resourceID == "anonymous-volume"
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .invalidLogicalName
          && $0.resourceID == "invalid-service"
          && $0.expectedLabelKey == ComposeLabelKey.service
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .invalidLogicalName
          && $0.resourceID == "invalid-volume"
          && $0.expectedLabelKey == ComposeLabelKey.volume
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .missingResourceLabel
          && $0.resourceID == "project-only-volume"
          && $0.expectedLabelKey == ComposeLabelKey.volume
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .builtinNetwork && $0.resourceID == "builtin-network"
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .invalidLogicalName
          && $0.resourceID == "invalid-network"
          && $0.expectedLabelKey == ComposeLabelKey.network
      }
    )
    #expect(
      topology.notices.contains {
        $0.kind == .missingResourceLabel
          && $0.resourceID == "project-only-network"
          && $0.expectedLabelKey == ComposeLabelKey.network
      }
    )
  }

  @Test
  func preservesInvalidOptionalContainerLabelsAsEvidence() throws {
    let topology = service.derive(
      from: makeInventory(containers: [
        makeContainer(
          id: "web-1",
          project: "app",
          service: "web",
          replicaNumber: "0",
          oneOff: "sometimes",
          state: .running
        )
      ])
    )
    let instance = try #require(topology.projects.first?.services.first?.instances.first)
    let association = try #require(topology.containerAssociationsByID["web-1"])

    #expect(instance.replicaNumberLabel == .invalid(rawValue: "0"))
    #expect(instance.oneOffLabel == .invalid(rawValue: "sometimes"))
    #expect(instance.replicaNumber == nil)
    #expect(!instance.isOneOff)
    #expect(association.replicaNumber == .invalid(rawValue: "0"))
    #expect(association.oneOff == .invalid(rawValue: "sometimes"))
    #expect(
      topology.notices.filter { $0.kind == .invalidOptionalLabel }.map(\.expectedLabelKey)
        == [ComposeLabelKey.containerNumber, ComposeLabelKey.oneOff]
    )
  }

  @Test
  func presentEmptyLogicalNamesRemainInvalidEvidenceRatherThanMissing() {
    let topology = service.derive(
      from: makeInventory(
        containers: [makeContainer(id: "container", project: "app", service: "")],
        volumes: [
          makeVolume(id: "volume", name: "runtime-volume", project: "app", logicalName: "")
        ],
        networks: [
          makeNetwork(id: "network", name: "runtime-network", project: "app", logicalName: "")
        ]
      )
    )

    #expect(topology.projects.isEmpty)
    #expect(topology.notices.count == 3)
    #expect(topology.notices.allSatisfy { $0.kind == .invalidLogicalName })
    #expect(topology.notices.allSatisfy { $0.observedValue == "" })
  }

  @Test
  func validatesProjectNamesWithoutTrimmingOrNormalizing() {
    let invalidNames = ["", " Team ", "UPPER", "-leading", "_leading", "équipe"]
    let invalidContainers = invalidNames.enumerated().map { index, project in
      makeContainer(id: "invalid-\(index)", project: project, service: "web")
    }
    let topology = service.derive(
      from: makeInventory(
        containers: invalidContainers + [
          makeContainer(id: "digit", project: "1app", service: "web"),
          makeContainer(id: "punctuation", project: "app-one_two", service: "web"),
        ]
      )
    )

    #expect(topology.projects.map(\.name) == ["1app", "app-one_two"])
    #expect(topology.notices.filter { $0.kind == .invalidProjectName }.count == 6)
  }

  @Test
  func reportsCrossProjectConsumersWithoutReassigningResources() {
    let topology = service.derive(
      from: makeInventory(
        containers: [
          makeContainer(id: "a-web", project: "a", service: "web"),
          makeContainer(id: "b-web", project: "b", service: "web"),
        ],
        volumes: [
          makeVolume(
            id: "a-volume",
            name: "a-volume-runtime",
            project: "a",
            logicalName: "data",
            usedByContainerIDs: ["b-web", "unknown"]
          )
        ],
        networks: [
          makeNetwork(
            id: "a-network",
            name: "a-network-runtime",
            project: "a",
            logicalName: "default",
            usedByContainerIDs: ["a-web", "b-web"]
          )
        ]
      )
    )

    #expect(topology.volumeAssociationsByID["a-volume"]?.projectName == "a")
    #expect(topology.networkAssociationsByID["a-network"]?.projectName == "a")
    #expect(
      topology.notices.filter { $0.kind == .consumerProjectMismatch }.map(\.resourceID)
        == ["a-volume", "a-network"]
    )
    #expect(
      topology.notices.filter { $0.kind == .consumerProjectMismatch }
        .allSatisfy { $0.relatedProjectNames == ["b"] }
    )
  }

  @Test
  func outputIsStableAcrossInputOrdering() {
    let containers = [
      makeContainer(id: "z-2", project: "z", service: "web", replicaNumber: "2"),
      makeContainer(id: "a-worker", project: "a", service: "worker"),
      makeContainer(id: "z-1", project: "z", service: "web", replicaNumber: "1"),
      makeContainer(id: "a-api", project: "a", service: "api"),
    ]
    let volumes = [
      makeVolume(id: "z-volume", name: "z", project: "z"),
      makeVolume(id: "a-volume", name: "a", project: "a"),
    ]
    let networks = [
      makeNetwork(id: "z-network", name: "z", project: "z"),
      makeNetwork(id: "a-network", name: "a", project: "a"),
    ]

    let forward = service.derive(
      from: makeInventory(containers: containers, volumes: volumes, networks: networks)
    )
    let reverse = service.derive(
      from: makeInventory(
        containers: containers.reversed(),
        volumes: volumes.reversed(),
        networks: networks.reversed()
      )
    )

    #expect(forward == reverse)
    #expect(forward.projects.map(\.name) == ["a", "z"])
    #expect(forward.project(named: "a")?.services.map(\.name) == ["api", "worker"])
    #expect(
      forward.project(named: "z")?.services.first?.instances.map(\.id) == ["z-1", "z-2"]
    )
  }

  @Test
  func reportsObjectiveObservedRuntimeStates() {
    let allRunning = service.derive(
      from: makeInventory(containers: [
        makeContainer(id: "one", project: "running", service: "web", state: .running),
        makeContainer(id: "two", project: "running", service: "web", state: .running),
      ])
    )
    let transitioning = service.derive(
      from: makeInventory(containers: [
        makeContainer(id: "one", project: "transitioning", service: "web", state: .stopping)
      ])
    )
    let stopped = service.derive(
      from: makeInventory(containers: [
        makeContainer(id: "one", project: "stopped", service: "web", state: .stopped)
      ])
    )
    let unknown = service.derive(
      from: makeInventory(containers: [
        makeContainer(id: "one", project: "unknown", service: "web", state: .unknown)
      ])
    )

    #expect(allRunning.projects.first?.observedState == .allRunning)
    #expect(transitioning.projects.first?.observedState == .transitioning)
    #expect(stopped.projects.first?.observedState == .noneRunning)
    #expect(unknown.projects.first?.observedState == .unknown)
  }
}

private func makeInventory(
  containers: some Sequence<ContainerRecord> = [],
  volumes: some Sequence<VolumeRecord> = [],
  networks: some Sequence<NetworkRecord> = []
) -> ContainerInventory {
  ContainerInventory(
    system: ContainerSystemInfo(
      version: "1.0.0",
      build: "test",
      commit: "test",
      applicationRoot: URL(filePath: "/tmp/container"),
      installRoot: URL(filePath: "/usr/local")
    ),
    containers: Array(containers),
    images: [],
    volumes: Array(volumes),
    networks: Array(networks),
    machines: []
  )
}

private func makeContainer(
  id: String,
  project: String? = nil,
  service: String? = nil,
  replicaNumber: String? = nil,
  oneOff: String? = nil,
  state: RuntimeState = .stopped,
  extraLabels: [String: String] = [:]
) -> ContainerRecord {
  var labels = extraLabels
  labels[ComposeLabelKey.project] = project
  labels[ComposeLabelKey.service] = service
  labels[ComposeLabelKey.containerNumber] = replicaNumber
  labels[ComposeLabelKey.oneOff] = oneOff

  return ContainerRecord(
    id: id,
    imageReference: "example/\(id):latest",
    platform: "linux/arm64",
    state: state,
    ipAddress: nil,
    createdAt: Date(timeIntervalSince1970: 0),
    startedAt: state.isRunning ? Date(timeIntervalSince1970: 1) : nil,
    cpuCount: 2,
    memoryBytes: 1_073_741_824,
    ports: [],
    labels: labels
  )
}

private func makeVolume(
  id: String,
  name: String,
  project: String,
  logicalName: String? = nil,
  includeResourceLabel: Bool = true,
  extraLabels: [String: String] = [:],
  isAnonymous: Bool = false,
  usedByContainerIDs: [String] = []
) -> VolumeRecord {
  var labels = extraLabels
  labels[ComposeLabelKey.project] = project
  if includeResourceLabel {
    labels[ComposeLabelKey.volume] = logicalName ?? name
  }
  return VolumeRecord(
    id: id,
    name: name,
    driver: "local",
    format: "ext4",
    source: "/tmp/\(name)",
    createdAt: Date(timeIntervalSince1970: 0),
    sizeBytes: nil,
    allocatedBytes: nil,
    labels: labels,
    options: [:],
    isAnonymous: isAnonymous,
    usedByContainerIDs: usedByContainerIDs
  )
}

private func makeNetwork(
  id: String,
  name: String,
  project: String,
  logicalName: String? = nil,
  includeResourceLabel: Bool = true,
  isBuiltin: Bool = false,
  extraLabels: [String: String] = [:],
  usedByContainerIDs: [String] = []
) -> NetworkRecord {
  var labels = extraLabels
  labels[ComposeLabelKey.project] = project
  if includeResourceLabel {
    labels[ComposeLabelKey.network] = logicalName ?? name
  }
  return NetworkRecord(
    id: id,
    name: name,
    mode: .nat,
    createdAt: Date(timeIntervalSince1970: 0),
    configuredIPv4Subnet: nil,
    configuredIPv6Subnet: nil,
    assignedIPv4Subnet: "192.168.64.0/24",
    ipv4Gateway: "192.168.64.1",
    assignedIPv6Subnet: nil,
    labels: labels,
    plugin: "container-network-vmnet",
    options: [:],
    isBuiltin: isBuiltin,
    usedByContainerIDs: usedByContainerIDs
  )
}
