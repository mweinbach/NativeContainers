import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import Foundation

struct AppleRuntimeInventoryService: ContainerInventoryLoading {
  private let infrastructureClient: any AppleInfrastructureTransport
  private let containerReader: any ContainerSnapshotReading
  private let machineInventory: any LinuxMachineInventoryLoading

  init(
    infrastructureClient: any AppleInfrastructureTransport = AppleInfrastructureClient(),
    containerReader: any ContainerSnapshotReading = AppleContainerSnapshotReader(),
    machineInventory: any LinuxMachineInventoryLoading = AppleLinuxMachineInventoryService()
  ) {
    self.infrastructureClient = infrastructureClient
    self.containerReader = containerReader
    self.machineInventory = machineInventory
  }

  func loadInventory() async throws -> ContainerInventory {
    async let healthRequest = ClientHealthCheck.ping()
    async let containerRequest = containerReader.list()
    async let imageRequest = ClientImage.list()
    async let volumeRequest = infrastructureClient.listVolumes()
    async let networkRequest = infrastructureClient.listNetworks()
    async let machineRequest = machineInventory.loadMachines()
    async let systemConfigurationRequest = AppleContainerConfiguration.load()

    let (
      health,
      snapshots,
      clientImages,
      configurations,
      networkResources,
      machines,
      systemConfiguration
    ) = try await (
      healthRequest,
      containerRequest,
      imageRequest,
      volumeRequest,
      networkRequest,
      machineRequest,
      systemConfigurationRequest
    )

    let system = ContainerSystemInfo(
      version: health.apiServerVersion,
      build: health.apiServerBuild,
      commit: health.apiServerCommit,
      applicationRoot: health.appRoot,
      installRoot: health.installRoot
    )

    let containers = snapshots.map(Self.containerRecord(from:))

    let images = clientImages.filter { image in
      !Utility.isInfraImage(
        name: image.reference,
        builderImage: systemConfiguration.build.image,
        initImage: systemConfiguration.vminit.image
      )
    }.map { image in
      ImageRecord(
        reference: image.reference,
        digest: image.digest,
        mediaType: image.descriptor.mediaType,
        indexSizeBytes: image.descriptor.size
      )
    }

    let volumeConsumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for volumeName in snapshot.configuration.mounts.compactMap(\.volumeName) {
        result[volumeName, default: []].insert(snapshot.id)
      }
    }
    let networkConsumers = snapshots.reduce(into: [String: Set<String>]()) { result, snapshot in
      for attachment in snapshot.configuration.networks {
        result[attachment.network, default: []].insert(snapshot.id)
      }
    }
    let allocatedVolumeSizes = try await loadAllocatedVolumeSizes(
      names: configurations.map(\.name)
    )

    let volumes = configurations.map { volume in
      VolumeRecord(
        id: volume.id,
        name: volume.name,
        driver: volume.driver,
        format: volume.format,
        source: volume.source,
        createdAt: volume.creationDate,
        sizeBytes: volume.sizeInBytes,
        allocatedBytes: allocatedVolumeSizes[volume.name],
        labels: volume.labels,
        options: volume.options,
        isAnonymous: volume.isAnonymous,
        usedByContainerIDs: (volumeConsumers[volume.name] ?? []).sorted()
      )
    }

    let networks = networkResources.map { network in
      NetworkRecord(
        id: network.id,
        name: network.name,
        mode: ContainerNetworkMode(rawValue: network.configuration.mode.rawValue) ?? .nat,
        createdAt: network.creationDate,
        configuredIPv4Subnet: network.configuration.ipv4Subnet.map(String.init(describing:)),
        configuredIPv6Subnet: network.configuration.ipv6Subnet.map(String.init(describing:)),
        assignedIPv4Subnet: String(describing: network.status.ipv4Subnet),
        ipv4Gateway: String(describing: network.status.ipv4Gateway),
        assignedIPv6Subnet: network.status.ipv6Subnet.map(String.init(describing:)),
        labels: network.labels.dictionary,
        plugin: network.configuration.plugin,
        options: network.configuration.options,
        isBuiltin: network.isBuiltin,
        usedByContainerIDs: (networkConsumers[network.id] ?? []).sorted()
      )
    }

    return ContainerInventory(
      system: system,
      containers: containers.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
      images: images.sorted {
        $0.reference.localizedStandardCompare($1.reference) == .orderedAscending
      },
      volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      networks: networks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      machines: machines
    )
  }

  static func containerRecord(from snapshot: ContainerSnapshot) -> ContainerRecord {
    ContainerRecord(
      id: snapshot.id,
      imageReference: snapshot.configuration.image.reference,
      platform: String(describing: snapshot.platform),
      state: RuntimeState(rawValue: snapshot.status.rawValue) ?? .unknown,
      ipAddress: snapshot.networks.first.map { String(describing: $0.ipv4Address) },
      createdAt: snapshot.configuration.creationDate,
      startedAt: snapshot.startedDate,
      cpuCount: snapshot.configuration.resources.cpus,
      memoryBytes: snapshot.configuration.resources.memoryInBytes,
      ports: snapshot.configuration.publishedPorts.flatMap { port in
        (0..<port.count).map { offset in
          ContainerPort(
            hostAddress: String(describing: port.hostAddress),
            hostPort: port.hostPort + offset,
            containerPort: port.containerPort + offset,
            protocolName: port.proto.rawValue
          )
        }
      },
      labels: snapshot.configuration.labels
    )
  }

  private func loadAllocatedVolumeSizes(names: [String]) async throws -> [String: UInt64] {
    let uniqueNames = Array(Set(names)).sorted()
    return try await withThrowingTaskGroup(of: (String, UInt64?).self) { group in
      let initialCount = min(4, uniqueNames.count)
      for name in uniqueNames.prefix(initialCount) {
        group.addTask {
          do {
            return (name, try await self.infrastructureClient.volumeDiskUsage(name: name))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return (name, nil)
          }
        }
      }

      var nextIndex = initialCount
      var result: [String: UInt64] = [:]
      while let (name, size) = try await group.next() {
        if let size {
          result[name] = size
        }
        if nextIndex < uniqueNames.count {
          let nextName = uniqueNames[nextIndex]
          nextIndex += 1
          group.addTask {
            do {
              return (
                nextName,
                try await self.infrastructureClient.volumeDiskUsage(name: nextName)
              )
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              return (nextName, nil)
            }
          }
        }
      }
      try Task.checkCancellation()
      return result
    }
  }
}
