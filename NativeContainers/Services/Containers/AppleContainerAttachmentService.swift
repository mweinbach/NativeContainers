import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import Foundation

struct AppleContainerAttachmentService: ContainerAttachmentManaging {
  private let infrastructureClient: any AppleInfrastructureTransport
  private let containerReader: any ContainerSnapshotReading
  private let hostAccessService: AppleContainerHostAccessService
  private let socketWorkspace: ApplePublishedSocketWorkspace

  init(
    infrastructureClient: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    containerReader: any ContainerSnapshotReading = AppleContainerSnapshotReader(),
    hostAccessService: AppleContainerHostAccessService = AppleContainerHostAccessService(),
    socketWorkspace: ApplePublishedSocketWorkspace = ApplePublishedSocketWorkspace()
  ) {
    self.infrastructureClient = infrastructureClient
    self.containerReader = containerReader
    self.hostAccessService = hostAccessService
    self.socketWorkspace = socketWorkspace
  }

  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment {
    ContainerAttachmentEnvironment(
      publishedSocketRootPath: socketWorkspace.rootPath,
      hostAccess: hostAccessService.loadCatalog()
    )
  }

  func resolveAttachments(
    _ selection: ContainerAttachmentSelection,
    operationID: UUID,
    containerID: String,
    dnsDomain: String?
  ) async throws -> ResolvedContainerAttachments {
    try Task.checkCancellation()

    async let volumeRequest = infrastructureClient.listVolumes()
    async let networkRequest = infrastructureClient.listNetworks()
    async let containerRequest = containerReader.list()
    let (volumeConfigurations, networkResources, containerSnapshots) =
      try await (volumeRequest, networkRequest, containerRequest)

    if let hostAccess = selection.requiredHostAccess {
      try hostAccessService.validate(hostAccess)
    }

    let mounts = try selection.volumeMounts.map { requested in
      guard
        let current = volumeConfigurations.first(where: {
          $0.name == requested.volume.name
        }),
        volumeIdentity(current) == requested.volume
      else {
        throw ContainerAttachmentResolutionError.staleVolume(requested.volume.name)
      }

      let consumers = containerSnapshots.compactMap { snapshot in
        snapshot.configuration.mounts.contains(where: {
          $0.volumeName == requested.volume.name
        }) ? snapshot.id : nil
      }
      guard consumers.isEmpty else {
        throw ContainerAttachmentResolutionError.volumeInUse(
          requested.volume.name,
          consumers.sorted()
        )
      }

      return Filesystem.volume(
        name: current.name,
        format: current.format,
        source: current.source,
        destination: requested.containerPath,
        options: requested.isReadOnly ? ["ro"] : []
      )
    }

    let selectedNetworks = try resolveNetworks(
      selection.networks,
      resources: networkResources
    )
    if let hostAccess = selection.requiredHostAccess {
      try validateHostAccessAddress(
        hostAccess,
        against: selectedNetworks
      )
    }

    let hostname = primaryHostname(containerID: containerID, dnsDomain: dnsDomain)
    let networks = selectedNetworks.enumerated().map { index, network in
      AttachmentConfiguration(
        network: network.id,
        options: AttachmentOptions(
          hostname: index == 0 ? hostname : containerID,
          macAddress: nil,
          mtu: 1_280
        )
      )
    }

    try Task.checkCancellation()
    let sockets = try socketWorkspace.prepare(
      selection.publishedSockets,
      operationID: operationID
    )
    return ResolvedContainerAttachments(
      mounts: mounts,
      networks: networks,
      publishedSockets: sockets
    )
  }

  func validatePublishedSocketsBeforeStart(
    _ sockets: [PublishSocket],
    operationID: UUID
  ) async throws {
    try socketWorkspace.validateBeforeStart(sockets, operationID: operationID)
  }

  func cleanupPublishedSocketWorkspace(operationID: UUID) async {
    socketWorkspace.cleanup(operationID: operationID)
  }

