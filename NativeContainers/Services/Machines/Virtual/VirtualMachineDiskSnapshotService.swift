import Foundation

protocol MacVirtualMachineDiskSnapshotPersisting: Sendable {
  func macOSDiskSnapshotConfiguration(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration

  func commitMacOSDiskSnapshotConfiguration(
    _ configuration: VirtualMachineDiskSnapshotConfiguration,
    replacing expected: VirtualMachineDiskSnapshotConfiguration,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

protocol LinuxVirtualMachineDiskSnapshotPersisting: Sendable {
  func linuxDiskSnapshotConfiguration(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration

  func commitLinuxDiskSnapshotConfiguration(
    _ configuration: VirtualMachineDiskSnapshotConfiguration,
    replacing expected: VirtualMachineDiskSnapshotConfiguration,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

protocol VirtualMachineDiskSnapshotManaging: Sendable {
  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> VirtualMachineDiskSnapshotOperationResult

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) async throws -> VirtualMachineDiskSnapshotOperationResult
}

struct UnavailableVirtualMachineDiskSnapshotService:
  VirtualMachineDiskSnapshotManaging
{
  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration {
    throw VirtualMachineDiskSnapshotError.unavailable
  }

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> VirtualMachineDiskSnapshotOperationResult {
    throw VirtualMachineDiskSnapshotError.unavailable
  }

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) async throws -> VirtualMachineDiskSnapshotOperationResult {
    throw VirtualMachineDiskSnapshotError.unavailable
  }
}

private struct VirtualMachineDiskSnapshotMachine: Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let diskImageURL: URL
  let diskSnapshotLayerURLs: [URL]
}

private final class VirtualMachineDiskSnapshotRuntimeLease:
  @unchecked Sendable
{
  let machine: VirtualMachineDiskSnapshotMachine

  private let stateLock = NSLock()
  private var releaseHandler: (@Sendable () -> Void)?
  private let requireNoSavedStateHandler: @Sendable () async throws -> Void
  private let commitHandler:
    @Sendable (
      VirtualMachineDiskSnapshotConfiguration,
      VirtualMachineDiskSnapshotConfiguration
    ) async throws -> VirtualMachineManifest

  init(
    machine: VirtualMachineDiskSnapshotMachine,
    release: @escaping @Sendable () -> Void,
    requireNoSavedState: @escaping @Sendable () async throws -> Void,
    commit:
      @escaping @Sendable (
        VirtualMachineDiskSnapshotConfiguration,
        VirtualMachineDiskSnapshotConfiguration
      ) async throws -> VirtualMachineManifest
  ) {
    self.machine = machine
    releaseHandler = release
    requireNoSavedStateHandler = requireNoSavedState
    commitHandler = commit
  }

  func requireNoSavedState() async throws {
    try await requireNoSavedStateHandler()
  }

  func commit(
    _ configuration: VirtualMachineDiskSnapshotConfiguration,
    replacing expected: VirtualMachineDiskSnapshotConfiguration
  ) async throws -> VirtualMachineManifest {
    try await commitHandler(configuration, expected)
  }

  func release() {
    let handler = stateLock.withLock {
      let handler = releaseHandler
      releaseHandler = nil
      return handler
    }
    handler?()
  }

  deinit {
    release()
  }
}

private protocol VirtualMachineDiskSnapshotRuntimeAccessing: Sendable {
  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration
  func acquireRuntime(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotRuntimeLease
}

private struct MacVirtualMachineDiskSnapshotRuntimeAccess:
  VirtualMachineDiskSnapshotRuntimeAccessing
{
  let leasingStore: any MacVirtualMachineRuntimeLeasing
  let persistence: any MacVirtualMachineDiskSnapshotPersisting
  let savedStateService: any MacVirtualMachineSavedStateInspecting

  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration {
    try await persistence.macOSDiskSnapshotConfiguration(id: id)
  }

  func acquireRuntime(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotRuntimeLease {
    let lease = try await leasingStore.acquireMacOSRuntime(id: id)
    return VirtualMachineDiskSnapshotRuntimeLease(
      machine: VirtualMachineDiskSnapshotMachine(
        manifest: lease.machine.manifest,
        bundleURL: lease.machine.bundleURL,
        diskImageURL: lease.machine.diskImageURL,
        diskSnapshotLayerURLs: lease.machine.diskSnapshotLayerURLs
      ),
      release: { lease.release() },
      requireNoSavedState: {
        guard try await savedStateService.inspect(for: lease) == .none else {
          throw VirtualMachineDiskSnapshotError.savedStateMustBeDiscarded
        }
      },
      commit: { configuration, expected in
        try await persistence.commitMacOSDiskSnapshotConfiguration(
          configuration,
          replacing: expected,
          for: lease
        )
      }
    )
  }
}

private struct LinuxVirtualMachineDiskSnapshotRuntimeAccess:
  VirtualMachineDiskSnapshotRuntimeAccessing
{
  let leasingStore: any LinuxVirtualMachineRuntimeLeasing
  let persistence: any LinuxVirtualMachineDiskSnapshotPersisting
  let savedStateService: any LinuxVirtualMachineSavedStateInspecting

  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration {
    try await persistence.linuxDiskSnapshotConfiguration(id: id)
  }

  func acquireRuntime(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotRuntimeLease {
    let lease = try await leasingStore.acquireLinuxRuntime(id: id)
    return VirtualMachineDiskSnapshotRuntimeLease(
      machine: VirtualMachineDiskSnapshotMachine(
        manifest: lease.machine.manifest,
        bundleURL: lease.machine.bundleURL,
        diskImageURL: lease.machine.diskImageURL,
        diskSnapshotLayerURLs: lease.machine.diskSnapshotLayerURLs
      ),
      release: { lease.release() },
      requireNoSavedState: {
        guard try await savedStateService.inspect(for: lease) == .none else {
          throw VirtualMachineDiskSnapshotError.savedStateMustBeDiscarded
        }
      },
      commit: { configuration, expected in
        try await persistence.commitLinuxDiskSnapshotConfiguration(
          configuration,
          replacing: expected,
          for: lease
        )
      }
    )
  }
}

actor VirtualMachineDiskSnapshotService:
  VirtualMachineDiskSnapshotManaging
{
  private let runtimeAccess: any VirtualMachineDiskSnapshotRuntimeAccessing
  private let layerStore: any VirtualMachineDiskSnapshotLayerStoring

  private init(
    runtimeAccess: any VirtualMachineDiskSnapshotRuntimeAccessing,
    layerStore: any VirtualMachineDiskSnapshotLayerStoring
  ) {
    self.runtimeAccess = runtimeAccess
    self.layerStore = layerStore
  }

  init(
    leasingStore: any MacVirtualMachineRuntimeLeasing,
    persistence: any MacVirtualMachineDiskSnapshotPersisting,
    savedStateService: any MacVirtualMachineSavedStateInspecting,
    layerStore: any VirtualMachineDiskSnapshotLayerStoring =
      AppleVirtualMachineDiskSnapshotLayerStore()
  ) {
    self.init(
      runtimeAccess: MacVirtualMachineDiskSnapshotRuntimeAccess(
        leasingStore: leasingStore,
        persistence: persistence,
        savedStateService: savedStateService
      ),
      layerStore: layerStore
    )
  }

  init(
    linuxLeasingStore: any LinuxVirtualMachineRuntimeLeasing,
    linuxPersistence: any LinuxVirtualMachineDiskSnapshotPersisting,
    linuxSavedStateService: any LinuxVirtualMachineSavedStateInspecting,
    layerStore: any VirtualMachineDiskSnapshotLayerStoring =
      AppleVirtualMachineDiskSnapshotLayerStore()
  ) {
    self.init(
      runtimeAccess: LinuxVirtualMachineDiskSnapshotRuntimeAccess(
        leasingStore: linuxLeasingStore,
        persistence: linuxPersistence,
        savedStateService: linuxSavedStateService
      ),
      layerStore: layerStore
    )
  }

  func snapshot(
    id: UUID
  ) async throws -> VirtualMachineDiskSnapshotConfiguration {
    try await runtimeAccess.snapshot(id: id)
  }

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) async throws -> VirtualMachineDiskSnapshotOperationResult {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskSnapshotError.unavailable
    }

    let lease = try await runtimeAccess.acquireRuntime(id: machineID)
    defer { lease.release() }

    guard lease.machine.manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(
        lease.machine.manifest.installState
      )
    }
    try await lease.requireNoSavedState()
    let current = lease.machine.manifest.effectiveDiskSnapshotConfiguration
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
      let manifest = try await lease.commit(
        mutation.configuration,
        replacing: current
      )
      return VirtualMachineDiskSnapshotOperationResult(
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
  ) async throws -> VirtualMachineDiskSnapshotOperationResult {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskSnapshotError.unavailable
    }

    let lease = try await runtimeAccess.acquireRuntime(id: machineID)
    defer { lease.release() }

    guard lease.machine.manifest.installState == .stopped else {
      throw VirtualMachineModelError.invalidInstallState(
        lease.machine.manifest.installState
      )
    }
    try await lease.requireNoSavedState()
    let current = lease.machine.manifest.effectiveDiskSnapshotConfiguration
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
      manifest = try await lease.commit(
        mutation.configuration,
        replacing: current
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
        VirtualMachineDiskSnapshotError
        .committedCleanupPending(error.localizedDescription)
        .localizedDescription
    }
    return VirtualMachineDiskSnapshotOperationResult(
      manifest: manifest,
      cleanupWarning: cleanupWarning
    )
  }

  private func requireResolvedLayersMatch(
    _ configuration: VirtualMachineDiskSnapshotConfiguration,
    machine: VirtualMachineDiskSnapshotMachine
  ) throws {
    guard configuration.layers.count == machine.diskSnapshotLayerURLs.count,
      zip(configuration.layers, machine.diskSnapshotLayerURLs)
        .allSatisfy({
          machine.bundleURL.appending(path: $0.relativePath)
            .standardizedFileURL == $1.standardizedFileURL
        })
    else {
      throw VirtualMachineDiskSnapshotError.invalidConfiguration(
        "the resolved layer stack does not match the manifest"
      )
    }
  }

  private func discardUncommittedLayer(
    _ layer: VirtualMachineDiskSnapshotLayer,
    operationError: any Error,
    bundleURL: URL
  ) throws -> Never {
    do {
      try layerStore.removeLayers([layer], in: bundleURL)
    } catch {
      throw VirtualMachineDiskSnapshotError.operationAndCleanupFailed(
        operation: operationError.localizedDescription,
        cleanup: error.localizedDescription
      )
    }
    throw operationError
  }
}

typealias MacVirtualMachineDiskSnapshotManaging =
  VirtualMachineDiskSnapshotManaging
typealias LinuxVirtualMachineDiskSnapshotManaging =
  VirtualMachineDiskSnapshotManaging
typealias UnavailableMacVirtualMachineDiskSnapshotService =
  UnavailableVirtualMachineDiskSnapshotService
typealias UnavailableLinuxVirtualMachineDiskSnapshotService =
  UnavailableVirtualMachineDiskSnapshotService
typealias MacVirtualMachineDiskSnapshotService =
  VirtualMachineDiskSnapshotService
typealias LinuxVirtualMachineDiskSnapshotService =
  VirtualMachineDiskSnapshotService
