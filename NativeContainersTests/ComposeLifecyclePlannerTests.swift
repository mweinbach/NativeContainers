import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose lifecycle planner")
struct ComposeLifecyclePlannerTests {
  private let planner = ComposeLifecyclePlanner()

  @Test
  func fullDeclarationBoundaryPreventsInactiveServiceFromBecomingOrphan() {
    let desired = ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web", "worker"],
      serviceDependencies: [:],
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "nginx:1.27",
          replicaCount: 1,
          profiles: [],
          dependencyNames: [],
          configurationHash: String(repeating: "a", count: 64),
          volumeNames: [],
          networkNames: [],
          publishedPortCount: 0
        )
      ],
      volumes: [],
      networks: []
    )
    let inventory = makeInventory(containers: [
      container(id: "web-1", service: "web"),
      container(id: "worker-1", service: "worker"),
      container(id: "legacy-1", service: "legacy"),
      container(id: "task-1", service: "task", oneOff: true),
    ])

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .start, projectName: "demo"),
      inventory: inventory
    )

    #expect(plan.affectedContainerIDs == ["web-1"])
    #expect(plan.orphanContainerIDs == ["legacy-1"])
    #expect(plan.preservedResourceNames == ["legacy-1", "task-1", "worker-1"])
    #expect(plan.issues.contains { $0.code == .executionPolicy })
  }

  @Test
  func externalResourcesAreLookupOnlyAndMissingActiveResourceBlocksUp() {
    let desired = ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web"],
      serviceDependencies: [:],
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "nginx:1.27",
          replicaCount: 1,
          profiles: [],
          dependencyNames: [],
          configurationHash: String(repeating: "a", count: 64),
          volumeNames: ["shared"],
          networkNames: ["edge"],
          publishedPortCount: 0
        )
      ],
      volumes: [
        ComposeDesiredResource(
          kind: .volume,
          logicalName: "shared",
          runtimeName: "shared-data",
          isExternal: true,
          isActive: true
        )
      ],
      networks: [
        ComposeDesiredResource(
          kind: .network,
          logicalName: "edge",
          runtimeName: "edge-network",
          isExternal: true,
          isActive: true
        )
      ]
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory()
    )

    #expect(
      plan.blockers.count(where: { $0.code == .externalResourceMissing }) == 2
    )
    #expect(plan.affectedVolumeNames.isEmpty)
    #expect(plan.affectedNetworkNames.isEmpty)
    #expect(plan.preservedResourceNames == ["edge-network", "shared-data"])
  }

  @Test
  func downBlocksManagedResourceDeletionWithUnreviewedConsumer() {
    let desired = ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web"],
      serviceDependencies: [:],
      activeServices: [],
      volumes: [
        ComposeDesiredResource(
          kind: .volume,
          logicalName: "data",
          runtimeName: "demo_data",
          isExternal: false,
          isActive: false
        )
      ],
      networks: [
        ComposeDesiredResource(
          kind: .network,
          logicalName: "default",
          runtimeName: "demo_default",
          isExternal: false,
          isActive: false
        )
      ]
    )
    let inventory = makeInventory(
      containers: [container(id: "web-1", service: "web")],
      volumes: [
        volume(
          name: "demo_data",
          logicalName: "data",
          consumers: ["web-1", "foreign-1"]
        )
      ],
      networks: [
        network(
          name: "demo_default",
          logicalName: "default",
          consumers: ["web-1"]
        )
      ]
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(
        action: .down,
        projectName: "demo",
        removeVolumes: true
      ),
      inventory: inventory
    )

    #expect(plan.affectedContainerIDs == ["web-1"])
    #expect(plan.affectedVolumeNames == ["demo_data"])
    #expect(plan.affectedNetworkNames == ["demo_default"])
    #expect(
      plan.blockers.contains {
        $0.code == .crossProjectConsumer && $0.subject == "demo_data"
      }
    )
  }

  private var sourceSummary: ComposeProjectSourceSummary {
    ComposeProjectSourceSummary(
      directoryName: "demo",
      fileName: "compose.yaml",
      fileIdentity: ComposeProjectSourceFileIdentity(
        device: 1,
        inode: 2,
        owner: 501,
        permissions: 0o600,
        byteCount: 12,
        modificationSeconds: 1,
        modificationNanoseconds: 0,
        changeSeconds: 1,
        changeNanoseconds: 0,
        sha256: String(repeating: "a", count: 64)
      )
    )
  }

  private var rendered: ComposeRenderedConfiguration {
    ComposeRenderedConfiguration(
      fullConfiguration: Data("{}".utf8),
      activeConfiguration: Data("{}".utf8),
      fullConfigurationSHA256: String(repeating: "a", count: 64),
      activeConfigurationSHA256: String(repeating: "b", count: 64),
      composeReleaseVersion: "5.1.4",
      composeBinarySHA256: String(repeating: "c", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: String(repeating: "d", count: 64),
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)]
    )
  }

  private func makeInventory(
    containers: [ContainerRecord] = [],
    volumes: [VolumeRecord] = [],
    networks: [NetworkRecord] = [],
    images: [ImageRecord] = []
  ) -> ContainerInventory {
    ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "test",
        commit: "test",
        applicationRoot: URL(filePath: "/tmp/app"),
        installRoot: URL(filePath: "/tmp/install")
      ),
      containers: containers,
      images: images,
      volumes: volumes,
      networks: networks,
      machines: []
    )
  }

  private func container(
    id: String,
    service: String,
    oneOff: Bool = false
  ) -> ContainerRecord {
    ContainerRecord(
      id: id,
      imageReference: "example/\(service):latest",
      platform: "linux/arm64",
      state: .running,
      ipAddress: nil,
      createdAt: Date(timeIntervalSince1970: 1),
      startedAt: Date(timeIntervalSince1970: 2),
      cpuCount: 2,
      memoryBytes: 1_024,
      ports: [],
      labels: [
        ComposeLabelKey.project: "demo",
        ComposeLabelKey.service: service,
        ComposeLabelKey.containerNumber: "1",
        ComposeLabelKey.oneOff: oneOff ? "True" : "False",
        ComposeLabelKey.configHash: String(repeating: "a", count: 64),
      ]
    )
  }

  private func volume(
    name: String,
    logicalName: String,
    consumers: [String]
  ) -> VolumeRecord {
    VolumeRecord(
      id: "volume-\(name)",
      name: name,
      driver: "local",
      format: "ext4",
      source: "/tmp/\(name).img",
      createdAt: Date(timeIntervalSince1970: 1),
      sizeBytes: nil,
      allocatedBytes: nil,
      labels: [
        ComposeLabelKey.project: "demo",
        ComposeLabelKey.volume: logicalName,
      ],
      options: [:],
      isAnonymous: false,
      usedByContainerIDs: consumers
    )
  }

  private func network(
    name: String,
    logicalName: String,
    consumers: [String]
  ) -> NetworkRecord {
    NetworkRecord(
      id: name,
      name: name,
      mode: .nat,
      createdAt: Date(timeIntervalSince1970: 1),
      configuredIPv4Subnet: nil,
      configuredIPv6Subnet: nil,
      assignedIPv4Subnet: "192.168.64.0/24",
      ipv4Gateway: "192.168.64.1",
      assignedIPv6Subnet: nil,
      labels: [
        ComposeLabelKey.project: "demo",
        ComposeLabelKey.network: logicalName,
      ],
      plugin: "container-network-vmnet",
      options: [:],
      isBuiltin: false,
      usedByContainerIDs: consumers
    )
  }
}
