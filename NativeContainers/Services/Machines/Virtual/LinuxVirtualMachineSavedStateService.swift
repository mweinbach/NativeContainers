import Foundation

@MainActor
protocol LinuxVirtualMachineSavedStateInspecting: Sendable {
  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus
}

@MainActor
protocol LinuxVirtualMachineSavedStateManaging:
  LinuxVirtualMachineSavedStateInspecting
{
  func saveCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary
  func restoreCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary
  func discardCheckpoint(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws
}

@MainActor
final class LinuxVirtualMachineSavedStateService:
  LinuxVirtualMachineSavedStateManaging
{
  private let store: any LinuxVirtualMachineSavedStateStoring

  init(store: any LinuxVirtualMachineSavedStateStoring) {
    self.store = store
  }

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus {
    try await store.inspect(for: lease)
  }

  func saveCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    let transaction = try await store.beginSave(for: lease)
    do {
      try await session.saveState(to: transaction.stateURL)
      return try await store.commitSave(transaction, for: lease)
    } catch {
      await store.abortSave(transaction, for: lease)
      throw error
    }
  }

  func restoreCheckpoint(
    session: any LinuxVirtualMachineRuntimeEngineSession,
    lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    let transaction = try await store.beginRestore(for: lease)
    do {
      try await session.restoreState(from: transaction.artifact.stateURL)
    } catch {
      let operationError = error
      do {
        try await store.finishRestore(transaction, for: lease)
      } catch {
        throw LinuxVirtualMachineSavedStateError.operationAndCleanupFailed(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      throw operationError
    }

    try? await store.finishRestore(transaction, for: lease)
    return transaction.artifact.summary
  }

  func discardCheckpoint(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws {
    try await store.discard(for: lease)
  }
}
