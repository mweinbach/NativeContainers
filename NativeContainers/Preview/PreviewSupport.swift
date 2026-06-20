import Foundation

extension AppModel {
  static var previewVirtualMachines: AppModel {
    let model = preview
    model.selection = .macOSVirtualMachines
    return model
  }

  static var previewContainers: AppModel {
    let model = preview
    model.selection = .containers
    return model
  }

  static var preview: AppModel {
    let now = Date()
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "container-apiserver version 1.0.0",
        build: "release",
        commit: "ee848e3",
        applicationRoot: URL(
          filePath: "/Users/example/Library/Application Support/com.apple.container"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [
        ContainerRecord(
          id: "api",
          imageReference: "ghcr.io/example/api:latest",
          platform: "linux/arm64",
          state: .running,
          ipAddress: "192.168.64.3/24",
          createdAt: now.addingTimeInterval(-7_200),
          startedAt: now.addingTimeInterval(-3_600),
          cpuCount: 4,
          memoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
          ports: []
        ),
        ContainerRecord(
          id: "postgres",
          imageReference: "docker.io/library/postgres:17",
          platform: "linux/arm64",
          state: .stopped,
          ipAddress: nil,
          createdAt: now.addingTimeInterval(-86_400),
          startedAt: nil,
          cpuCount: 2,
          memoryBytes: VirtualMachineResources.bytesPerGiB,
          ports: []
        ),
      ],
      images: [
        ImageRecord(
          reference: "ghcr.io/example/api:latest",
          digest: "sha256:1234567890abcdef",
          mediaType: "application/vnd.oci.image.index.v1+json",
          indexSizeBytes: 1_024
        )
      ],
      volumes: [
        VolumeRecord(
          id: "postgres-data",
          name: "postgres-data",
          driver: "local",
          format: "ext4",
          source: "/example/postgres-data",
          createdAt: now.addingTimeInterval(-86_400),
          sizeBytes: 536_870_912,
          isAnonymous: false
        )
      ],
      machines: [
        LinuxMachineRecord(
          id: "dev",
          imageReference: "ubuntu:24.04",
          platform: "linux/arm64",
          state: .running,
          ipAddress: "192.168.64.5",
          createdAt: now.addingTimeInterval(-172_800),
          startedAt: now.addingTimeInterval(-1_200),
          diskSizeBytes: 20 * VirtualMachineResources.bytesPerGiB,
          cpuCount: 6,
          memoryDescription: "8 GiB",
          isInitialized: true
        )
      ]
    )
    let machineResources = try! VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let macVM = try! VirtualMachineManifest(
      name: "macOS Sequoia",
      guest: .macOS,
      resources: machineResources
    )
    return AppModel(
      containerService: PreviewContainerService(inventory: inventory),
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: true),
      initialInventory: inventory,
      initialVirtualMachines: [macVM]
    )
  }

  static var previewEmpty: AppModel {
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "container-apiserver version 1.0.0",
        build: "release",
        commit: "ee848e3",
        applicationRoot: URL(filePath: "/tmp/container"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [],
      images: [],
      volumes: [],
      machines: []
    )
    return AppModel(
      containerService: PreviewContainerService(inventory: inventory),
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: false),
      initialInventory: inventory
    )
  }
}

