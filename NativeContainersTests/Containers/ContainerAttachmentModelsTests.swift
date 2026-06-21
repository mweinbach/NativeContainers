import Foundation
import Testing

@testable import NativeContainers

@Suite("Container attachment models")
struct ContainerAttachmentModelsTests {
  @Test
  func freezesReviewedResourceIdentitiesAndNormalizesPaths() throws {
    let volume = makeVolume()
    let network = makeNetwork()
    let mount = try ContainerVolumeMount(
      volume: volume,
      containerPath: " /var//lib/data/ ",
      isReadOnly: true
    )
    let socket = try ContainerUnixSocketPublication(
      hostSocketName: "nativecontainers.sock",
      containerPath: "/run//service.sock"
    )
    let hostAccess = try ContainerHostAccessConfiguration(
      domain: "Host.Container.Internal.",
      redirectIPv4Address: "203.0.113.113"
    )
    let selection = try ContainerAttachmentSelection(
      volumeMounts: [mount],
      networks: [ContainerNetworkAttachment(network: network)],
      publishedSockets: [socket],
      requiredHostAccess: hostAccess
    )

    #expect(selection.volumeMounts.first?.volume == volume.configurationIdentity)
    #expect(selection.volumeMounts.first?.containerPath == "/var/lib/data")
    #expect(selection.volumeMounts.first?.isReadOnly == true)
    #expect(selection.networks.first?.network == network.configurationIdentity)
    #expect(selection.publishedSockets.first?.hostSocketName == "nativecontainers.sock")
    #expect(selection.publishedSockets.first?.containerPath == "/run/service.sock")
    #expect(selection.requiredHostAccess?.domain == "host.container.internal")
  }

  @Test
  func rejectsAmbiguousOrUnsafePaths() throws {
    let volume = makeVolume()

    #expect(throws: ContainerAttachmentValidationError.invalidContainerPath) {
      try ContainerVolumeMount(volume: volume, containerPath: "var/lib/data")
    }
    #expect(throws: ContainerAttachmentValidationError.invalidContainerPath) {
      try ContainerVolumeMount(volume: volume, containerPath: "/var/../data")
    }
    #expect(throws: ContainerAttachmentValidationError.invalidHostSocketName) {
      try ContainerUnixSocketPublication(
        hostSocketName: "../service.sock",
        containerPath: "/run/service.sock"
      )
    }
  }

  @Test
  func rejectsDuplicateDestinationsAndAttachments() throws {
    let volume = makeVolume()
    let secondVolume = makeVolume(name: "cache")
    let network = makeNetwork()
    let firstMount = try ContainerVolumeMount(volume: volume, containerPath: "/data")
    let secondMount = try ContainerVolumeMount(volume: secondVolume, containerPath: "/data")
    let duplicateVolume = try ContainerVolumeMount(volume: volume, containerPath: "/backup")
    let firstSocket = try ContainerUnixSocketPublication(
      hostSocketName: "one.sock",
      containerPath: "/run/one.sock"
    )
    let duplicateHostSocket = try ContainerUnixSocketPublication(
      hostSocketName: "one.sock",
      containerPath: "/run/two.sock"
    )

    #expect(throws: ContainerAttachmentValidationError.duplicateMountDestination) {
      try ContainerAttachmentSelection(
        volumeMounts: [firstMount, secondMount],
        networks: [],
        publishedSockets: [],
        requiredHostAccess: nil
      )
    }
    #expect(throws: ContainerAttachmentValidationError.duplicateVolume) {
      try ContainerAttachmentSelection(
        volumeMounts: [firstMount, duplicateVolume],
        networks: [],
        publishedSockets: [],
        requiredHostAccess: nil
      )
    }
    #expect(throws: ContainerAttachmentValidationError.duplicateNetwork) {
      try ContainerAttachmentSelection(
        volumeMounts: [],
        networks: [
          ContainerNetworkAttachment(network: network),
          ContainerNetworkAttachment(network: network),
        ],
        publishedSockets: [],
        requiredHostAccess: nil
      )
    }
    #expect(throws: ContainerAttachmentValidationError.duplicateHostSocketPath) {
      try ContainerAttachmentSelection(
        volumeMounts: [],
        networks: [],
        publishedSockets: [firstSocket, duplicateHostSocket],
        requiredHostAccess: nil
      )
    }
  }

  @Test
  func rejectsAnonymousVolumesAndInvalidHostAccess() throws {
    let anonymous = makeVolume(isAnonymous: true)

    #expect(throws: ContainerAttachmentValidationError.anonymousVolume("data")) {
      try ContainerVolumeMount(volume: anonymous, containerPath: "/data")
    }
    #expect(throws: ContainerAttachmentValidationError.invalidHostAccessDomain) {
      try ContainerHostAccessConfiguration(
        domain: "bad_domain",
        redirectIPv4Address: "203.0.113.113"
      )
    }
    #expect(throws: ContainerAttachmentValidationError.invalidHostAccessAddress) {
      try ContainerHostAccessConfiguration(
        domain: "host.container.internal",
        redirectIPv4Address: "::1"
      )
    }
  }

  private func makeVolume(
    name: String = "data",
    isAnonymous: Bool = false
  ) -> VolumeRecord {
    VolumeRecord(
      id: name,
      name: name,
      driver: "local",
      format: "ext4",
      source: "/tmp/\(name).img",
      createdAt: Date(timeIntervalSince1970: 1),
      sizeBytes: 64 * VolumeCreateRequest.bytesPerMiB,
      allocatedBytes: nil,
      labels: [:],
      options: ["size": "67108864B"],
      isAnonymous: isAnonymous,
      usedByContainerIDs: []
    )
  }

  private func makeNetwork() -> NetworkRecord {
    NetworkRecord(
      id: "backend",
      name: "backend",
      mode: .hostOnly,
      createdAt: Date(timeIntervalSince1970: 2),
      configuredIPv4Subnet: "192.168.100.0/24",
      configuredIPv6Subnet: nil,
      assignedIPv4Subnet: "192.168.100.0/24",
      ipv4Gateway: "192.168.100.1",
      assignedIPv6Subnet: nil,
      labels: [:],
      plugin: "container-network-vmnet",
      options: [:],
      isBuiltin: false,
      usedByContainerIDs: []
    )
  }
}
