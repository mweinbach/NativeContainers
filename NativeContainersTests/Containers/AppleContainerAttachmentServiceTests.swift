import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container attachment service")
struct AppleContainerAttachmentServiceTests {
  @Test
  func resolvesReviewedVolumesNetworksAndSocketsWithoutAutoCreatingResources() async throws {
    let volume = VolumeConfiguration(
      name: "data",
      driver: "local",
      source: "/tmp/data.img",
      creationDate: Date(timeIntervalSince1970: 1),
      labels: [:],
      options: ["size": "67108864B"],
      sizeInBytes: 64 * VolumeCreateRequest.bytesPerMiB
    )
    let builtin = try makeNetwork(
      name: "default",
      subnet: "192.168.64.0/24",
      gateway: "192.168.64.1",
      isBuiltin: true
    )
    let backend = try makeNetwork(
      name: "backend",
      subnet: "192.168.100.0/24",
      gateway: "192.168.100.1"
    )
    let fixture = AttachmentServiceFixture(
      volumes: [volume],
      networks: [builtin, backend]
    )
    defer { fixture.remove() }
    let operationID = UUID()
    let selection = try ContainerAttachmentSelection(
      volumeMounts: [
        try ContainerVolumeMount(
          volume: volumeRecord(volume),
          containerPath: "/var/lib/data",
          isReadOnly: true
        )
      ],
      networks: [
        ContainerNetworkAttachment(network: networkRecord(backend)),
        ContainerNetworkAttachment(network: networkRecord(builtin)),
      ],
      publishedSockets: [
        try ContainerUnixSocketPublication(
          hostSocketName: "api.sock",
          containerPath: "/run/api.sock"
        )
      ],
      requiredHostAccess: nil
    )

    let resolved = try await fixture.service.resolveAttachments(
      selection,
      operationID: operationID,
      containerID: "api",
      dnsDomain: "test"
    )

    #expect(resolved.mounts.count == 1)
    #expect(resolved.mounts[0].volumeName == "data")
    #expect(resolved.mounts[0].destination == "/var/lib/data")
    #expect(resolved.mounts[0].options == ["ro"])
    #expect(resolved.networks.map(\.network) == ["backend", "default"])
    #expect(resolved.networks.map(\.options.hostname) == ["api.test.", "api"])
    #expect(resolved.networks.allSatisfy { $0.options.mtu == 1_280 })
    #expect(resolved.publishedSockets.count == 1)
    let operationDirectory = fixture.socketRootURL.appending(
      path: operationID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    #expect(
      resolved.publishedSockets[0].hostPath.string.hasPrefix(
        operationDirectory.path(percentEncoded: false)
      )
    )
  }

  @Test
  func rejectsRecreatedVolumeAndNetworkIdentities() async throws {
    let volume = VolumeConfiguration(
      name: "data",
      driver: "local",
      source: "/tmp/data.img",
      creationDate: Date(timeIntervalSince1970: 1),
      labels: [:],
      options: [:],
      sizeInBytes: nil
    )
    let currentNetwork = try makeNetwork(
      name: "backend",
      subnet: "192.168.100.0/24",
      gateway: "192.168.100.1"
    )
    let fixture = AttachmentServiceFixture(
      volumes: [volume],
      networks: [currentNetwork]
    )
    defer { fixture.remove() }

    let staleVolume = VolumeRecord(
      id: "data",
      name: "data",
      driver: "local",
      format: volume.format,
      source: volume.source,
      createdAt: Date(timeIntervalSince1970: 0),
      sizeBytes: volume.sizeInBytes,
      allocatedBytes: nil,
      labels: volume.labels,
      options: volume.options,
      isAnonymous: false,
      usedByContainerIDs: []
    )
    let staleVolumeSelection = try ContainerAttachmentSelection(
      volumeMounts: [
        try ContainerVolumeMount(volume: staleVolume, containerPath: "/data")
      ],
      networks: [],
      publishedSockets: [],
      requiredHostAccess: nil
    )

    await #expect(
      throws: ContainerAttachmentResolutionError.staleVolume("data")
    ) {
      try await fixture.service.resolveAttachments(
        staleVolumeSelection,
        operationID: UUID(),
        containerID: "api",
        dnsDomain: nil
      )
    }

