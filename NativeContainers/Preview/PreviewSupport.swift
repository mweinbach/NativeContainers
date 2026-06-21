import Foundation

extension AppModel {
  static var previewVirtualMachines: AppModel {
    let model = preview
    model.selection = .macOSVirtualMachines
    return model
  }

  static var previewASIFVirtualMachines: AppModel {
    let model = preview(diskFormat: .asif)
    model.selection = .macOSVirtualMachines
    return model
  }

  static var previewContainers: AppModel {
    let model = preview
    model.selection = .containers
    return model
  }

  static var preview: AppModel {
    preview(diskFormat: .raw)
  }

  private static func preview(
    diskFormat: VirtualMachineDiskImageFormat
  ) -> AppModel {
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
          ports: [],
          labels: [
            ComposeLabelKey.project: "sample-stack",
            ComposeLabelKey.service: "api",
            ComposeLabelKey.containerNumber: "1",
            ComposeLabelKey.workingDirectory: "/Users/example/Projects/sample-stack",
            ComposeLabelKey.configFiles: "/Users/example/Projects/sample-stack/compose.yaml",
            ComposeLabelKey.version: "2.38.1",
          ]
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
          ports: [],
          labels: [
            ComposeLabelKey.project: "sample-stack",
            ComposeLabelKey.service: "database",
            ComposeLabelKey.containerNumber: "1",
          ]
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
          allocatedBytes: 48_234_496,
          labels: [
            "com.example.purpose": "database",
            ComposeLabelKey.project: "sample-stack",
            ComposeLabelKey.volume: "postgres-data",
          ],
          options: ["size": "536870912B", "journal": "ordered"],
          isAnonymous: false,
          usedByContainerIDs: ["postgres"]
        ),
        VolumeRecord(
          id: "workspace",
          name: "workspace",
          driver: "local",
          format: "ext4",
          source: "/example/workspace",
          createdAt: now.addingTimeInterval(-43_200),
          sizeBytes: 1_073_741_824,
          allocatedBytes: 12_582_912,
          labels: ["com.example.purpose": "development"],
          options: ["size": "1073741824B", "journal": "ordered"],
          isAnonymous: false,
          usedByContainerIDs: []
        ),
      ],
      networks: [
        NetworkRecord(
          id: "default",
          name: "default",
          mode: .nat,
          createdAt: now.addingTimeInterval(-172_800),
          configuredIPv4Subnet: nil,
          configuredIPv6Subnet: nil,
          assignedIPv4Subnet: "192.168.64.0/24",
          ipv4Gateway: "192.168.64.1",
          assignedIPv6Subnet: nil,
          labels: ["com.apple.container.resource.role": "builtin"],
          plugin: "container-network-vmnet",
          options: [:],
          isBuiltin: true,
          usedByContainerIDs: ["api", "postgres"]
        ),
        NetworkRecord(
          id: "backend",
          name: "backend",
          mode: .hostOnly,
          createdAt: now.addingTimeInterval(-86_400),
          configuredIPv4Subnet: "192.168.100.0/24",
          configuredIPv6Subnet: nil,
          assignedIPv4Subnet: "192.168.100.0/24",
          ipv4Gateway: "192.168.100.1",
          assignedIPv6Subnet: nil,
          labels: [
            "com.example.purpose": "internal",
            ComposeLabelKey.project: "sample-stack",
            ComposeLabelKey.network: "backend",
          ],
          plugin: "container-network-vmnet",
          options: [:],
          isBuiltin: false,
          usedByContainerIDs: []
        ),
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
    var macVM = try! VirtualMachineManifest(
      name: "macOS Sequoia",
      guest: .macOS,
      installState: .stopped,
      resources: machineResources
    )
    if diskFormat == .asif {
      macVM.markDiskImageReplaced(
        to: "Installed/Disk.asif",
        format: .asif
      )
    }
    let sharedDirectories = PreviewMacVirtualMachineSharedDirectoryService(
      initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration(
        revision: 2,
        directories: [
          MacVirtualMachineSharedDirectory(
            id: UUID(),
            guestName: "Projects",
            bookmarkData: Data(),
            lastKnownPath: "/Users/example/Projects",
            sourceIdentity: MacVirtualMachineSharedDirectorySourceIdentity(
              device: 1,
              inode: 42
            ),
            readOnly: false
          ),
          MacVirtualMachineSharedDirectory(
            id: UUID(),
            guestName: "Reference",
            bookmarkData: Data(),
            lastKnownPath: "/Users/example/Documents/Reference",
            sourceIdentity: MacVirtualMachineSharedDirectorySourceIdentity(
              device: 1,
              inode: 84
            ),
            readOnly: true
          ),
        ]
      )
    )
    let service = PreviewContainerService(inventory: inventory)
    return AppModel(
      containerService: service,
      machineService: service,
      registryService: PreviewRegistryService(),
      dockerCompatibilityService: PreviewDockerCompatibilityService(),
      dockerComposeClientService: PreviewDockerComposeClientService(),
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: true),
      virtualMachineSharedDirectories: sharedDirectories,
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
      networks: [],
      machines: []
    )
    let service = PreviewContainerService(inventory: inventory)
    return AppModel(
      containerService: service,
      machineService: service,
      registryService: PreviewRegistryService(),
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: false),
      initialInventory: inventory
    )
  }
}

