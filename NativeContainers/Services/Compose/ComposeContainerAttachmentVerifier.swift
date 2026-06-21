import Foundation

struct ComposeContainerAttachmentVerifier: Sendable {
  func hasExactAttachments(
    containerID: String,
    service: ComposeDesiredService,
    desiredState: ComposeDesiredState,
    inventory: ContainerInventory
  ) -> Bool {
    guard
      let expectedVolumes = runtimeNames(
        logicalNames: service.volumeNames,
        resources: desiredState.volumes
      ),
      let expectedNetworks = runtimeNames(
        logicalNames: service.networkNames,
        resources: desiredState.networks
      )
    else {
      return false
    }

    let actualVolumes = Set(
      inventory.volumes.compactMap {
        $0.usedByContainerIDs.contains(containerID) ? $0.name : nil
      }
    )
    let actualNetworks = Set(
      inventory.networks.compactMap {
        $0.usedByContainerIDs.contains(containerID) ? $0.name : nil
      }
    )
    return actualVolumes == expectedVolumes && actualNetworks == expectedNetworks
  }

  private func runtimeNames(
    logicalNames: [String],
    resources: [ComposeDesiredResource]
  ) -> Set<String>? {
    let byLogicalName = Dictionary(
      resources.map { ($0.logicalName, $0.runtimeName) },
      uniquingKeysWith: { first, _ in first }
    )
    guard byLogicalName.count == resources.count else { return nil }

    var result: Set<String> = []
    for logicalName in logicalNames {
      guard let runtimeName = byLogicalName[logicalName] else { return nil }
      result.insert(runtimeName)
    }
    return result
  }
}