    var staleNetwork = networkRecord(currentNetwork)
    staleNetwork = NetworkRecord(
      id: staleNetwork.id,
      name: staleNetwork.name,
      mode: staleNetwork.mode,
      createdAt: Date(timeIntervalSince1970: 0),
      configuredIPv4Subnet: staleNetwork.configuredIPv4Subnet,
      configuredIPv6Subnet: staleNetwork.configuredIPv6Subnet,
      assignedIPv4Subnet: staleNetwork.assignedIPv4Subnet,
      ipv4Gateway: staleNetwork.ipv4Gateway,
      assignedIPv6Subnet: staleNetwork.assignedIPv6Subnet,
      labels: staleNetwork.labels,
      plugin: staleNetwork.plugin,
      options: staleNetwork.options,
      isBuiltin: staleNetwork.isBuiltin,
      usedByContainerIDs: []
    )
    let staleNetworkSelection = try ContainerAttachmentSelection(
      volumeMounts: [],
      networks: [ContainerNetworkAttachment(network: staleNetwork)],
      publishedSockets: [],
      requiredHostAccess: nil
    )

    await #expect(
      throws: ContainerAttachmentResolutionError.staleNetwork("backend")
    ) {
      try await fixture.service.resolveAttachments(
        staleNetworkSelection,
        operationID: UUID(),
        containerID: "api",
        dnsDomain: nil
      )
    }
  }

  @Test
  func emptyNetworkSelectionUsesCurrentBuiltinNetwork() async throws {
    let builtin = try makeNetwork(
      name: "default",
      subnet: "192.168.64.0/24",
      gateway: "192.168.64.1",
      isBuiltin: true
    )
    let fixture = AttachmentServiceFixture(volumes: [], networks: [builtin])
    defer { fixture.remove() }

    let resolved = try await fixture.service.resolveAttachments(
      .empty,
      operationID: UUID(),
      containerID: "api",
      dnsDomain: nil
    )

    #expect(resolved.networks.map(\.network) == ["default"])
    #expect(resolved.networks.first?.options.hostname == "api")
  }

  @Test
  func resolvesReviewedHostDirectoriesAsVirtioFSAttachments() async throws {
    let rootURL = URL(
      filePath: "/private/tmp/nca-attachment-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appending(path: "Source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    let hostDirectoryService = AppleContainerHostDirectoryService(
      manifestStore: FileContainerHostDirectoryManifestStore(
        rootURL: rootURL.appending(path: "Manifests", directoryHint: .isDirectory)
      )
    )
    let reviewed = try hostDirectoryService.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: sourceURL,
        containerPath: "/workspace/source",
        isReadOnly: true
      )
    )
    let builtin = try makeNetwork(
      name: "default",
      subnet: "192.168.64.0/24",
      gateway: "192.168.64.1",
      isBuiltin: true
    )
    let fixture = AttachmentServiceFixture(
      volumes: [],
      networks: [builtin],
      hostDirectoryService: hostDirectoryService
    )
    defer { fixture.remove() }
    let operationID = UUID()
    let selection = try ContainerAttachmentSelection(
      volumeMounts: [],
      hostDirectoryMounts: [reviewed],
      networks: [],
      publishedSockets: [],
      requiredHostAccess: nil
    )

    let resolved = try await fixture.service.resolveAttachments(
      selection,
      operationID: operationID,
      containerID: "workspace",
      dnsDomain: nil
    )
    defer {
      resolved.hostDirectoryAccess?.release()
      hostDirectoryService.cleanup(operationID: operationID)
    }

    #expect(resolved.mounts.count == 1)
    #expect(resolved.mounts[0].isVirtiofs)
    #expect(resolved.mounts[0].source == reviewed.lastKnownPath)
    #expect(resolved.mounts[0].destination == "/workspace/source")
    #expect(resolved.mounts[0].options == ["ro"])
  }

  private func makeNetwork(
    name: String,
    subnet: String,
    gateway: String,
    isBuiltin: Bool = false
  ) throws -> NetworkResource {
    let labels =
      isBuiltin
      ? try ResourceLabels([ResourceLabelKeys.role: ResourceRoleValues.builtin])
      : ResourceLabels()
    let configuration = try NetworkConfiguration(
      name: name,
      mode: .nat,
      labels: labels,
      plugin: "container-network-vmnet"
    )
    return NetworkResource(
      configuration: configuration,
      status: NetworkStatus(
        ipv4Subnet: try CIDRv4(subnet),
        ipv4Gateway: try ContainerizationExtras.IPv4Address(gateway),
        ipv6Subnet: nil
      )
    )
  }

  private func volumeRecord(_ configuration: VolumeConfiguration) -> VolumeRecord {
    VolumeRecord(
      id: configuration.id,
      name: configuration.name,
      driver: configuration.driver,
      format: configuration.format,
      source: configuration.source,
      createdAt: configuration.creationDate,
      sizeBytes: configuration.sizeInBytes,
      allocatedBytes: nil,
      labels: configuration.labels,
      options: configuration.options,
      isAnonymous: configuration.isAnonymous,
      usedByContainerIDs: []
    )
  }

  private func networkRecord(_ resource: NetworkResource) -> NetworkRecord {
    NetworkRecord(
      id: resource.id,
      name: resource.name,
      mode: ContainerNetworkMode(rawValue: resource.configuration.mode.rawValue) ?? .nat,
      createdAt: resource.creationDate,
      configuredIPv4Subnet: resource.configuration.ipv4Subnet.map(String.init(describing:)),
      configuredIPv6Subnet: resource.configuration.ipv6Subnet.map(String.init(describing:)),
      assignedIPv4Subnet: String(describing: resource.status.ipv4Subnet),
      ipv4Gateway: String(describing: resource.status.ipv4Gateway),
      assignedIPv6Subnet: resource.status.ipv6Subnet.map(String.init(describing:)),
      labels: resource.labels.dictionary,
      plugin: resource.configuration.plugin,
      options: resource.configuration.options,
      isBuiltin: resource.isBuiltin,
      usedByContainerIDs: []
    )
  }
}