private actor PreviewRegistryService: RegistryManaging {
  func listRegistries() async throws -> [RegistryCredentialRecord] {
    [
      RegistryCredentialRecord(
        hostname: "ghcr.io",
        username: "example",
        createdAt: Date().addingTimeInterval(-86_400),
        modifiedAt: Date().addingTimeInterval(-3_600)
      )
    ]
  }
}

private actor PreviewDockerCompatibilityService: DockerCompatibilityManaging {
  private let socketURL = URL(filePath: "/Users/example/.socktainer/container.sock")

  func snapshot() async -> DockerCompatibilitySnapshot {
    DockerCompatibilitySnapshot(
      release: .pinned,
      installation: .ready(version: "1.0.0"),
      appleContainer: .compatible(version: "1.0.0"),
      runtime: .running(processID: 4242),
      dockerContext: DockerContextSnapshot(
        state: .ready,
        activeContext: "orbstack",
        environmentOverrides: []
      ),
      socketURL: socketURL
    )
  }

  func installPinnedBridge() async throws {}
  func startBridge() async throws {}
  func stopBridge() async throws {}
  func forceStopBridge() async throws {}
  func removeStaleSocket() async throws {}
  func createOrRepairDockerContext() async throws {}
}

private actor PreviewDockerComposeClientService: DockerComposeClientInstalling {
  nonisolated let release = DockerComposeRelease.pinned
  nonisolated let executableURL = URL(
    filePath:
      "/Users/example/Library/Application Support/NativeContainers/Compatibility/DockerCompose/5.1.4/docker-compose"
  )
  nonisolated let provenanceURL = URL(
    filePath:
      "/Users/example/Library/Application Support/NativeContainers/Compatibility/DockerCompose/5.1.4/provenance.json"
  )

  func snapshot() async -> DockerComposeClientSnapshot {
    DockerComposeClientSnapshot(
      release: release,
      installation: .ready(version: release.version),
      executableURL: executableURL,
      provenanceURL: provenanceURL
    )
  }

  func installationState() async -> DockerComposeClientInstallationState {
    .ready(version: release.version)
  }

  func verifiedExecutableURL() async throws -> URL {
    executableURL
  }

  func install() async throws {}
}

