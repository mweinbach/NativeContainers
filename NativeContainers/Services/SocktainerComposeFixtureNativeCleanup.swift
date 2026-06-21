import Foundation

protocol SocktainerComposeFixtureNativeCleaning: Sendable {
  func removeContainer(_ container: ContainerRecord) async throws
  func removeNetwork(_ network: NetworkRecord) async throws
  func removeVolume(_ volume: VolumeRecord) async throws
}

struct AppleSocktainerComposeFixtureNativeCleanup:
  SocktainerComposeFixtureNativeCleaning
{
  private let containerLifecycle: any ContainerLifecycleManaging
  private let volumes: any VolumeManaging
  private let networks: any NetworkManaging

  init(
    containerLifecycle: any ContainerLifecycleManaging =
      AppleContainerLifecycleService(),
    volumes: any VolumeManaging = AppleInfrastructureService(),
    networks: any NetworkManaging = AppleInfrastructureService()
  ) {
    self.containerLifecycle = containerLifecycle
    self.volumes = volumes
    self.networks = networks
  }

  func removeContainer(_ container: ContainerRecord) async throws {
    if container.state != .stopped {
      try await containerLifecycle.forceStopContainer(id: container.id)
    }
    try await containerLifecycle.deleteContainer(id: container.id)
  }

  func removeNetwork(_ network: NetworkRecord) async throws {
    try await networks.deleteNetwork(
      NetworkDeletionPlan(
        network: network,
        identity: network.configurationIdentity,
        generatedAt: Date()
      )
    )
  }

  func removeVolume(_ volume: VolumeRecord) async throws {
    try await volumes.deleteVolume(
      VolumeDeletionPlan(
        volume: volume,
        identity: volume.configurationIdentity,
        generatedAt: Date()
      )
    )
  }
}
