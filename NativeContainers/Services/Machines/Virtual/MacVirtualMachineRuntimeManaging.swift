import Foundation

typealias MacVirtualMachineRuntimeEventHandler =
  @MainActor @Sendable (MacVirtualMachineRuntimeEvent) -> Void

@MainActor
protocol MacVirtualMachineRuntimeEngine: Sendable {
  func makeSession(
    for machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget
  ) throws -> any MacVirtualMachineRuntimeEngineSession
}

@MainActor
protocol MacVirtualMachineRuntimeEngineSession: AnyObject {
  var target: MacVirtualMachineRuntimeTarget { get }
  var console: MacVirtualMachineConsole? { get }
  var saveRestoreSupport: MacVirtualMachineSaveRestoreSupport { get }
  var canForceStop: Bool { get }
  var eventHandler: MacVirtualMachineRuntimeEventHandler? { get set }

  func start() async throws
  func saveState(to url: URL) async throws
  func restoreState(from url: URL) async throws
  func pause() async throws
  func resume() async throws
  func requestStop() throws
  func forceStop() async throws
  func close()
}

extension MacVirtualMachineRuntimeEngineSession {
  func close() {}
}

@MainActor
protocol MacVirtualMachineRuntimeManaging: Sendable {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot
  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot>
  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole?

  func refreshSavedState(id: UUID) async
  func start(id: UUID) async throws
  func startFresh(id: UUID) async throws
  func pause(target: MacVirtualMachineRuntimeTarget) async throws
  func resume(target: MacVirtualMachineRuntimeTarget) async throws
  func suspend(target: MacVirtualMachineRuntimeTarget) async throws
  func requestStop(target: MacVirtualMachineRuntimeTarget) throws
  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws
  func discardSavedState(id: UUID) async throws
}

@MainActor
struct UnavailableMacVirtualMachineRuntimeService: MacVirtualMachineRuntimeManaging {
  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    MacVirtualMachineRuntimeSnapshot(
      machineID: machineID,
      savedStateStatus: .none
    )
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot(for: machineID))
      continuation.finish()
    }
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? { nil }
  func refreshSavedState(id: UUID) async {}
  func start(id: UUID) async throws { throw MacVirtualMachineRuntimeError.unavailable }
  func startFresh(id: UUID) async throws { throw MacVirtualMachineRuntimeError.unavailable }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func suspend(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }

  func discardSavedState(id: UUID) async throws {
    throw MacVirtualMachineRuntimeError.unavailable
  }
}