  private func resolveNetworks(
    _ requestedNetworks: [ContainerNetworkAttachment],
    resources: [NetworkResource]
  ) throws -> [NetworkResource] {
    if requestedNetworks.isEmpty {
      guard let builtin = resources.first(where: \.isBuiltin) else {
        throw ContainerAttachmentResolutionError.builtinNetworkUnavailable
      }
      return [builtin]
    }

    let resolved = try requestedNetworks.map { requested in
      guard
        let current = resources.first(where: { $0.id == requested.networkID }),
        networkIdentity(current) == requested.network
      else {
        throw ContainerAttachmentResolutionError.staleNetwork(requested.network.name)
      }
      return current
    }

    let isOnlyBuiltin = resolved.count == 1 && resolved[0].isBuiltin
    if !isOnlyBuiltin {
      guard #available(macOS 26, *) else {
        throw ContainerAttachmentResolutionError.customNetworksUnavailable
      }
    }
    return resolved
  }

  private func primaryHostname(containerID: String, dnsDomain: String?) -> String {
    if containerID.contains(".") {
      return "\(containerID)."
    }
    if let dnsDomain {
      return "\(containerID).\(dnsDomain)."
    }
    return containerID
  }

  private func validateHostAccessAddress(
    _ configuration: ContainerHostAccessConfiguration,
    against networks: [NetworkResource]
  ) throws {
    let address = try ContainerizationExtras.IPv4Address(
      configuration.redirectIPv4Address
    )
    if let conflict = networks.first(where: { $0.status.ipv4Subnet.contains(address) }) {
      throw ContainerAttachmentResolutionError.hostAccessNetworkConflict(
        configuration.domain,
        conflict.name
      )
    }
  }

  private func volumeIdentity(
    _ configuration: VolumeConfiguration
  ) -> VolumeConfigurationIdentity {
    VolumeConfigurationIdentity(
      name: configuration.name,
      driver: configuration.driver,
      format: configuration.format,
      source: configuration.source,
      createdAt: configuration.creationDate,
      labels: configuration.labels,
      options: configuration.options,
      sizeBytes: configuration.sizeInBytes
    )
  }

  private func networkIdentity(
    _ resource: NetworkResource
  ) -> NetworkConfigurationIdentity {
    NetworkConfigurationIdentity(
      name: resource.name,
      mode: ContainerNetworkMode(rawValue: resource.configuration.mode.rawValue) ?? .nat,
      createdAt: resource.creationDate,
      configuredIPv4Subnet: resource.configuration.ipv4Subnet.map(String.init(describing:)),
      configuredIPv6Subnet: resource.configuration.ipv6Subnet.map(String.init(describing:)),
      labels: resource.labels.dictionary,
      plugin: resource.configuration.plugin,
      options: resource.configuration.options,
      isBuiltin: resource.isBuiltin
    )
  }
}

enum ContainerAttachmentResolutionError: LocalizedError, Equatable {
  case staleVolume(String)
  case volumeInUse(String, [String])
  case staleNetwork(String)
  case builtinNetworkUnavailable
  case customNetworksUnavailable
  case hostAccessNetworkConflict(String, String)

  var errorDescription: String? {
    switch self {
    case .staleVolume(let name):
      "Named volume “\(name)” changed or disappeared after review."
    case .volumeInUse(let name, let containerIDs):
      "Named volume “\(name)” is already attached to \(containerIDs.formatted())."
    case .staleNetwork(let name):
      "Network “\(name)” changed or disappeared after review."
    case .builtinNetworkUnavailable:
      "Apple’s built-in container network is unavailable."
    case .customNetworksUnavailable:
      "Custom network attachments require macOS 26 or newer."
    case .hostAccessNetworkConflict(let domain, let network):
      "Host alias “\(domain)” uses an address inside network “\(network)”. Choose a nonconflicting host-access address."
    }
  }
}
