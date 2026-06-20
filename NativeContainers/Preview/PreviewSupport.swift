import Foundation

extension AppModel {
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
          id: "api@sha256:1234",
          reference: "ghcr.io/example/api:latest",
          digest: "sha256:1234567890abcdef",
          mediaType: "application/vnd.oci.image.index.v1+json",
          compressedSizeBytes: 182_000_000
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
    return AppModel(
      containerService: PreviewContainerService(inventory: inventory),
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: true)
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
      virtualMachineLibrary: PreviewVirtualMachineLibrary(hasMachine: false)
    )
  }
}

private actor PreviewContainerService: ContainerManaging {
  let inventory: ContainerInventory

  init(inventory: ContainerInventory) {
    self.inventory = inventory
  }

  func loadInventory() async throws -> ContainerInventory { inventory }
  func startContainer(id: String) async throws {}
  func stopContainer(id: String) async throws {}
  func deleteContainer(id: String) async throws {}
  func startMachine(id: String) async throws {}
  func stopMachine(id: String) async throws {}
  func deleteMachine(id: String) async throws {}
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
