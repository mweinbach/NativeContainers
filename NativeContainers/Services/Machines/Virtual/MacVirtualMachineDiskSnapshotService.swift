import Foundation

protocol MacVirtualMachineDiskSnapshotPersisting: Sendable {
  func macOSDiskSnapshotConfiguration(
    id: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotConfiguration

  func commitMacOSDiskSnapshotConfiguration(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration,
    replacing expected: MacVirtualMachineDiskSnapshotConfiguration,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

protocol MacVirtualMachineDiskSnapshotManaging: Sendable {
  func snapshot(
    id: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotConfiguration

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult
}

struct UnavailableMacVirtualMachineDiskSnapshotService:
  MacVirtualMachineDiskSnapshotManaging
{
  func snapshot(
    id: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotConfiguration {
    throw MacVirtualMachineDiskSnapshotError.unavailable
  }

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult {
    throw MacVirtualMachineDiskSnapshotError.unavailable
  }

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult {
    throw MacVirtualMachineDiskSnapshotError.unavailable
  }
}

actor MacVirtualMachineDiskSnapshotService:
  MacVirtualMachineDiskSnapshotManaging
{
  private let leasingStore: any MacVirtualMachineRuntimeLeasing
  private let persistence: any MacVirtualMachineDiskSnapshotPersisting
  private let savedStateService: any MacVirtualMachineSavedStateInspecting
  private let layerStore: any MacVirtualMachineDiskSnapshotLayerStoring

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineDiskSnapshotPersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting,
    layerStore: any MacVirtualMachineDiskSnapshotLayerStoring =
      AppleMacVirtualMachineDiskSnapshotLayerStore()
  ) {
    self.leasingStore = leasingStore
    self.persistence = persistence
    self.savedStateService = savedStateService
    self.layerStore = layerStore
  }

  func snapshot(
    id: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotConfiguration {
    try await persistence.macOSDiskSnapshotConfiguration(id: id)
  }

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult {
    guard #available(macOS 27.0, *) else {
      throw MacVirtualMachineDiskSnapshotError.unavailable
    }

    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    let current = lease.machine.manifest
      .effectiveMacOSDiskSnapshotConfiguration
    try requireResolvedLayersMatch(current, machine: lease.machine)
    try layerStore.recoverUnreferencedLayers(
      in: lease.machine.bundleURL,
      configuration: current
    )

    let mutation = try current.creatingSnapshot(named: name)
    _ = try layerStore.createLayer(
      mutation.createdLayer,
      baseURL: lease.machine.diskImageURL,
      retainedLayerURLs: lease.machine.diskSnapshotLayerURLs,
      targetLogicalBytes: lease.machine.manifest.resources.diskBytes,
      in: lease.machine.bundleURL
    )

    do {
      try Task.checkCancellation()
      let manifest =
        try await persistence
        .commitMacOSDiskSnapshotConfiguration(
          mutation.configuration,
          replacing: current,
          for: lease
        )
      return MacVirtualMachineDiskSnapshotOperationResult(
        manifest: manifest,
        cleanupWarning: nil
      )
    } catch {
      try discardUncommittedLayer(
        mutation.createdLayer,
        operationError: error,
        bundleURL: lease.machine.bundleURL
      )
    }
  }

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) async throws -> MacVirtualMachineDiskSnapshotOperationResult {
    guard #available(macOS 27.0, *) else {
      throw MacVirtualMachineDiskSnapshotError.unavailable
    }

    let lease = try await leasingStore.acquireMacOSRuntime(id: machineID)
    defer { lease.release() }

    try await requireNoSavedState(for: lease)
    let current = lease.machine.manifest
      .effectiveMacOSDiskSnapshotConfiguration
    try requireResolvedLayersMatch(current, machine: lease.machine)
    try layerStore.recoverUnreferencedLayers(
      in: lease.machine.bundleURL,
      configuration: current
    )

    let mutation = try current.restoring(snapshotID: snapshotID)
    let retainedLayerURLs = Array(
      lease.machine.diskSnapshotLayerURLs.prefix(
        mutation.configuration.layers.count - 1
      )
    )
    _ = try layerStore.createLayer(
      mutation.createdLayer,
      baseURL: lease.machine.diskImageURL,
      retainedLayerURLs: retainedLayerURLs,
      targetLogicalBytes: lease.machine.manifest.resources.diskBytes,
      in: lease.machine.bundleURL
    )

    let manifest: VirtualMachineManifest
    do {
      try Task.checkCancellation()
      manifest =
        try await persistence
        .commitMacOSDiskSnapshotConfiguration(
          mutation.configuration,
          replacing: current,
          for: lease
        )
    } catch {
      try discardUncommittedLayer(
        mutation.createdLayer,
        operationError: error,
        bundleURL: lease.machine.bundleURL
      )
    }

    let cleanupWarning: String?
    do {
      try layerStore.removeLayers(
        mutation.retiredLayers,
        in: lease.machine.bundleURL
      )
      cleanupWarning = nil
    } catch {
      cleanupWarning =
        MacVirtualMachineDiskSnapshotError
        .committedCleanupPending(error.localizedDescription)
        .localizedDescription
    }
    return MacVirtualMachineDiskSnapshotOperationResult(
      manifest: manifest,
      cleanupWarning: cleanupWarning
    )
  }

  private func requireNoSavedState(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    guard try await savedStateService.inspect(for: lease) == .none else {
      throw MacVirtualMachineDiskSnapshotError.savedStateMustBeDiscarded
    }
  }

  private func requireResolvedLayersMatch(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration,
    machine: ResolvedMacVirtualMachine
  ) throws {
    guard configuration.layers.count == machine.diskSnapshotLayerURLs.count,
      zip(configuration.layers, machine.diskSnapshotLayerURLs)
        .allSatisfy({
          machine.bundleURL.appending(path: $0.relativePath)
            .standardizedFileURL == $1.standardizedFileURL
        })
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "the resolved layer stack does not match the manifest"
      )
    }
  }

  private func discardUncommittedLayer(
    _ layer: MacVirtualMachineDiskSnapshotLayer,
    operationError: any Error,
    bundleURL: URL
  ) throws -> Never {
    do {
      try layerStore.removeLayers([layer], in: bundleURL)
    } catch {
      throw MacVirtualMachineDiskSnapshotError.operationAndCleanupFailed(
        operation: operationError.localizedDescription,
        cleanup: error.localizedDescription
      )
    }
    throw operationError
  }
}
