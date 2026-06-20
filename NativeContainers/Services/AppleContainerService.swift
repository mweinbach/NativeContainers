import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Darwin
import Foundation
import MachineAPIClient
import SystemPackage
import TerminalProgress

actor AppleContainerService: ContainerManaging {
  private static let maximumLogBytes = 512 * 1_024
  private static let maximumCommandOutputBytes = 1_024 * 1_024
  private static let creationOperationLabel = "com.nativecontainers.creation-operation"

  private let containerClient = ContainerClient()
  private let machineClient = MachineClient()
  private let terminalProcessLauncher: any ContainerTerminalProcessLaunching

  init(
    terminalProcessLauncher: any ContainerTerminalProcessLaunching =
      AppleContainerTerminalProcessLauncher()
  ) {
    self.terminalProcessLauncher = terminalProcessLauncher
  }

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
    if snapshot.configuration.ssh,
      let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    {
      environment["SSH_AUTH_SOCK"] = socket
    }

    let process = try await containerClient.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: environment
    )
    try await process.start()
  }

  func pullImage(
    reference: String,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else {
      throw ContainerCreationValidationError.missingImageReference
    }

    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .fetchingImage, message: "Fetching image")
    let systemConfiguration = try await loadSystemConfiguration()
    _ = try await ClientImage.pull(
      reference: reference,
      platform: .current,
      containerSystemConfig: systemConfiguration,
      progressUpdate: { events in
        await relay.consume(events)
      }
    )
    await relay.emit(phase: .completed, message: "Image ready")
  }

  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .preparing, message: "Preparing container")
    try Utility.validEntityName(request.name)

    if (try? await containerClient.get(id: request.name)) != nil {
      throw AppleContainerServiceError.containerAlreadyExists(request.name)
    }

    let systemConfiguration = try await loadSystemConfiguration()
    let processFlags = Flags.Process(
      cwd: request.workingDirectory,
      env: request.environment.map(\.entry),
      envFile: [],
      gid: nil,
      interactive: false,
      tty: false,
      uid: nil,
      ulimits: [],
      user: nil
    )
    let resourceFlags = Flags.Resource(
      cpus: Int64(request.cpuCount),
      memory: "\(request.memoryBytes / ContainerCreationRequest.bytesPerMiB)MiB"
    )
    let managementFlags = Flags.Management(
      arch: request.architecture.rawValue,
      capAdd: [],
      capDrop: [],
      cidfile: "",
      detach: true,
      dns: Flags.DNS(),
      dnsDisabled: false,
      entrypoint: nil,
      initImage: nil,
      kernel: nil,
      labels: ["\(Self.creationOperationLabel)=\(request.operationID.uuidString)"],
      mounts: [],
      name: request.name,
      networks: [],
      os: "linux",
      platform: nil,
      publishPorts: request.publishedPorts.map(\.appleSpecification),
      publishSockets: [],
      readOnly: request.readOnlyRootFilesystem,
      remove: request.removeWhenStopped,
      rosetta: false,
      runtime: nil,
      ssh: request.forwardSSHAgent,
      shmSize: nil,
      tmpFs: [],
      useInit: request.useInitProcess,
      virtualization: false,
      volumes: []
    )
    try managementFlags.validate()
    let appleProgress: ProgressUpdateHandler = { events in
      await relay.consume(events)
    }
    let requestedPlatform = Parser.platform(os: "linux", arch: request.architecture.rawValue)
    await relay.emit(phase: .fetchingImage, message: "Checking image platform")
    let image: ClientImage
    if let localImage = try? await ClientImage.get(
      reference: request.imageReference,
      containerSystemConfig: systemConfiguration
    ) {
      do {
        _ = try await localImage.config(for: requestedPlatform)
        image = localImage
      } catch {
        image = try await ClientImage.pull(
          reference: request.imageReference,
          platform: requestedPlatform,
          containerSystemConfig: systemConfiguration,
          progressUpdate: appleProgress
        )
      }
    } else {
      image = try await ClientImage.fetch(
        reference: request.imageReference,
        platform: requestedPlatform,
        containerSystemConfig: systemConfiguration,
        progressUpdate: appleProgress
      )
    }

    await relay.emit(phase: .unpackingImage, message: "Unpacking image")
    _ = try await image.getCreateSnapshot(
      platform: requestedPlatform,
      progressUpdate: appleProgress
    )

    await relay.emit(phase: .fetchingKernel, message: "Preparing Linux kernel")
    let kernel = try await ClientKernel.getDefaultKernel(for: .current)

    await relay.emit(phase: .fetchingInitImage, message: "Fetching runtime image")
    let initImage = try await ClientImage.fetch(
      reference: systemConfiguration.vminit.image,
      platform: .current,
      containerSystemConfig: systemConfiguration,
      progressUpdate: appleProgress
    )
    await relay.emit(phase: .unpackingInitImage, message: "Unpacking runtime image")
    _ = try await initImage.getCreateSnapshot(
      platform: .current,
      progressUpdate: appleProgress
    )

    let imageConfiguration = try await image.config(for: requestedPlatform).config
    let processConfiguration = try Parser.process(
      arguments: request.arguments,
      processFlags: processFlags,
      managementFlags: managementFlags,
      config: imageConfiguration
    )
    var configuration = ContainerConfiguration(
      id: request.name,
      image: image.description,
      process: processConfiguration
    )
    configuration.platform = requestedPlatform
    configuration.resources = try Parser.resources(
      cpus: resourceFlags.cpus,
      memory: resourceFlags.memory,
      defaultCPUs: systemConfiguration.container.cpus,
      defaultMemory: systemConfiguration.container.memory
    )
    configuration.rosetta = request.architecture == .amd64
    configuration.labels = [Self.creationOperationLabel: request.operationID.uuidString]
    configuration.publishedPorts = try Parser.publishPorts(
      request.publishedPorts.map(\.appleSpecification)
    )
    guard configuration.publishedPorts.count <= 64 else {
      throw ContainerCreationValidationError.tooManyPortPublications
    }
    guard !configuration.publishedPorts.hasOverlaps() else {
      throw ContainerCreationValidationError.duplicatePortPublication
    }
    configuration.ssh = request.forwardSSHAgent
    configuration.readOnly = request.readOnlyRootFilesystem
    configuration.useInit = request.useInitProcess
    configuration.stopSignal = imageConfiguration?.stopSignal

    guard let builtinNetwork = try await NetworkClient().builtin else {
      throw AppleContainerServiceError.builtinNetworkUnavailable
    }
    let hostname = systemConfiguration.dns.domain.map { "\(request.name).\($0)." } ?? request.name
    configuration.networks = [
      AttachmentConfiguration(
        network: builtinNetwork.id,
        options: AttachmentOptions(hostname: hostname, macAddress: nil, mtu: 1_280)
      )
    ]
    configuration.dns = .init(
      nameservers: [],
      domain: systemConfiguration.dns.domain,
      searchDomains: [],
      options: []
    )

    await relay.emit(phase: .creating, message: "Creating container")
    do {
      try await containerClient.create(
        configuration: configuration,
        options: ContainerCreateOptions(autoRemove: request.removeWhenStopped),
        kernel: kernel
      )
    } catch {
      let reconciledSnapshot = try? await containerClient.get(id: request.name)
      guard
        reconciledSnapshot?.configuration.labels[Self.creationOperationLabel]
          == request.operationID.uuidString
      else {
        throw error
      }
    }

    if request.startAfterCreation {
      await relay.emit(phase: .starting, message: "Starting container")
      do {
        try await startContainer(id: request.name)
      } catch {
        try? await containerClient.stop(id: request.name)
        try? await containerClient.delete(id: request.name)
        throw error
      }
    }
    await relay.emit(phase: .completed, message: "Container ready")
  }

  func inspectContainer(id: String) async throws -> ContainerInspection {
    let snapshot = try await containerClient.get(id: id)
    async let diskUsageRequest = containerClient.diskUsage(id: id)
    async let logsRequest = loadContainerLogs(id: id)

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
      standardOutput: logs.standardOutput,
      bootLog: logs.bootLog,
      logsAreTruncated: logs.logsAreTruncated
    )
  }

  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else { return nil }
    let value = try await containerClient.stats(id: id)
    return ContainerStatistics(
      memoryUsageBytes: value.memoryUsageBytes,
      memoryLimitBytes: value.memoryLimitBytes,
      cpuUsageMicroseconds: value.cpuUsageUsec,
      networkReceivedBytes: value.networkRxBytes,
      networkTransmittedBytes: value.networkTxBytes,
      blockReadBytes: value.blockReadBytes,
      blockWrittenBytes: value.blockWriteBytes,
      processCount: value.numProcesses
    )
  }

  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    let logs = try await readLogs(id: id)
    return ContainerLogsSnapshot(
      standardOutput: logs.standardOutput.text,
      bootLog: logs.boot.text,
      logsAreTruncated: logs.standardOutput.isTruncated || logs.boot.isTruncated
    )
  }

  func stopContainer(id: String) async throws {
    try await containerClient.stop(
      id: id,
      opts: ContainerStopOptions(timeoutInSeconds: 5, signal: nil)
    )
  }

  func restartContainer(id: String) async throws {
    let snapshot = try await containerClient.get(id: id)
    if snapshot.status == .running {
      try await stopContainer(id: id)
    }
    try await startContainer(id: id)
  }

  func forceStopContainer(id: String) async throws {
    try await containerClient.kill(id: id, signal: "KILL")
  }

  func deleteContainer(id: String) async throws {
    try await containerClient.delete(id: id)
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else {
      throw ContainerToolValidationError.containerNotRunning(id)
    }

    var configuration = snapshot.configuration.initProcess
    configuration.executable = request.executable
    configuration.arguments = request.arguments
    configuration.terminal = false
    configuration.environment = try Parser.allEnv(
      imageEnvs: configuration.environment,
      envFiles: [],
      envs: request.environment.map(\.entry)
    )
    if let workingDirectory = request.workingDirectory {
      configuration.workingDirectory = workingDirectory
    }

    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    let process = try await containerClient.createProcess(
      containerId: id,
      processId: UUID().uuidString.lowercased(),
      configuration: configuration,
      stdio: [nil, standardOutputPipe.fileHandleForWriting, standardErrorPipe.fileHandleForWriting]
    )
    let standardOutputTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardOutputPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let standardErrorTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardErrorPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
      try await process.start()
      try standardOutputPipe.fileHandleForWriting.close()
      try standardErrorPipe.fileHandleForWriting.close()
      let exitCode = try await Self.wait(
        for: process,
        timeoutSeconds: request.timeoutSeconds
      )
      let standardOutput = try await standardOutputTask.value
      let standardError = try await standardErrorTask.value
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      return ContainerCommandResult(
        exitCode: exitCode,
        standardOutput: String(decoding: standardOutput.data, as: UTF8.self),
        standardError: String(decoding: standardError.data, as: UTF8.self),
        outputWasTruncated: standardOutput.isTruncated || standardError.isTruncated,
        duration: startedAt.duration(to: clock.now)
      )
    } catch {
      try? await process.kill(SIGKILL)
      try? standardOutputPipe.fileHandleForWriting.close()
      try? standardErrorPipe.fileHandleForWriting.close()
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      standardOutputTask.cancel()
      standardErrorTask.cancel()
      throw error
    }
  }

  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw ContainerTerminalError.invalidContainerIdentifier
    }

    let transport = PipeContainerTerminalTransport()
    do {
      let process = try await terminalProcessLauncher.makeProcess(
        containerID: id,
        request: request,
        standardInput: transport.childStandardInput,
        standardOutput: transport.childStandardOutput
      )

      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: request.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: request.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }

  func copyIntoContainer(id: String, source: URL, destination: String) async throws {
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
      throw ContainerToolValidationError.invalidLocalURL
    }
    try await containerClient.copyIn(
      id: id,
      source: source.path(percentEncoded: false),
      destination: destination,
      createParents: true
    )
  }

  func copyFromContainer(id: String, source: String, destination: URL) async throws {
    var destination = destination.standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(
      atPath: destination.path(percentEncoded: false),
      isDirectory: &isDirectory
    ), isDirectory.boolValue {
      destination.append(path: URL(filePath: source).lastPathComponent)
    }
    try await containerClient.copyOut(
      id: id,
      source: source,
      destination: destination.path(percentEncoded: false),
      createParents: true
    )
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

  private static func wait(
    for process: any ClientProcess,
    timeoutSeconds: Int
  ) async throws -> Int32 {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          try await process.wait()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(timeoutSeconds))
          try? await process.kill(SIGKILL)
          throw ContainerToolValidationError.commandTimedOut(timeoutSeconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw CancellationError()
        }
        return result
      }
    } onCancel: {
      Task {
        try? await process.kill(SIGKILL)
      }
    }
  }

  private static func readBoundedOutput(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (data: Data, isTruncated: Bool) {
    var result = Data()
    var isTruncated = false
    while !Task.isCancelled {
      guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
      if chunk.count >= maximumBytes {
        result = Data(chunk.suffix(maximumBytes))
        isTruncated = true
      } else {
        let excess = result.count + chunk.count - maximumBytes
        if excess > 0 {
          result.removeFirst(excess)
          isTruncated = true
        }
        result.append(chunk)
      }
    }
    return (result, isTruncated)
  }

  private func loadSystemConfiguration() async throws -> ContainerSystemConfig {
    let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
    let applicationRoot = FilePath(health.appRoot.path(percentEncoded: false))
    let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
    return try await ConfigurationLoader.load(
      configurationFiles: [
        ConfigurationLoader.configurationFile(in: applicationRoot, of: .appRoot),
        ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
      ]
    )
  }
}

