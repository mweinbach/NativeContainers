import ContainerAPIClient
import ContainerResource
import Foundation
import MachineAPIClient

actor AppleContainerService: ContainerManaging {
  private static let maximumLogBytes = 512 * 1_024

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

  func inspectContainer(id: String) async throws -> ContainerInspection {
    let snapshot = try await containerClient.get(id: id)
    async let diskUsageRequest = containerClient.diskUsage(id: id)
    async let logsRequest = readLogs(id: id)

    let statistics: ContainerStatistics?
    if snapshot.status == .running {
      let value = try await containerClient.stats(id: id)
      statistics = ContainerStatistics(
        memoryUsageBytes: value.memoryUsageBytes,
        memoryLimitBytes: value.memoryLimitBytes,
        cpuUsageMicroseconds: value.cpuUsageUsec,
        networkReceivedBytes: value.networkRxBytes,
        networkTransmittedBytes: value.networkTxBytes,
        blockReadBytes: value.blockReadBytes,
        blockWrittenBytes: value.blockWriteBytes,
        processCount: value.numProcesses
      )
    } else {
      statistics = nil
    }

    let (diskUsage, logs) = try await (diskUsageRequest, logsRequest)
    return ContainerInspection(
      diskUsageBytes: diskUsage,
      statistics: statistics,
      standardOutput: logs.standardOutput.text,
      bootLog: logs.boot.text,
      logsAreTruncated: logs.standardOutput.isTruncated || logs.boot.isTruncated
    )
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

  private func readLogs(id: String) async throws -> (
    standardOutput: (text: String, isTruncated: Bool),
    boot: (text: String, isTruncated: Bool)
  ) {
    let handles = try await containerClient.logs(id: id)
    defer {
      for handle in handles {
        try? handle.close()
      }
    }

    guard handles.count >= 2 else {
      return (("", false), ("", false))
    }
    return try (
      Self.readTail(from: handles[0], maximumBytes: Self.maximumLogBytes),
      Self.readTail(from: handles[1], maximumBytes: Self.maximumLogBytes)
    )
  }

  private static func readTail(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (text: String, isTruncated: Bool) {
    let length = try handle.seekToEnd()
    let maximumBytes = UInt64(maximumBytes)
    let isTruncated = length > maximumBytes
    try handle.seek(toOffset: isTruncated ? length - maximumBytes : 0)
    let data = try handle.readToEnd() ?? Data()
    return (String(decoding: data, as: UTF8.self), isTruncated)
  }
}
