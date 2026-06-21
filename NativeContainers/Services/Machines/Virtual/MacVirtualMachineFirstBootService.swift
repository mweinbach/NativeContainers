import Foundation

struct MacVirtualMachineFirstBootAttempt: Equatable, Sendable {
  let target: MacVirtualMachineRuntimeTarget
}

protocol MacVirtualMachineFirstBootPersisting: Sendable {
  func transitionMacOSFirstBootState(
    from expectedState: MacVirtualMachineFirstBootState,
    to newState: MacVirtualMachineFirstBootState,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws
}

protocol MacVirtualMachineFirstBootManaging: Sendable {
  func begin(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineFirstBootAttempt?

  func complete(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws

  func cancel(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws
}

struct MacVirtualMachineFirstBootService: MacVirtualMachineFirstBootManaging {
  private let persistence: any MacVirtualMachineFirstBootPersisting

  init(persistence: any MacVirtualMachineFirstBootPersisting) {
    self.persistence = persistence
  }

  func begin(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineFirstBootAttempt? {
    guard lease.machine.manifest.macOSFirstBootState == .pending else {
      return nil
    }
    try await persistence.transitionMacOSFirstBootState(
      from: .pending,
      to: .launching,
      for: lease
    )
    return MacVirtualMachineFirstBootAttempt(target: lease.target)
  }

  func complete(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    try requireCurrent(attempt, for: lease)
    try await persistence.transitionMacOSFirstBootState(
      from: .launching,
      to: .started,
      for: lease
    )
  }

  func cancel(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    try requireCurrent(attempt, for: lease)
    try await persistence.transitionMacOSFirstBootState(
      from: .launching,
      to: .pending,
      for: lease
    )
  }

  private func requireCurrent(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) throws {
    guard attempt.target == lease.target else {
      throw MacVirtualMachineFirstBootError.staleAttempt(attempt.target)
    }
  }
}

struct UntrackedMacVirtualMachineFirstBootService: MacVirtualMachineFirstBootManaging {
  func begin(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineFirstBootAttempt? {
    nil
  }

  func complete(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {}

  func cancel(
    _ attempt: MacVirtualMachineFirstBootAttempt,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {}
}

enum MacVirtualMachineFirstBootError: LocalizedError, Equatable, Sendable {
  case invalidTransition(
    expected: MacVirtualMachineFirstBootState,
    actual: MacVirtualMachineFirstBootState?
  )
  case staleAttempt(MacVirtualMachineRuntimeTarget)
  case rollbackFailed(start: String, rollback: String)

  var errorDescription: String? {
    switch self {
    case .invalidTransition(let expected, let actual):
      let actualDescription = actual?.rawValue ?? "unknown"
      return
        "The virtual machine first-boot state changed unexpectedly (expected \(expected.rawValue), found \(actualDescription))."
    case .staleAttempt:
      return "The virtual machine first-boot attempt is no longer current."
    case .rollbackFailed(let start, let rollback):
      return
        "The virtual machine failed to start: \(start) Restoring first-boot eligibility also failed: \(rollback)"
    }
  }
}
