import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineRuntimeModel {
  let machineID: UUID
  private(set) var snapshot: MacVirtualMachineRuntimeSnapshot
  private(set) var actionErrorMessage: String?
  private(set) var hasStartedSinceLoad = false

  private let service: any MacVirtualMachineRuntimeManaging
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var hasRefreshedSavedState = false

  init(machineID: UUID, service: any MacVirtualMachineRuntimeManaging) {
    self.machineID = machineID
    self.service = service
    snapshot = service.snapshot(for: machineID)
  }

  var console: MacVirtualMachineConsole? {
    guard let target = snapshot.target else { return nil }
    return service.console(for: target)
  }

  var errorMessage: String? {
    actionErrorMessage ?? snapshot.errorMessage
  }

  func observe() async {
    if observationTask == nil {
      let updates = service.updates(for: machineID)
      observationTask = Task { @MainActor [weak self] in
        for await update in updates {
          guard !Task.isCancelled, let self else { return }
          apply(update)
        }
      }
    }
    guard !hasRefreshedSavedState else { return }
    hasRefreshedSavedState = true
    await service.refreshSavedState(id: machineID)
  }

  private func apply(_ update: MacVirtualMachineRuntimeSnapshot) {
    guard update.revision >= snapshot.revision else { return }
    snapshot = update
    if update.errorMessage == nil {
      actionErrorMessage = nil
    }
  }

  func start() async {
    if await perform({
      try await service.start(id: machineID)
    }) {
      hasStartedSinceLoad = true
    }
  }

  func start(provisioning: MacGuestProvisioningRequest) async -> Bool {
    let didStart = await perform {
      try await service.start(
        id: machineID,
        provisioning: provisioning
      )
    }
    if didStart {
      hasStartedSinceLoad = true
    }
    return didStart
  }

  func startFresh() async {
    if await perform({
      try await service.startFresh(id: machineID)
    }) {
      hasStartedSinceLoad = true
    }
  }

  func pause() async {
    guard let target = snapshot.target else { return }
    await perform {
      try await service.pause(target: target)
    }
  }

  func resume() async {
    guard let target = snapshot.target else { return }
    await perform {
      try await service.resume(target: target)
    }
  }

  func suspend() async {
    guard let target = snapshot.target else { return }
    await perform {
      try await service.suspend(target: target)
    }
  }

  func requestStop() async {
    guard let target = snapshot.target else { return }
    await perform {
      try service.requestStop(target: target)
    }
  }

  func forceStop() async {
    guard let target = snapshot.target else { return }
    await perform {
      try await service.forceStop(target: target)
    }
  }

  func discardSavedState() async {
    await perform {
      try await service.discardSavedState(id: machineID)
    }
  }

  func clearActionError() {
    actionErrorMessage = nil
  }

  func refreshSavedState() async {
    await service.refreshSavedState(id: machineID)
  }

  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
    hasRefreshedSavedState = false
  }

  @discardableResult
  private func perform(_ operation: () async throws -> Void) async -> Bool {
    actionErrorMessage = nil
    defer { snapshot = service.snapshot(for: machineID) }
    do {
      try await operation()
      return true
    } catch {
      actionErrorMessage = error.localizedDescription
      return false
    }
  }

  deinit {
    observationTask?.cancel()
  }
}
