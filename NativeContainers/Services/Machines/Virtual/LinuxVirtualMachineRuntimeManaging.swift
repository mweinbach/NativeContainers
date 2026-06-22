import Foundation

typealias LinuxVirtualMachineRuntimeEventHandler =
  @MainActor @Sendable (LinuxVirtualMachineRuntimeEvent) -> Void

@MainActor
protocol LinuxVirtualMachineRuntimeEngine: Sendable {
  func makeSession(
    for machine: ResolvedLinuxVirtualMachine,
    target: LinuxVirtualMachineRuntimeTarget
  ) throws -> any LinuxVirtualMachineRuntimeEngineSession
}

@MainActor
protocol LinuxVirtualMachineRuntimeEngineSession: AnyObject {
  var target: LinuxVirtualMachineRuntimeTarget { get }
  var console: LinuxVirtualMachineConsole? { get }
  var saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport { get }
  var hasInstallationMedia: Bool { get }
  var canForceStop: Bool { get }
  var eventHandler: LinuxVirtualMachineRuntimeEventHandler? { get set }

  func start() async throws
  func saveState(to url: URL) async throws
  func restoreState(from url: URL) async throws
  func pause() async throws
  func resume() async throws
  func requestStop() throws
  func forceStop() async throws
  func ejectInstallationMedia() async throws
  func close()
}

extension LinuxVirtualMachineRuntimeEngineSession {
  func close() {}
}

@MainActor
protocol LinuxVirtualMachineRuntimeManaging: Sendable {
  func snapshot(for machineID: UUID) -> LinuxVirtualMachineRuntimeSnapshot
  func updates(for machineID: UUID) -> AsyncStream<LinuxVirtualMachineRuntimeSnapshot>
  func console(for target: LinuxVirtualMachineRuntimeTarget) -> LinuxVirtualMachineConsole?

  func refreshSavedState(id: UUID) async
  func start(id: UUID) async throws
  func startFresh(id: UUID) async throws
  func pause(target: LinuxVirtualMachineRuntimeTarget) async throws
  func resume(target: LinuxVirtualMachineRuntimeTarget) async throws
  func suspend(target: LinuxVirtualMachineRuntimeTarget) async throws
  func requestStop(target: LinuxVirtualMachineRuntimeTarget) throws
  func forceStop(target: LinuxVirtualMachineRuntimeTarget) async throws
  func discardSavedState(id: UUID) async throws
  func ejectInstallationMedia(
    target: LinuxVirtualMachineRuntimeTarget
  ) async throws -> VirtualMachineManifest
}

@MainActor
struct UnavailableLinuxVirtualMachineRuntimeService: LinuxVirtualMachineRuntimeManaging {
  func snapshot(for machineID: UUID) -> LinuxVirtualMachineRuntimeSnapshot {
    LinuxVirtualMachineRuntimeSnapshot(machineID: machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<LinuxVirtualMachineRuntimeSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot(for: machineID))
      continuation.finish()
    }
  }

  func console(
    for target: LinuxVirtualMachineRuntimeTarget
  ) -> LinuxVirtualMachineConsole? {
    nil
  }

  func refreshSavedState(id: UUID) async {}

  func start(id: UUID) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func startFresh(id: UUID) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func pause(target: LinuxVirtualMachineRuntimeTarget) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func resume(target: LinuxVirtualMachineRuntimeTarget) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func suspend(target: LinuxVirtualMachineRuntimeTarget) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func requestStop(target: LinuxVirtualMachineRuntimeTarget) throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func forceStop(target: LinuxVirtualMachineRuntimeTarget) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func discardSavedState(id: UUID) async throws {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }

  func ejectInstallationMedia(
    target: LinuxVirtualMachineRuntimeTarget
  ) async throws -> VirtualMachineManifest {
    throw LinuxVirtualMachineRuntimeError.unavailable
  }
}
