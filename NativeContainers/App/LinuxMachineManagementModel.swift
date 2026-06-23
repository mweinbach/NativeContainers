import Foundation
import Observation

@MainActor
@Observable
final class LinuxMachineManagementModel {
  private(set) var isWorking = false
  private(set) var progress: ContainerOperationProgress?
  private(set) var errorMessage: String?
  private(set) var partialCreation: LinuxMachineCreationResult?
  private(set) var configurationUpdate: LinuxMachineConfigurationUpdateResult?

  private let creator: any MachineCreating
  private let lifecycle: any MachineLifecycleManaging
  private let configuration: any MachineConfigurationManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    creator: any MachineCreating,
    lifecycle: any MachineLifecycleManaging,
    configuration: any MachineConfigurationManaging =
      UnavailableLinuxMachineConfigurationService(),
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.creator = creator
    self.lifecycle = lifecycle
    self.configuration = configuration
    self.didMutate = didMutate
  }

  func createMachine(_ request: LinuxMachineCreationRequest) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    progress = nil
    errorMessage = nil
    partialCreation = nil
    configurationUpdate = nil
    defer { isWorking = false }

    do {
      _ = try await creator.createMachine(request: request) { update in
        await self.receive(update)
      }
      await refreshIgnoringCancellation()
      return true
    } catch let error as LinuxMachinePartialCompletionError {
      partialCreation = error.recovery.retainsMachine ? error.result : nil
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    } catch is CancellationError {
      errorMessage = "The operation was cancelled."
      await refreshIgnoringCancellation()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    }
  }

  func start(_ machine: LinuxMachineRecord) async -> Bool {
    await mutate {
      try await self.lifecycle.startMachine(LinuxMachineIdentity(machine: machine))
    }
  }

  func stop(_ machine: LinuxMachineRecord) async -> Bool {
    await mutate {
      try await self.lifecycle.stopMachine(LinuxMachineIdentity(machine: machine))
    }
  }

  func forceStop(_ machine: LinuxMachineRecord) async -> Bool {
    let target = LinuxMachineIdentity(machine: machine)
    return await mutate {
      try await self.lifecycle.forceStopMachine(
        target,
        authorization: .confirmed(for: target)
      )
    }
  }

  func delete(_ machine: LinuxMachineRecord) async -> Bool {
    await mutate {
      try await self.lifecycle.deleteMachine(LinuxMachineIdentity(machine: machine))
    }
  }

  func updateConfiguration(
    for machine: LinuxMachineRecord,
    request: LinuxMachineConfigurationUpdateRequest
  ) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    configurationUpdate = nil
    defer { isWorking = false }

    do {
      configurationUpdate = try await configuration.updateConfiguration(
        for: LinuxMachineIdentity(machine: machine),
        request: request
      )
      await refreshIgnoringCancellation()
      return true
    } catch is CancellationError {
      await refreshIgnoringCancellation()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    }
  }

  func beginCreationSession() {
    progress = nil
    errorMessage = nil
    partialCreation = nil
    configurationUpdate = nil
  }

  func beginConfigurationSession() {
    errorMessage = nil
    configurationUpdate = nil
  }

  func report(_ error: any Error) {
    errorMessage = error.localizedDescription
  }

  func clearConfigurationUpdate() {
    configurationUpdate = nil
  }

  func clearError() {
    errorMessage = nil
    partialCreation = nil
  }

  private func mutate(
    _ operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    configurationUpdate = nil
    defer { isWorking = false }

    do {
      try await operation()
      await refreshIgnoringCancellation()
      return true
    } catch is CancellationError {
      await refreshIgnoringCancellation()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshIgnoringCancellation()
      return false
    }
  }

  private func receive(_ update: ContainerOperationProgress) {
    progress = update
  }

  private func refreshIgnoringCancellation() async {
    let didMutate = self.didMutate
    await Task.detached {
      await didMutate()
    }.value
  }
}

@MainActor
@Observable
final class LinuxMachineSnapshotModel {
  private(set) var catalog: LinuxMachineSnapshotCatalog?
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any LinuxMachineSnapshotManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any LinuxMachineSnapshotManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func load(for machine: LinuxMachineRecord) async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    catalog = nil
    defer { isWorking = false }
    do {
      catalog = try await service.loadSnapshots(
        for: LinuxMachineIdentity(machine: machine)
      )
    } catch is CancellationError {
      return
    } catch {
      catalog = nil
      errorMessage = error.localizedDescription
    }
  }

  func create(named name: String) async -> Bool {
    await mutate(refreshesInventory: false) { catalog in
      try await self.service.createSnapshot(named: name, in: catalog)
    }
  }

  func restore(_ snapshot: LinuxMachineSnapshotRecord) async -> Bool {
    await mutate(refreshesInventory: true) { catalog in
      try await self.service.restoreSnapshot(snapshot.id, in: catalog)
    }
  }

  func clone(_ snapshot: LinuxMachineSnapshotRecord, as machineID: String) async -> Bool {
    guard let catalog, !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let result = try await service.cloneSnapshot(
        snapshot.id,
        as: machineID,
        in: catalog
      )
      self.catalog = result.sourceCatalog
      await didMutate()
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func delete(_ snapshot: LinuxMachineSnapshotRecord) async -> Bool {
    await mutate(refreshesInventory: false) { catalog in
      try await self.service.deleteSnapshot(snapshot.id, in: catalog)
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func mutate(
    refreshesInventory: Bool,
    _ operation:
      @escaping @MainActor @Sendable (
        LinuxMachineSnapshotCatalog
      ) async throws -> LinuxMachineSnapshotCatalog
  ) async -> Bool {
    guard let catalog, !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      self.catalog = try await operation(catalog)
      if refreshesInventory {
        await didMutate()
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