private struct AttachmentServiceFixture {
  let socketRootURL: URL
  let service: AppleContainerAttachmentService

  init(
    volumes: [VolumeConfiguration],
    networks: [NetworkResource],
    hostDirectoryService: any ContainerHostDirectoryManaging =
      AppleContainerHostDirectoryService()
  ) {
    socketRootURL = URL(
      filePath: "/private/tmp",
      directoryHint: .isDirectory
    ).appending(
      path: "nca-\(UUID().uuidString.prefix(8))",
      directoryHint: .isDirectory
    )
    service = AppleContainerAttachmentService(
      infrastructureClient: AttachmentInfrastructureTransport(
        volumes: volumes,
        networks: networks
      ),
      containerReader: AttachmentEmptyContainerReader(),
      socketWorkspace: ApplePublishedSocketWorkspace(rootURL: socketRootURL),
      hostDirectoryService: hostDirectoryService
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: socketRootURL)
  }
}

private actor AttachmentInfrastructureTransport: AppleInfrastructureTransport {
  let volumes: [VolumeConfiguration]
  let networks: [NetworkResource]

  init(volumes: [VolumeConfiguration], networks: [NetworkResource]) {
    self.volumes = volumes
    self.networks = networks
  }

  func createVolume(
    name: String,
    driver: String,
    driverOptions: [String: String],
    labels: [String: String]
  ) async throws -> VolumeConfiguration {
    throw ResourceManagementError.unsupported
  }

  func deleteVolume(name: String) async throws {
    throw ResourceManagementError.unsupported
  }

  func listVolumes() async throws -> [VolumeConfiguration] {
    volumes
  }

  func volumeDiskUsage(name: String) async throws -> UInt64 {
    throw ResourceManagementError.unsupported
  }

  func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkResource {
    throw ResourceManagementError.unsupported
  }

  func deleteNetwork(id: String) async throws {
    throw ResourceManagementError.unsupported
  }

  func listNetworks() async throws -> [NetworkResource] {
    networks
  }
}

private struct AttachmentEmptyContainerReader: ContainerSnapshotReading {
  func list() async throws -> [ContainerSnapshot] { [] }

  func get(id: String) async throws -> ContainerSnapshot {
    throw ResourceManagementError.containerNotRunning(id)
  }
}
