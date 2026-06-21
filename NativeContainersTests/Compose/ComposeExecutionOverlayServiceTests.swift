import CryptoKit
import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose execution overlay")
struct ComposeExecutionOverlayServiceTests {
  @Test
  func convertsEveryReviewedResourceToAnExactExternalReference() throws {
    let canonical = canonicalConfiguration()
    let plan = overlayPlan(canonicalConfiguration: canonical)
    let result = try ComposeExecutionOverlayService().prepare(
      canonicalConfiguration: canonical,
      plan: plan
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: result.data) as? [String: Any]
    )
    let volumes = try #require(object["volumes"] as? [String: Any])
    let networks = try #require(object["networks"] as? [String: Any])
    let volume = try #require(volumes["data"] as? [String: Any])
    let network = try #require(networks["default"] as? [String: Any])

    #expect(volume.count == 2)
    #expect(volume["external"] as? Bool == true)
    #expect(volume["name"] as? String == "demo_data")
    #expect(network.count == 2)
    #expect(network["external"] as? Bool == true)
    #expect(network["name"] as? String == "demo_default")
    #expect(result.sha256 == overlaySHA256(result.data))
  }

  @Test
  func rejectsAnActiveResourceWithoutItsFrozenExecutionAction() throws {
    let canonical = canonicalConfiguration()
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      includeNetworkAction: false
    )

    #expect(throws: ComposeProjectLifecycleError.observedStateChanged) {
      _ = try ComposeExecutionOverlayService().prepare(
        canonicalConfiguration: canonical,
        plan: plan
      )
    }
  }

  private func canonicalConfiguration() -> Data {
    Data(
      """
      {
        "name": "demo",
        "services": {
          "web": {
            "image": "nginx:1.27",
            "volumes": [{"type": "volume", "source": "data", "target": "/data"}],
            "networks": {"default": {}}
          }
        },
        "volumes": {"data": {"name": "demo_data", "driver": "local"}},
        "networks": {"default": {"name": "demo_default", "driver": "bridge"}}
      }
      """.utf8
    )
  }

  private func overlayPlan(
    canonicalConfiguration: Data,
    includeNetworkAction: Bool = true
  ) -> ComposeProjectPlan {
    let desired = ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web"],
      serviceDependencies: ["web": []],
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "nginx:1.27",
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
    return ComposeProjectPlan(
      id: UUID(),
      generatedAt: Date(timeIntervalSince1970: 1),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      source: ComposeProjectSourceSummary(
        directoryName: "demo",
        fileName: "compose.yaml",
        fileIdentity: ComposeProjectSourceFileIdentity(
          device: 1,
          inode: 2,
          owner: 501,
          permissions: 0o600,
          byteCount: Int64(canonicalConfiguration.count),
          modificationSeconds: 1,
          modificationNanoseconds: 0,
          changeSeconds: 1,
          changeNanoseconds: 0,
          sha256: overlaySHA256(canonicalConfiguration)
        )
      ),
      desiredState: desired,
      fullConfigurationSHA256: overlaySHA256(canonicalConfiguration),
      activeConfigurationSHA256: String(repeating: "b", count: 64),
      composeReleaseVersion: DockerComposeRelease.pinned.version,
      composeBinarySHA256: DockerComposeRelease.pinned.binarySHA256,
      composeSourceRevision: DockerComposeRelease.pinned.sourceRevision,
      environmentSHA256: String(repeating: "c", count: 64),
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)],
      observedIdentity: .empty,
      issues: [],
      containerActions: [
        ComposeProjectContainerAction(
          stepID: .container(1),
          operation: .create,
          serviceName: "web",
          replicaNumber: 1,
          expectedIdentity: nil
        )
      ],
      volumeActions: [
        ComposeProjectVolumeAction(
          stepID: .volume(1),
          operation: .createManaged,
          logicalName: "data",
          runtimeName: "demo_data",
          expectedIdentity: nil
        )
      ],
      networkActions: includeNetworkAction
        ? [
          ComposeProjectNetworkAction(
            stepID: .network(1),
            operation: .createManaged,
            logicalName: "default",
            runtimeName: "demo_default",
            expectedIdentity: nil
          )
        ] : [],
      orphanContainers: [],
      preservedResources: []
    )
  }
}

private func overlaySHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
