import Foundation
import Testing

@testable import NativeContainers

struct KubernetesResourceInventoryParserTests {
  @Test
  func parsesSortedWorkloadsPodsAndServicesWithoutSecretFields() throws {
    let capturedAt = Date(timeIntervalSince1970: 1_700_001_000)
    let inventory = try KubernetesResourceInventoryParser().parse(
      inventoryOutput(
        workloads: """
          {
            "items": [
              {
                "kind": "Deployment",
                "metadata": {
                  "namespace": "default",
                  "name": "web",
                  "annotations": {
                    "ignored.example/token": "must-not-enter-the-model"
                  }
                },
                "spec": {"replicas": 3},
                "status": {
                  "replicas": 3,
                  "readyReplicas": 2,
                  "availableReplicas": 2
                }
              },
              {
                "kind": "Job",
                "metadata": {"namespace": "batch", "name": "migrate"},
                "spec": {"completions": 1},
                "status": {"succeeded": 1, "active": 0, "failed": 0}
              },
              {
                "kind": "DaemonSet",
                "metadata": {"namespace": "kube-system", "name": "ingress"},
                "status": {
                  "desiredNumberScheduled": 1,
                  "numberReady": 1,
                  "numberAvailable": 1
                }
              }
            ]
          }
          """,
        pods: """
          {
            "items": [
              {
                "metadata": {"namespace": "kube-system", "name": "coredns"},
                "spec": {
                  "nodeName": "nativecontainers-kubernetes",
                  "containers": [{"name": "coredns"}]
                },
                "status": {
                  "phase": "Running",
                  "containerStatuses": [{"ready": true, "restartCount": 1}]
                }
              },
              {
                "metadata": {"namespace": "default", "name": "web-abc"},
                "spec": {
                  "nodeName": "nativecontainers-kubernetes",
                  "containers": [{"name": "web"}, {"name": "sidecar"}]
                },
                "status": {
                  "phase": "Pending",
                  "containerStatuses": [
                    {"ready": true, "restartCount": 0},
                    {"ready": false, "restartCount": 2}
                  ]
                }
              }
            ]
          }
          """,
        services: """
          {
            "items": [
              {
                "metadata": {"namespace": "kube-system", "name": "kube-dns"},
                "spec": {
                  "type": "ClusterIP",
                  "clusterIP": "10.43.0.10",
                  "ports": [
                    {
                      "name": "dns",
                      "protocol": "UDP",
                      "port": 53,
                      "targetPort": 53
                    }
                  ]
                }
              },
              {
                "metadata": {"namespace": "default", "name": "web"},
                "spec": {
                  "type": "NodePort",
                  "clusterIP": "10.43.2.20",
                  "ports": [
                    {
                      "name": "http",
                      "protocol": "TCP",
                      "port": 80,
                      "targetPort": "http",
                      "nodePort": 30080
                    }
                  ]
                }
              }
            ]
          }
          """
      ),
      capturedAt: capturedAt
    )

    #expect(inventory.capturedAt == capturedAt)
    #expect(
      inventory.workloads.map(\.id) == [
        "batch/job/migrate",
        "default/deployment/web",
        "kube-system/daemonSet/ingress",
      ]
    )
    #expect(inventory.workloads[1].desiredCount == 3)
    #expect(inventory.workloads[1].readyCount == 2)
    #expect(inventory.workloads[0].readyCount == 1)
    #expect(inventory.pods.map(\.id) == ["default/web-abc", "kube-system/coredns"])
    #expect(inventory.pods[0].phase == .pending)
    #expect(inventory.pods[0].readyContainerCount == 1)
    #expect(inventory.pods[0].containerCount == 2)
    #expect(inventory.pods[0].restartCount == 2)
    #expect(inventory.services.map(\.id) == ["default/web", "kube-system/kube-dns"])
    #expect(inventory.services[0].ports.first?.targetPort == "http")
    #expect(inventory.services[0].ports.first?.nodePort == 30_080)
    #expect(inventory.services[1].ports.first?.targetPort == "53")
  }

  @Test
  func rejectsDuplicateStableResourceIdentity() {
    let duplicatePod = """
      {
        "metadata": {"namespace": "default", "name": "duplicate"},
        "spec": {"containers": []},
        "status": {"phase": "Pending", "containerStatuses": []}
      }
      """
    let output = inventoryOutput(
      workloads: #"{"items":[]}"#,
      pods: "{\"items\":[\(duplicatePod),\(duplicatePod)]}",
      services: #"{"items":[]}"#
    )

    #expect(throws: KubernetesClusterError.invalidResourceInventory) {
      _ = try KubernetesResourceInventoryParser().parse(
        output,
        capturedAt: .distantPast
      )
    }
  }

  @Test
  func rejectsInventoryBeyondPerSectionLimit() {
    let workload = """
      {
        "kind": "Deployment",
        "metadata": {"namespace": "default", "name": "workload"},
        "spec": {"replicas": 1},
        "status": {"readyReplicas": 1, "availableReplicas": 1}
      }
      """
    let workloads = Array(
      repeating: workload,
      count: KubernetesResourceInventoryParser.maximumItemsPerSection + 1
    )
    .joined(separator: ",")
    let output = inventoryOutput(
      workloads: "{\"items\":[\(workloads)]}",
      pods: #"{"items":[]}"#,
      services: #"{"items":[]}"#
    )

    #expect(throws: KubernetesClusterError.resourceInventoryTooLarge) {
      _ = try KubernetesResourceInventoryParser().parse(
        output,
        capturedAt: .distantPast
      )
    }
  }

  @Test
  func rejectsMissingSectionsAndInvalidServicePorts() {
    #expect(throws: KubernetesClusterError.invalidResourceInventory) {
      _ = try KubernetesResourceInventoryParser().parse(
        #"{"items":[]}"#,
        capturedAt: .distantPast
      )
    }

    let output = inventoryOutput(
      workloads: #"{"items":[]}"#,
      pods: #"{"items":[]}"#,
      services: """
        {
          "items": [
            {
              "metadata": {"namespace": "default", "name": "bad"},
              "spec": {
                "ports": [
                  {"protocol": "TCP", "port": 70000, "targetPort": 80}
                ]
              }
            }
          ]
        }
        """
    )
    #expect(throws: KubernetesClusterError.invalidResourceInventory) {
      _ = try KubernetesResourceInventoryParser().parse(
        output,
        capturedAt: .distantPast
      )
    }
  }

  private func inventoryOutput(
    workloads: String,
    pods: String,
    services: String
  ) -> String {
    """
    \(KubernetesResourceInventoryParser.workloadsMarker)
    \(workloads)
    \(KubernetesResourceInventoryParser.podsMarker)
    \(pods)
    \(KubernetesResourceInventoryParser.servicesMarker)
    \(services)
    """
  }
}
