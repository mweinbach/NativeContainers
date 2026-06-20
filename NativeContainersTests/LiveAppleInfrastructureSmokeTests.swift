import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleInfrastructureSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func createInspectAndDeleteReviewedVolumeAndNetwork() async throws {
    let service = AppleContainerService()
    let suffix = UUID().uuidString.lowercased().prefix(8)
    let volumeName = "nativecontainers-volume-\(suffix)"
    let networkName = "nativecontainers-network-\(suffix)"

    do {
      let volumeRequest = try VolumeCreateRequest(
        name: volumeName,
        sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB,
        journalMode: .ordered,
        labels: ["com.nativecontainers.smoke": "volume"]
      )
      let volumePlan = try await service.prepareVolumeCreation(volumeRequest)
      let volume = try await service.createVolume(volumePlan)
      #expect(volume.name == volumeName)
      #expect(volume.driver == "local")
      #expect(volume.format == "ext4")
      #expect(volume.sizeBytes == 64 * VolumeCreateRequest.bytesPerMiB)
      #expect(volume.allocatedBytes != nil)
      #expect(volume.usedByContainerIDs.isEmpty)

      let networkRequest = try NetworkCreateRequest(
        name: networkName,
        mode: .hostOnly,
        labels: ["com.nativecontainers.smoke": "network"]
      )
      let networkPlan = try await service.prepareNetworkCreation(networkRequest)
      let network = try await service.createNetwork(networkPlan)
      #expect(network.name == networkName)
      #expect(network.mode == .hostOnly)
      #expect(network.plugin == "container-network-vmnet")
      #expect(!network.isBuiltin)
      #expect(network.usedByContainerIDs.isEmpty)

      let inventory = try await service.loadInventory()
      #expect(inventory.volumes.contains { $0.name == volumeName })
      #expect(inventory.networks.contains { $0.name == networkName })

      try await service.deleteNetwork(
        service.prepareNetworkDeletion(id: networkName)
      )
      try await service.deleteVolume(
        service.prepareVolumeDeletion(name: volumeName)
      )

      let cleaned = try await service.loadInventory()
      #expect(!cleaned.volumes.contains { $0.name == volumeName })
      #expect(!cleaned.networks.contains { $0.name == networkName })
    } catch {
      await cleanUpNetwork(networkName, service: service)
      await cleanUpVolume(volumeName, service: service)
      throw error
    }
  }

  private func cleanUpNetwork(
    _ id: String,
    service: AppleContainerService
  ) async {
    guard let plan = try? await service.prepareNetworkDeletion(id: id), plan.canDelete else {
      return
    }
    try? await service.deleteNetwork(plan)
  }

  private func cleanUpVolume(
    _ name: String,
    service: AppleContainerService
  ) async {
    guard let plan = try? await service.prepareVolumeDeletion(name: name), plan.canDelete else {
      return
    }
    try? await service.deleteVolume(plan)
  }
}
