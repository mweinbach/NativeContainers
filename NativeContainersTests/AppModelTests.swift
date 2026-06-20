import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct AppModelTests {
  @Test
  func refreshPublishesContainerAndVirtualMachineInventories() async throws {
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "release",
        commit: "abc123",
        applicationRoot: URL(filePath: "/tmp/data"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [
        ContainerRecord(
          id: "web",
          imageReference: "example/web:latest",
          platform: "linux/arm64",
          state: .running,
          ipAddress: "192.168.64.2/24",
          createdAt: Date(timeIntervalSince1970: 1),
          startedAt: Date(timeIntervalSince1970: 2),
          cpuCount: 2,
          memoryBytes: VirtualMachineResources.bytesPerGiB,
          ports: []
        )
      ],
      images: [],
      volumes: [],
      machines: []
    )
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let manifest = try VirtualMachineManifest(name: "macOS", guest: .macOS, resources: resources)
    let containerService = MockContainerService(inventory: inventory)
    let library = MockVirtualMachineLibrary(manifests: [manifest])
    let model = AppModel(containerService: containerService, virtualMachineLibrary: library)

    await model.refresh()

    #expect(model.systemInfo == inventory.system)
    #expect(model.containers == inventory.containers)
    #expect(model.virtualMachines == [manifest])
    #expect(model.errorMessage == nil)
    #expect(model.lastRefresh != nil)
    #expect(!model.isRefreshing)
  }

  @Test
  func successfulMutationRefreshesInventory() async {
    let inventory = ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "release",
        commit: "abc123",
        applicationRoot: URL(filePath: "/tmp/data"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: [],
      images: [],
      volumes: [],
      machines: []
    )
    let service = MockContainerService(inventory: inventory)
    let model = AppModel(
      containerService: service,
      virtualMachineLibrary: MockVirtualMachineLibrary(manifests: [])
    )

    await model.startContainer(id: "web")

    #expect(await service.startedContainerIDs == ["web"])
    #expect(await service.loadCount == 1)
  }
}

private actor MockContainerService: ContainerManaging {
  let inventory: ContainerInventory
  private(set) var startedContainerIDs: [String] = []
  private(set) var loadCount = 0

  init(inventory: ContainerInventory) {
    self.inventory = inventory
  }

  func loadInventory() async throws -> ContainerInventory {
    loadCount += 1
    return inventory
  }

  func startContainer(id: String) async throws { startedContainerIDs.append(id) }
  func stopContainer(id: String) async throws {}
  func deleteContainer(id: String) async throws {}
  func startMachine(id: String) async throws {}
  func stopMachine(id: String) async throws {}
  func deleteMachine(id: String) async throws {}
}

private actor MockVirtualMachineLibrary: VirtualMachineLibraryProtocol {
  private var manifests: [VirtualMachineManifest]

  init(manifests: [VirtualMachineManifest]) {
    self.manifests = manifests
  }

  func list() async throws -> [VirtualMachineManifest] { manifests }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws -> VirtualMachineManifest {
    let manifest = try VirtualMachineManifest(name: name, guest: guest, resources: resources)
    manifests.append(manifest)
    return manifest
  }
}