private actor PreviewContainerService: ContainerManaging {
  let inventory: ContainerInventory

  init(inventory: ContainerInventory) {
    self.inventory = inventory
  }

  func loadInventory() async throws -> ContainerInventory { inventory }
  func pullImage(
    reference: String,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    await progress(ContainerOperationProgress(phase: .completed, message: "Image ready"))
  }
  func inspectImage(reference: String) async throws -> ImageInspection {
    ImageInspection(
      reference: reference,
      displayReference: "ghcr.io/example/api:latest",
      digest: "sha256:1234567890abcdef",
      mediaType: "application/vnd.oci.image.index.v1+json",
      indexSizeBytes: 1_024,
      createdAt: Date().addingTimeInterval(-7_200),
      variants: [
        ImageVariantInspection(
          platform: "linux/arm64",
          os: "linux",
          architecture: "arm64",
          variant: nil,
          manifestDigest: "sha256:arm64manifest",
          sizeBytes: 182_000_000,
          createdAt: Date().addingTimeInterval(-7_200),
          author: "Example Team",
          user: "1000:1000",
          workingDirectory: "/app",
          entrypoint: ["/app/server"],
          command: ["--port", "8080"],
          environment: ["NODE_ENV=production", "PORT=8080"],
          labels: ["org.opencontainers.image.source": "https://github.com/example/api"],
          layerCount: 8
        )
      ],
      aliases: ["ghcr.io/example/api:stable"],
      usedByContainerIDs: ["api"],
      warnings: []
    )
  }
  func prepareImageTag(source: String, target: String) async throws -> ImageTagPlan {
    ImageTagPlan(
      sourceReference: source,
      sourceDigest: "sha256:1234567890abcdef",
      targetReference: target,
      displayTargetReference: target,
      replacedDigest: nil
    )
  }
  func tagImage(_ plan: ImageTagPlan, replacingExisting: Bool) async throws {}
  func prepareImageDeletion(reference: String) async throws -> ImageDeletionPlan {
    ImageDeletionPlan(
      reference: reference,
      digest: "sha256:1234567890abcdef",
      aliases: ["ghcr.io/example/api:stable"],
      usedByContainerIDs: ["api"],
      isInfrastructureImage: false
    )
  }
  func deleteImage(_ plan: ImageDeletionPlan) async throws -> ImageCleanupResult {
    ImageCleanupResult(
      removedReferences: [plan.reference],
      failedReferences: [],
      removedBlobDigests: [],
      reclaimedBytes: 182_000_000
    )
  }
  func prepareImagePrune(mode: ImagePruneMode) async throws -> ImagePrunePlan {
    ImagePrunePlan(
      mode: mode,
      generatedAt: Date(),
      candidates: [],
      estimatedReclaimableBytes: mode == .allUnused ? 0 : nil
    )
  }
  func pruneImages(_ plan: ImagePrunePlan) async throws -> ImageCleanupResult {
    ImageCleanupResult(
      removedReferences: plan.candidates.map(\.reference),
      failedReferences: [],
      removedBlobDigests: [],
      reclaimedBytes: 0
    )
  }
  func createContainer(
    request: ContainerCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    await progress(ContainerOperationProgress(phase: .completed, message: "Container ready"))
  }
  func inspectContainer(id: String) async throws -> ContainerInspection {
    ContainerInspection(
      diskUsageBytes: 286_261_248,
      statistics: ContainerStatistics(
        memoryUsageBytes: 187_695_104,
        memoryLimitBytes: 2 * VirtualMachineResources.bytesPerGiB,
        cpuUsageMicroseconds: 4_820_000,
        networkReceivedBytes: 8_421_912,
        networkTransmittedBytes: 1_928_140,
        blockReadBytes: 42_991_616,
        blockWrittenBytes: 9_437_184,
        processCount: 7
      ),
      standardOutput: "Server listening on http://0.0.0.0:8080\nConnected to postgres\n",
      bootLog: "vminitd: container runtime ready\n",
      logsAreTruncated: false
    )
  }
  func sampleContainer(id: String) async throws -> ContainerStatistics? {
    (try await inspectContainer(id: id)).statistics
  }
  func loadContainerLogs(id: String) async throws -> ContainerLogsSnapshot {
    let inspection = try await inspectContainer(id: id)
    return ContainerLogsSnapshot(
      standardOutput: inspection.standardOutput,
      bootLog: inspection.bootLog,
      logsAreTruncated: inspection.logsAreTruncated
    )
  }
  func startContainer(id: String) async throws {}
  func stopContainer(id: String) async throws {}
  func restartContainer(id: String) async throws {}
  func forceStopContainer(id: String) async throws {}
  func deleteContainer(id: String) async throws {}
  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    ContainerCommandResult(
      exitCode: 0,
      standardOutput: "hello from \(id)\n",
      standardError: "",
      outputWasTruncated: false,
      duration: .milliseconds(42)
    )
  }
  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    PreviewContainerTerminalSession(containerID: id)
  }
  func copyIntoContainer(id: String, source: URL, destination: String) async throws {}
  func copyFromContainer(id: String, source: String, destination: URL) async throws {}
  func startMachine(id: String) async throws {}
  func stopMachine(id: String) async throws {}
  func deleteMachine(id: String) async throws {}
}

private actor PreviewContainerTerminalSession: ContainerTerminalSession {
  nonisolated let output: AsyncStream<Data>

  private let continuation: AsyncStream<Data>.Continuation
  private var lifecycle = ContainerTerminalLifecycle.running
  private var retainedOutput: Data

  init(containerID: String) {
    let pair = AsyncStream.makeStream(of: Data.self)
    output = pair.stream
    continuation = pair.continuation
    retainedOutput = Data(
      "\u{1B}[1;34mNativeContainers\u{1B}[0m · \(containerID)\r\n\u{1B}[32m/ #\u{1B}[0m ".utf8
    )
    continuation.yield(retainedOutput)
  }

  func sendInput(_ data: Data) {
    continuation.yield(data)
  }

  func resize(to size: ContainerTerminalSize) {}

  func sendSignal(_ signal: ContainerTerminalSignal) {}

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: lifecycle,
      retainedOutput: retainedOutput,
      outputWasTruncated: false
    )
  }

  func wait() async throws -> Int32 {
    while lifecycle == .running {
      try await Task.sleep(for: .seconds(1))
    }
    return 0
  }

  func close() {
    lifecycle = .closed
    continuation.finish()
  }
}

private actor PreviewVirtualMachineLibrary: VirtualMachineLibraryProtocol {
  let hasMachine: Bool

  init(hasMachine: Bool) {
    self.hasMachine = hasMachine
  }

  func list() async throws -> [VirtualMachineManifest] {
    guard hasMachine else { return [] }
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    return [try VirtualMachineManifest(name: "macOS Sequoia", guest: .macOS, resources: resources)]
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest {
    try VirtualMachineManifest(name: name, guest: guest, resources: resources)
  }
}
