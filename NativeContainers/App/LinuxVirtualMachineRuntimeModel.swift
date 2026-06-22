import Foundation
import Observation

@MainActor
@Observable
final class LinuxVirtualMachineRuntimeModel {
  let machineID: UUID
  private(set) var snapshot: LinuxVirtualMachineRuntimeSnapshot
  private(set) var actionErrorMessage: String?

  private let service: any LinuxVirtualMachineRuntimeManaging
  private let didUpdateManifest: @MainActor (VirtualMachineManifest) -> Void
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var hasRefreshedSavedState = false

  init(
    machineID: UUID,
    service: any LinuxVirtualMachineRuntimeManaging,
    didUpdateManifest: @escaping @MainActor (VirtualMachineManifest) -> Void = { _ in }
  ) {
    self.machineID = machineID
    self.service = service
    self.didUpdateManifest = didUpdateManifest
    snapshot = service.snapshot(for: machineID)
  }

  var console: LinuxVirtualMachineConsole? {
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

  private func apply(_ update: LinuxVirtualMachineRuntimeSnapshot) {
    guard update.revision >= snapshot.revision else { return }
    snapshot = update
    if update.errorMessage == nil {
      actionErrorMessage = nil
    }
  }

  func start() async {
    await perform {
      try await service.start(id: machineID)
    }
  }

  func refreshSavedState() async {
    await service.refreshSavedState(id: machineID)
  }

  func startFresh() async {
    await perform {
      try await service.startFresh(id: machineID)
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

  func setMemoryBalloonTarget(_ memoryBytes: UInt64) async {
    guard let target = snapshot.target else { return }
    await perform {
      try service.setMemoryBalloonTarget(memoryBytes, for: target)
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

  func ejectInstallationMedia() async {
    guard let target = snapshot.target else { return }
    await perform {
      let manifest = try await service.ejectInstallationMedia(target: target)
      didUpdateManifest(manifest)
    }
  }

  func clearActionError() {
    actionErrorMessage = nil
  }

  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
    hasRefreshedSavedState = false
  }

  private func perform(_ operation: () async throws -> Void) async {
    actionErrorMessage = nil
    defer { snapshot = service.snapshot(for: machineID) }
    do {
      try await operation()
    } catch {
      actionErrorMessage = error.localizedDescription
    }
  }

  deinit {
    observationTask?.cancel()
  }
}
