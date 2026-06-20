import ContainerAPIClient
import ContainerResource
import Foundation
import MachineAPIClient

actor AppleContainerService: ContainerManaging {
  private let containerClient = ContainerClient()
  private let machineClient = MachineClient()

  func loadInventory() async throws -> ContainerInventory {
    async let healthRequest = ClientHealthCheck.ping()
    async let containerRequest = containerClient.list()
    async let imageRequest = ClientImage.list()
    async let volumeRequest = ClientVolume.list()
    async let machineRequest = machineClient.list()

    let (health, snapshots, clientImages, configurations, machineSnapshots) = try await (
      healthRequest,
      containerRequest,
      imageRequest,
      volumeRequest,
      machineRequest
    )

    let system = ContainerSystemInfo(
      version: health.apiServerVersion,
      build: health.apiServerBuild,
      commit: health.apiServerCommit,
      applicationRoot: health.appRoot,
      installRoot: health.installRoot
    )

    let containers = snapshots.map { snapshot in
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
        ports: snapshot.configuration.publishedPorts.map { port in
          ContainerPort(
            hostAddress: String(describing: port.hostAddress),
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            protocolName: port.proto.rawValue
          )
        }
      )
    }

    let images = clientImages.map { image in
      ImageRecord(
        id: "\(image.reference)@\(image.digest)",
        reference: image.reference,
        digest: image.digest,
        mediaType: image.descriptor.mediaType,
        compressedSizeBytes: image.descriptor.size
      )
    }

    let volumes = configurations.map { volume in
      VolumeRecord(
        id: volume.id,
        name: volume.name,
        driver: volume.driver,
        format: volume.format,
        source: volume.source,
        createdAt: volume.creationDate,
        sizeBytes: volume.sizeInBytes,
        isAnonymous: volume.isAnonymous
      )
    }

    let machines = machineSnapshots.map { machine in
      LinuxMachineRecord(
        id: machine.id,
        imageReference: machine.configuration.image.reference,
        platform: String(describing: machine.platform),
        state: RuntimeState(rawValue: machine.status.rawValue) ?? .unknown,
        ipAddress: machine.ipAddress,
        createdAt: machine.createdDate,
        startedAt: machine.startedDate,
        diskSizeBytes: machine.diskSize,
        cpuCount: machine.bootConfig.cpus,
        memoryDescription: String(describing: machine.bootConfig.memory),
        isInitialized: machine.initialized
      )
    }

    return ContainerInventory(
      system: system,
      containers: containers.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
      images: images.sorted {
        $0.reference.localizedStandardCompare($1.reference) == .orderedAscending
      },
      volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      machines: machines.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    )
  }

  func startContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status != .running else { return }

    var environment: [String: String] = [:]
    if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
      environment["SSH_AUTH_SOCK"] = socket
    }

    let process = try await containerClient.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: environment
    )
    try await process.start()
  }

  func stopContainer(id: String) async throws {
    try await containerClient.stop(id: id)
  }

  func deleteContainer(id: String) async throws {
    try await containerClient.delete(id: id)
  }

  func startMachine(id: String) async throws {
    _ = try await machineClient.boot(id: id)
  }

  func stopMachine(id: String) async throws {
    try await machineClient.stop(id: id)
  }

  func deleteMachine(id: String) async throws {
    try await machineClient.delete(id: id)
  }
}
