import Foundation
import Testing

@testable import NativeContainers

@Suite("Container creation draft")
struct ContainerCreationDraftTests {
  @Test
  func convertsEditableRowsIntoImmutableReviewedAttachments() throws {
    let volume = makeVolume()
    let builtin = makeNetwork(id: "default", isBuiltin: true)
    let backend = makeNetwork(id: "backend")
    let hostAccess = try ContainerHostAccessConfiguration(
      domain: "host.container.internal",
      redirectIPv4Address: "203.0.113.113"
    )
    let environment = ContainerAttachmentEnvironment(
      publishedSocketRootPath: "/tmp/nativecontainers",
      hostAccess: ContainerHostAccessCatalog(
        configurations: [hostAccess],
        warnings: []
      )
    )
    var draft = ContainerCreationDraft(defaultNetworkID: builtin.id)
    draft.name = "web-api"
    draft.imageReference = "alpine:latest"
    draft.volumeMounts = [
      ContainerVolumeMountDraft(
        volumeName: volume.name,
        containerPath: "/var/lib/data",
        isReadOnly: true
      )
    ]
    draft.networkAttachments.append(
      ContainerNetworkAttachmentDraft(networkID: backend.id)
    )
    draft.publishedSockets = [
      ContainerSocketPublicationDraft(
        hostSocketName: "api.sock",
        containerPath: "/run/api.sock"
      )
    ]
    draft.requiresHostAccess = true
    draft.selectedHostAccessID = hostAccess.id

    let request = try draft.makeRequest(
      availableVolumes: [volume],
      availableNetworks: [builtin, backend],
      attachmentEnvironment: environment
    )

    #expect(request.attachments.volumeMounts.first?.volume == volume.configurationIdentity)
    #expect(request.attachments.volumeMounts.first?.isReadOnly == true)
    #expect(request.attachments.networks.map(\.networkID) == ["default", "backend"])
    #expect(request.attachments.publishedSockets.first?.hostSocketName == "api.sock")
    #expect(request.attachments.requiredHostAccess == hostAccess)
  }

  @Test
  func failsWhenAReviewedResourceDisappearsFromTheCurrentCatalog() throws {
    var draft = ContainerCreationDraft(defaultNetworkID: "default")
    draft.name = "web-api"
    draft.imageReference = "alpine:latest"
    draft.volumeMounts = [ContainerVolumeMountDraft(volumeName: "missing")]

    #expect(
      throws: ContainerAttachmentValidationError.unavailableVolume("missing")
    ) {
      try draft.makeRequest(
        availableVolumes: [],
        availableNetworks: [makeNetwork(id: "default", isBuiltin: true)],
        attachmentEnvironment: nil
      )
    }

    draft.volumeMounts = []
    #expect(
      throws: ContainerAttachmentValidationError.unavailableNetwork("default")
    ) {
      try draft.makeRequest(
        availableVolumes: [],
        availableNetworks: [],
        attachmentEnvironment: nil
      )
    }
  }

  @Test
  func ensuresBuiltinNetworkWhenInventoryArrivesAfterPresentation() {
    var draft = ContainerCreationDraft()
    let builtin = makeNetwork(id: "default", isBuiltin: true)

    draft.ensureDefaultNetwork(from: [builtin])
    draft.ensureDefaultNetwork(from: [builtin])

    #expect(draft.networkAttachments.map(\.networkID) == ["default"])
  }

  private func makeVolume() -> VolumeRecord {
    VolumeRecord(
      id: "data",
      name: "data",
      driver: "local",
      format: "ext4",
      source: "/tmp/data.img",
      createdAt: Date(timeIntervalSince1970: 1),
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB,
      allocatedBytes: nil,
      labels: [:],
      options: ["size": "67108864B"],
      isAnonymous: false,
      usedByContainerIDs: []
    )
  }

  private func makeNetwork(id: String, isBuiltin: Bool = false) -> NetworkRecord {
    NetworkRecord(
      id: id,
      name: id,
      mode: .nat,
      createdAt: Date(timeIntervalSince1970: isBuiltin ? 1 : 2),
      configuredIPv4Subnet: nil,
      configuredIPv6Subnet: nil,
      assignedIPv4Subnet: isBuiltin ? "192.168.64.0/24" : "192.168.100.0/24",
      ipv4Gateway: isBuiltin ? "192.168.64.1" : "192.168.100.1",
      assignedIPv6Subnet: nil,
      labels: isBuiltin ? [ResourceOperationLabel.appleResourceRoleKey: "builtin"] : [:],
      plugin: "container-network-vmnet",
      options: [:],
      isBuiltin: isBuiltin,
      usedByContainerIDs: []
    )
  }
}