private enum AppleContainerServiceError: LocalizedError {
  case containerAlreadyExists(String)
  case builtinNetworkUnavailable

  var errorDescription: String? {
    switch self {
    case .containerAlreadyExists(let name):
      "A container named “\(name)” already exists."
    case .builtinNetworkUnavailable:
      "Apple’s built-in container network is unavailable."
    }
  }
}

private actor AppleContainerProgressRelay {
  private let handler: ContainerProgressHandler
  private var phase: ContainerOperationProgress.Phase = .preparing
  private var message = "Preparing"
  private var submessage: String?
  private var completedItems = 0
  private var totalItems = 0
  private var transferredBytes: Int64 = 0
  private var totalBytes: Int64 = 0

  init(handler: @escaping ContainerProgressHandler) {
    self.handler = handler
  }

  func emit(phase: ContainerOperationProgress.Phase, message: String) async {
    self.phase = phase
    self.message = message
    submessage = nil
    completedItems = 0
    totalItems = 0
    transferredBytes = 0
    totalBytes = 0
    await publish()
  }

  func consume(_ events: [ProgressUpdateEvent]) async {
    for event in events {
      switch event {
      case .setDescription(let value):
        phase = Self.phase(for: value)
        message = value
        submessage = nil
        completedItems = 0
        totalItems = 0
        transferredBytes = 0
        totalBytes = 0
      case .setSubDescription(let value):
        submessage = value
      case .addItems(let value):
        completedItems += value
      case .setItems(let value):
        completedItems = value
      case .addTotalItems(let value):
        totalItems += value
      case .setTotalItems(let value):
        totalItems = value
      case .addSize(let value):
        transferredBytes += value
      case .setSize(let value):
        transferredBytes = value
      case .addTotalSize(let value):
        totalBytes += value
      case .setTotalSize(let value):
        totalBytes = value
      case .custom(let value):
        submessage = value
      case .addTasks, .setTasks, .addTotalTasks, .setTotalTasks, .setItemsName:
        break
      }
    }
    await publish()
  }

  private func publish() async {
    let displayMessage = submessage.map { "\(message) — \($0)" } ?? message
    await handler(
      ContainerOperationProgress(
        phase: phase,
        message: displayMessage,
        completedItems: max(completedItems, 0),
        totalItems: max(totalItems, 0),
        transferredBytes: max(transferredBytes, 0),
        totalBytes: max(totalBytes, 0)
      )
    )
  }

  private static func phase(for description: String) -> ContainerOperationProgress.Phase {
    switch description.lowercased() {
    case let value where value.contains("unpack") && value.contains("init"):
      .unpackingInitImage
    case let value where value.contains("fetch") && value.contains("init"):
      .fetchingInitImage
    case let value where value.contains("unpack"):
      .unpackingImage
    case let value where value.contains("kernel"):
      .fetchingKernel
    case let value where value.contains("fetch") || value.contains("pull"):
      .fetchingImage
    default:
      .preparing
    }
  }
}