private actor PreviewContainerService: ContainerManaging, MachineManaging {
  let inventory: ContainerInventory

  init(inventory: ContainerInventory) {
    self.inventory = inventory
  }

  func loadInventory() async throws -> ContainerInventory { inventory }

  func loadContainerAttachmentEnvironment() async -> ContainerAttachmentEnvironment {
    ContainerAttachmentEnvironment(
      publishedSocketRootPath:
        "/Users/example/Library/Application Support/NativeContainers/PublishedSockets",
      hostAccess: ContainerHostAccessCatalog(
        configurations: [
          try! ContainerHostAccessConfiguration(
            domain: "host.container.internal",
            redirectIPv4Address: "203.0.113.113"
          )
        ],
        warnings: []
      )
    )
  }

  func prepareImagePull(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport,
    unpackAfterPull: Bool,
    maxConcurrentDownloads: Int
  ) async throws -> ImagePullPlan {
    ImagePullPlan(
      normalizedReference: reference,
      registryHost: "docker.io",
      existingDigest: nil,
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: transport,
      resolvedTransport: .https,
      unpackAfterPull: unpackAfterPull,
      maxConcurrentDownloads: maxConcurrentDownloads,
      generatedAt: Date()
    )
  }
  func pullImage(
    _ plan: ImagePullPlan,
    authorization: ImagePullAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws -> ImagePullResult {
    await progress(ContainerOperationProgress(phase: .completed, message: "Image ready"))
    return ImagePullResult(
      reference: plan.normalizedReference,
      digest: "sha256:preview",
      replacedDigest: plan.existingDigest,
      unpackOutcome: plan.unpackAfterPull
        ? ImageUnpackOutcome(
          platforms: [
            ImagePlatformUnpackOutcome(
              platform: OCIPlatformValue(
                os: "linux",
                architecture: "arm64",
                variant: "v8"
              ),
              state: .created
            )
          ]
        ) : nil
    )
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
  func prepareImagePush(
    reference: String,
    platform: ImagePlatformRequest,
    transport: RegistryTransport
  ) async throws -> ImagePushPlan {
    ImagePushPlan(
      reference: reference,
      displayReference: reference,
      sourceDigest: "sha256:1234567890abcdef",
      registryHost: "ghcr.io",
      platform: .specific(
        OCIPlatformValue(os: "linux", architecture: "arm64", variant: "v8")
      ),
      requestedTransport: transport,
      resolvedTransport: .https,
      generatedAt: Date()
    )
  }
  func pushImage(
    _ plan: ImagePushPlan,
    authorization: ImagePushAuthorization,
    progress: @escaping ContainerProgressHandler
  ) async throws {
    await progress(ContainerOperationProgress(phase: .completed, message: "Image pushed"))
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
  func createMachine(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineCreationResult {
    await progress(
      ContainerOperationProgress(phase: .completed, message: "Linux machine ready")
    )
    return LinuxMachineCreationResult(
      identity: LinuxMachineIdentity(
        id: request.name,
        imageReference: request.imageReference,
        platform: "linux/\(request.architecture.rawValue)",
        createdAt: Date()
      ),
      state: request.startAfterCreation ? .running : .stopped,
      isInitialized: request.startAfterCreation
    )
  }
  func startMachine(_ target: LinuxMachineIdentity) async throws {}
  func stopMachine(_ target: LinuxMachineIdentity) async throws {}
  func forceStopMachine(
    _ target: LinuxMachineIdentity,
    authorization: LinuxMachineForceStopAuthorization
  ) async throws {}
  func deleteMachine(_ target: LinuxMachineIdentity) async throws {}
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

private actor PreviewMacVirtualMachineSharedDirectoryService:
  MacVirtualMachineSharedDirectoryManaging
{
  private var current: MacVirtualMachineSharedDirectoryConfiguration

  init(initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration) {
    current = initialConfiguration
  }

  func configuration(
    id: UUID
  ) -> MacVirtualMachineSharedDirectoryConfiguration {
    current
  }

  func add(
    to machineID: UUID,
    request: MacVirtualMachineSharedDirectoryRequest
  ) -> MacVirtualMachineSharedDirectoryConfiguration {
    let next = MacVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: request.guestName,
      bookmarkData: Data(),
      lastKnownPath: request.sourceURL.path(percentEncoded: false),
      sourceIdentity: MacVirtualMachineSharedDirectorySourceIdentity(
        device: 1,
        inode: UInt64(current.directories.count + 100)
      ),
      readOnly: request.readOnly
    )
    current = MacVirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories + [next]
    )
    return current
  }

  func remove(
    from machineID: UUID,
    sharedDirectoryID: UUID
  ) -> MacVirtualMachineSharedDirectoryConfiguration {
    current = MacVirtualMachineSharedDirectoryConfiguration(
      revision: current.revision + 1,
      directories: current.directories.filter { $0.id != sharedDirectoryID }
    )
    return current
  }
}
