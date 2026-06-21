import Foundation

protocol SocktainerComposeFixtureCleanupPlanning: Sendable {
  func plan(
    from inventory: ContainerInventory,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) throws -> SocktainerComposeFixtureCleanupPlan
}

struct SocktainerComposeFixtureCleanupPlanner:
  SocktainerComposeFixtureCleanupPlanning
{
  func plan(
    from inventory: ContainerInventory,
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) throws -> SocktainerComposeFixtureCleanupPlan {
    let container = inventory.containers.first(where: {
      $0.id == configuration.containerName
    })
    if let container {
      guard
        container.labels[ComposeLabelKey.project] == configuration.projectName,
        container.labels[ComposeLabelKey.service] == "probe"
      else {
        throw SocktainerComposeLiveFixtureError.unsafeCleanupResource(
          "container \(configuration.containerName)"
        )
      }
    }

    let volume = inventory.volumes.first(where: {
      $0.name == configuration.volumeName
    })
    if let volume {
      guard
        !volume.isAnonymous,
        volume.labels[ComposeLabelKey.project] == configuration.projectName,
        volume.labels[ComposeLabelKey.volume] == "data"
      else {
        throw SocktainerComposeLiveFixtureError.unsafeCleanupResource(
          "volume \(configuration.volumeName)"
        )
      }
    }

    let network = inventory.networks.first(where: {
      $0.name == configuration.networkName
    })
    if let network {
      guard
        !network.isBuiltin,
        network.labels[ComposeLabelKey.project] == configuration.projectName,
        network.labels[ComposeLabelKey.network] == "default"
      else {
        throw SocktainerComposeLiveFixtureError.unsafeCleanupResource(
          "network \(configuration.networkName)"
        )
      }
    }

    return SocktainerComposeFixtureCleanupPlan(
      container: container.map(SocktainerComposeFixtureContainerIdentity.init),
      volume: volume.map(SocktainerComposeFixtureVolumeIdentity.init),
      network: network.map(SocktainerComposeFixtureNetworkIdentity.init)
    )
  }
}
