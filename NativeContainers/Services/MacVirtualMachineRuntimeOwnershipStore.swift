import Foundation

protocol MacVirtualMachineRuntimeLeasing: Sendable {
  func acquireMacOSRuntime(id: UUID) async throws -> MacVirtualMachineRuntimeLease
}

struct MacVirtualMachineRuntimeOwnerRecord: Codable, Equatable, Sendable {
  let machineID: UUID
  let generation: UUID
  let launchID: UUID
  let processID: Int32
  let acquiredAt: Date
}

final class MacVirtualMachineRuntimeLease: @unchecked Sendable {
  let machine: ResolvedMacVirtualMachine
  let target: MacVirtualMachineRuntimeTarget

  private let stateLock = NSLock()
  private var releaseHandler: (() -> Void)?

  init(
    machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget,
    release: @escaping () -> Void
  ) {
    self.machine = machine
    self.target = target
    releaseHandler = release
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
