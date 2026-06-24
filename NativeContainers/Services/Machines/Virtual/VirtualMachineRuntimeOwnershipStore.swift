import Foundation

protocol MacVirtualMachineRuntimeLeasing: Sendable {
  func acquireMacOSRuntime(id: UUID) async throws -> MacVirtualMachineRuntimeLease
}

protocol LinuxVirtualMachineRuntimeLeasing: Sendable {
  func acquireLinuxRuntime(id: UUID) async throws -> LinuxVirtualMachineRuntimeLease
}

protocol WindowsVirtualMachineBootMediaRepairing: Sendable {
  func repairWindowsBootMediaIfNeeded(id: UUID) async throws
}

struct NoOpWindowsVirtualMachineBootMediaRepairer:
  WindowsVirtualMachineBootMediaRepairing
{
  func repairWindowsBootMediaIfNeeded(id: UUID) async throws {}
}

protocol LinuxVirtualMachineInstallationCompleting: Sendable {
  func completeLinuxInstallation(
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest
}

struct VirtualMachineRuntimeOwnerRecord: Codable, Equatable, Sendable {
  let machineID: UUID
  let generation: UUID
  let launchID: UUID
  let processID: Int32
  let acquiredAt: Date
}

typealias MacVirtualMachineRuntimeOwnerRecord = VirtualMachineRuntimeOwnerRecord
typealias LinuxVirtualMachineRuntimeOwnerRecord = VirtualMachineRuntimeOwnerRecord

final class VirtualMachineRuntimeLeaseBorrow: @unchecked Sendable {
  private let stateLock = NSLock()
  private var returnHandler: (() -> Void)?

  fileprivate init(returnHandler: @escaping () -> Void) {
    self.returnHandler = returnHandler
  }

  func release() {
    let handler = stateLock.withLock {
      let handler = returnHandler
      returnHandler = nil
      return handler
    }
    handler?()
  }

  deinit {
    release()
  }
}

typealias MacVirtualMachineRuntimeLeaseBorrow = VirtualMachineRuntimeLeaseBorrow
typealias LinuxVirtualMachineRuntimeLeaseBorrow = VirtualMachineRuntimeLeaseBorrow

private final class VirtualMachineRuntimeLeaseState: @unchecked Sendable {
  private let stateLock = NSLock()
  private var releaseHandler: (() -> Void)?
  private var releaseRequested = false
  private var borrowCount = 0

  init(release: @escaping () -> Void) {
    releaseHandler = release
  }

  func release() {
    let handler: (() -> Void)? = stateLock.withLock {
      guard !releaseRequested else { return nil }
      releaseRequested = true
      return takeReleaseHandlerIfPossible()
    }
    handler?()
  }

  func borrow(or error: @autoclosure () -> any Error) throws
    -> VirtualMachineRuntimeLeaseBorrow
  {
    try stateLock.withLock {
      guard !releaseRequested, releaseHandler != nil else {
        throw error()
      }
      borrowCount += 1
      return VirtualMachineRuntimeLeaseBorrow { [self] in
        returnBorrow()
      }
    }
  }

  private func returnBorrow() {
    let handler = stateLock.withLock {
      precondition(borrowCount > 0, "A runtime lease borrow must be returned exactly once.")
      borrowCount -= 1
      return takeReleaseHandlerIfPossible()
    }
    handler?()
  }

  private func takeReleaseHandlerIfPossible() -> (() -> Void)? {
    guard releaseRequested, borrowCount == 0 else { return nil }
    let handler = releaseHandler
    releaseHandler = nil
    return handler
  }

  deinit {
    release()
  }
}

final class MacVirtualMachineRuntimeLease: @unchecked Sendable {
  let machine: ResolvedMacVirtualMachine
  let target: MacVirtualMachineRuntimeTarget

  private let state: VirtualMachineRuntimeLeaseState

  init(
    machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget,
    release: @escaping () -> Void
  ) {
    self.machine = machine
    self.target = target
    state = VirtualMachineRuntimeLeaseState(release: release)
  }

  func release() {
    state.release()
  }

  func borrow() throws -> MacVirtualMachineRuntimeLeaseBorrow {
    try state.borrow(or: MacVirtualMachineRuntimeError.staleTarget(target))
  }
}

final class LinuxVirtualMachineRuntimeLease: @unchecked Sendable {
  let machine: ResolvedLinuxVirtualMachine
  let target: LinuxVirtualMachineRuntimeTarget

  private let state: VirtualMachineRuntimeLeaseState

  init(
    machine: ResolvedLinuxVirtualMachine,
    target: LinuxVirtualMachineRuntimeTarget,
    release: @escaping () -> Void
  ) {
    self.machine = machine
    self.target = target
    state = VirtualMachineRuntimeLeaseState(release: release)
  }

  func release() {
    state.release()
  }

  func borrow() throws -> LinuxVirtualMachineRuntimeLeaseBorrow {
    try state.borrow(or: LinuxVirtualMachineRuntimeError.staleTarget(target))
  }
}
