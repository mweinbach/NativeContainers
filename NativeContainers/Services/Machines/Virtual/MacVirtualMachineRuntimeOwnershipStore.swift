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
  private var releaseRequested = false
  private var borrowCount = 0

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
    let handler: (() -> Void)? = stateLock.withLock {
      guard !releaseRequested else { return nil }
      releaseRequested = true
      return takeReleaseHandlerIfPossible()
    }
    handler?()
  }

  func borrow() throws -> MacVirtualMachineRuntimeLeaseBorrow {
    try stateLock.withLock {
      guard !releaseRequested, releaseHandler != nil else {
        throw MacVirtualMachineRuntimeError.staleTarget(target)
      }
      borrowCount += 1
      return MacVirtualMachineRuntimeLeaseBorrow { [self] in
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

final class MacVirtualMachineRuntimeLeaseBorrow: @unchecked Sendable {
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
