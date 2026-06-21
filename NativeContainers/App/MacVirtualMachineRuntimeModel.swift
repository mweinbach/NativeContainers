import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineRuntimeModel {
  let machineID: UUID
  private(set) var snapshot: MacVirtualMachineRuntimeSnapshot
  private(set) var actionErrorMessage: String?

  private let service: any MacVirtualMachineRuntimeManaging

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
    for await update in service.updates(for: machineID) {
      guard !Task.isCancelled else { return }
      guard update.revision >= snapshot.revision else { continue }
      snapshot = update
      if update.errorMessage == nil {
        actionErrorMessage = nil
      }
    }
  }

  func start() async {
    await perform {
      try await service.start(id: machineID)
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

  func clearActionError() {
    actionErrorMessage = nil
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
}
