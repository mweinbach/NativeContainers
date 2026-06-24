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

  @Test
  func exactExistingUpUsesNativeConvergenceActions() {
    let desired = desiredWebState(replicaCount: 1)
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web"
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.converge])
    #expect(plan.containerActions.first?.expectedIdentity?.id == "web-1")
    #expect(plan.executionStepTokens == ["container-0001"])
  }

  @Test
  func existingUpPlansReplacementWhenReviewedAttachmentsDoNotMatchInventory() {
    let base = desiredWebState(replicaCount: 1)
    let desired = ComposeDesiredState(
      projectName: base.projectName,
      declaredServiceNames: base.declaredServiceNames,
      serviceDependencies: base.serviceDependencies,
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "example/web:latest",
          replicaCount: 1,
          profiles: [],
          dependencyNames: [],
          configurationHash: String(repeating: "a", count: 64),
          volumeNames: ["data"],
          networkNames: ["default"],
          publishedPortCount: 0
        )
      ],
      volumes: [
        ComposeDesiredResource(
          kind: .volume,
          logicalName: "data",
          runtimeName: "demo_data",
          isExternal: false,
          isActive: true
        )
      ],
      networks: [
        ComposeDesiredResource(
          kind: .network,
          logicalName: "default",
          runtimeName: "demo_default",
          isExternal: false,
          isActive: true
        )
      ]
    )
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web"
    )
    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        volumes: [volume(name: "demo_data", logicalName: "data", consumers: [])],
        networks: [
          network(name: "demo_default", logicalName: "default", consumers: [])
        ],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.replace])
    #expect(plan.containerActions.first?.expectedIdentity?.id == "web-1")
    #expect(plan.executionStepTokens == ["compose-up-0001"])
  }

  @Test
  func upstreamBridgeProfileBlocksReplacementWithoutPlanningDestructiveMutation() {
    let desired = desiredWebState(
      replicaCount: 1,
      inputSeal: String(repeating: "e", count: 64)
    )
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web",
      inputSeal: String(repeating: "f", count: 64)
    )

    let plan = ComposeLifecyclePlanner(
      allowsNativeContainersForkRecreation: false
    ).plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(!plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.converge])
    #expect(plan.blockers.contains { $0.message.contains("input seal") })
  }

  @Test
  func createMissingUpIsExecutableForAContiguousReviewedPrefix() {
    let desired = desiredWebState(replicaCount: 2)
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web"
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.containerActions.map(\.operation) == [.converge, .create])
    #expect(plan.executionStepTokens == ["container-0001", "compose-up-0001"])
    #expect(plan.canExecute)
  }

  @Test
  func inputSealedServiceCanCreateAMissingReplicaFromAReviewedPrefix() {
    let seal = String(repeating: "e", count: 64)
    let desired = desiredWebState(replicaCount: 2, inputSeal: seal)
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web",
      inputSeal: seal
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.converge, .create])
  }

  @Test
  func changedInputSealPlansExactReplacement() {
    let desired = desiredWebState(
      replicaCount: 1,
      inputSeal: String(repeating: "e", count: 64)
    )
    let existing = container(
      id: "web-1",
      service: "web",
      state: .stopped,
      imageDigest: "sha256:web",
      inputSeal: String(repeating: "f", count: 64)
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.replace])
    #expect(plan.containerActions.first?.expectedIdentity?.id == "web-1")
  }

  @Test
  func createMissingUpRepairsANoncontiguousReplicaSet() {
    let desired = desiredWebState(replicaCount: 2)
    let existing = container(
      id: "web-2",
      service: "web",
      replica: 2,
      state: .stopped,
      imageDigest: "sha256:web"
    )

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [existing],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.converge, .create])
    #expect(plan.containerActions.map(\.replicaNumber) == [2, 1])
  }

  @Test
  func upPlansExactHighestReplicaScaleDown() {
    let desired = desiredWebState(replicaCount: 1)
    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      inventory: makeInventory(
        containers: [
          container(
            id: "web-1",
            service: "web",
            replica: 1,
            state: .running,
            imageDigest: "sha256:web"
          ),
          container(
            id: "web-2",
            service: "web",
            replica: 2,
            state: .running,
            imageDigest: "sha256:web"
          ),
        ],
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.converge, .scaleDown])
    #expect(plan.containerActions.last?.expectedIdentity?.id == "web-2")
    #expect(plan.executionStepTokens == ["container-0001", "compose-up-0001"])
  }

  @Test
  func downSeparatesDeclaredOrphanNetworkAndVolumeDeletionActions() {
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
      containers: [
        container(id: "web-1", service: "web"),
        container(id: "legacy-1", service: "legacy"),
      ],
      volumes: [
        volume(
          name: "demo_data",
          logicalName: "data",
          consumers: ["web-1", "legacy-1"]
        )
      ],
      networks: [
        network(
          name: "demo_default",
          logicalName: "default",
          consumers: ["web-1", "legacy-1"]
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
        removeOrphans: true,
        removeVolumes: true
      ),
      inventory: inventory
    )

    #expect(plan.canExecute)
    #expect(plan.containerActions.map(\.operation) == [.removeDeclared, .removeOrphan])
    #expect(plan.orphanContainerIDs == ["legacy-1"])
    #expect(plan.networkActions.map(\.operation) == [.removeManaged])
    #expect(plan.volumeActions.map(\.operation) == [.removeManaged])
    #expect(
      plan.executionStepTokens
        == ["container-0001", "container-0002", "network-0001", "volume-0001"]
    )
  }

  @Test
  func duplicateReplicaLabelsBlockExactLifecycleExecution() {
    let desired = desiredWebState(replicaCount: 2)
    let containers = [
      container(
        id: "web-a",
        service: "web",
        replica: 1,
        state: .stopped,
        imageDigest: "sha256:web"
      ),
      container(
        id: "web-b",
        service: "web",
        replica: 1,
        state: .stopped,
        imageDigest: "sha256:web"
      ),
    ]

    let plan = planner.plan(
      source: sourceSummary,
      rendered: rendered,
      review: ComposeDesiredStateReview(desiredState: desired, issues: []),
      options: ComposeProjectReviewOptions(action: .start, projectName: "demo"),
      inventory: makeInventory(
        containers: containers,
        images: [image(reference: "example/web:latest", digest: "sha256:web")]
      )
    )

    #expect(
      plan.blockers.contains {
        $0.code == .observedProjectDrift && $0.subject == "web"
      }
    )
    #expect(!plan.canExecute)
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

  private func desiredWebState(
    replicaCount: Int,
    inputSeal: String? = nil
  ) -> ComposeDesiredState {
    ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web"],
      serviceDependencies: ["web": []],
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "example/web:latest",
          replicaCount: replicaCount,
          profiles: [],
          dependencyNames: [],
          configurationHash: String(repeating: "a", count: 64),
          inputSeal: inputSeal,
          volumeNames: [],
          networkNames: [],
          publishedPortCount: 0
        )
      ],
      volumes: [],
      networks: []
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
    replica: Int? = 1,
    oneOff: Bool = false,
    state: RuntimeState = .running,
    imageDigest: String? = nil,
    inputSeal: String? = nil
  ) -> ContainerRecord {
    var labels = [
      ComposeLabelKey.project: "demo",
      ComposeLabelKey.service: service,
      ComposeLabelKey.oneOff: oneOff ? "True" : "False",
      ComposeLabelKey.configHash: String(repeating: "a", count: 64),
    ]
    if let replica {
      labels[ComposeLabelKey.containerNumber] = String(replica)
    }
    if let inputSeal {
      labels[ComposeLabelKey.inputSeal] = inputSeal
      labels[ComposeLabelKey.reviewedConfigHash] = String(repeating: "a", count: 64)
    }
    return ContainerRecord(
      id: id,
      imageReference: "example/\(service):latest",
      imageDigest: imageDigest,
      platform: "linux/arm64",
      state: state,
      ipAddress: nil,
      createdAt: Date(timeIntervalSince1970: 1),
      startedAt: Date(timeIntervalSince1970: 2),
      cpuCount: 2,
      memoryBytes: 1_024,
      ports: [],
      labels: labels
    )
  }

  private func image(reference: String, digest: String) -> ImageRecord {
    ImageRecord(
      reference: reference,
      digest: digest,
      mediaType: "application/test",
      indexSizeBytes: 1
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
