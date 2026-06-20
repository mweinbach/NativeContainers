import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  var selection: SidebarDestination = .overview

  private(set) var systemInfo: ContainerSystemInfo?
  private(set) var containers: [ContainerRecord] = []
  private(set) var images: [ImageRecord] = []
  private(set) var volumes: [VolumeRecord] = []
  private(set) var linuxMachines: [LinuxMachineRecord] = []
  private(set) var virtualMachines: [VirtualMachineManifest] = []
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?
  private(set) var errorMessage: String?

  private let containerService: any ContainerManaging
  private let virtualMachineLibrary: any VirtualMachineLibraryProtocol
  private var hasLoaded = false

  init(
    containerService: any ContainerManaging = AppleContainerService(),
    virtualMachineLibrary: any VirtualMachineLibraryProtocol = VirtualMachineLibrary(),
    initialInventory: ContainerInventory? = nil,
    initialVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.containerService = containerService
    self.virtualMachineLibrary = virtualMachineLibrary
    if let initialInventory {
      systemInfo = initialInventory.system
      containers = initialInventory.containers
      images = initialInventory.images
      volumes = initialInventory.volumes
      linuxMachines = initialInventory.machines
      virtualMachines = initialVirtualMachines
      hasLoaded = true
      lastRefresh = Date()
    }
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await refresh()
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    var messages: [String] = []

    do {
      let inventory = try await containerService.loadInventory()
      systemInfo = inventory.system
      containers = inventory.containers
      images = inventory.images
      volumes = inventory.volumes
      linuxMachines = inventory.machines
    } catch {
      systemInfo = nil
      messages.append("Apple container services: \(error.localizedDescription)")
    }

    do {
      virtualMachines = try await virtualMachineLibrary.list()
    } catch {
      messages.append("Virtual machine library: \(error.localizedDescription)")
    }

    errorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    lastRefresh = Date()
  }

  func startContainer(id: String) async {
    await performMutation {
      try await self.containerService.startContainer(id: id)
    }
  }

  func stopContainer(id: String) async {
    await performMutation {
      try await self.containerService.stopContainer(id: id)
    }
  }

  func restartContainer(id: String) async {
    await performMutation {
      try await self.containerService.restartContainer(id: id)
    }
  }

  func forceStopContainer(id: String) async {
    await performMutation {
      try await self.containerService.forceStopContainer(id: id)
    }
  }

  func deleteContainer(id: String) async {
    await performMutation {
      try await self.containerService.deleteContainer(id: id)
    }
  }

  func startMachine(id: String) async {
    await performMutation {
      try await self.containerService.startMachine(id: id)
    }
  }

  func stopMachine(id: String) async {
    await performMutation {
      try await self.containerService.stopMachine(id: id)
    }
  }

  func deleteMachine(id: String) async {
    await performMutation {
      try await self.containerService.deleteMachine(id: id)
    }
  }

  func createVirtualMachineDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) async throws {
    _ = try await virtualMachineLibrary.createDraft(
      name: name,
      guest: guest,
      resources: resources
    )
    virtualMachines = try await virtualMachineLibrary.list()
  }

  func clearError() {
    errorMessage = nil
  }

  func makeContainerInspector(for container: ContainerRecord) -> ContainerInspectorModel {
    ContainerInspectorModel(
      containerID: container.id,
      allocatedCPUCount: container.cpuCount,
      service: containerService
    )
  }

  func makeContainerProvisioningModel() -> ContainerProvisioningModel {
    ContainerProvisioningModel(service: containerService) { [weak self] in
      await self?.refresh()
    }
  }

  private func performMutation(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    do {
      try await operation()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
