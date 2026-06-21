import Foundation

@MainActor
protocol MacVirtualMachineSavedStateManaging: Sendable {
  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus
  func saveCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary
  func restoreCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary
  func discardCheckpoint(for lease: MacVirtualMachineRuntimeLease) async throws
}

@MainActor
final class MacVirtualMachineSavedStateService:
  MacVirtualMachineSavedStateManaging
{
  private let store: any MacVirtualMachineSavedStateStoring

  init(store: any MacVirtualMachineSavedStateStoring) {
    self.store = store
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    try await store.inspect(for: lease)
  }

  func saveCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
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
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
    let transaction = try await store.beginRestore(for: lease)
    do {
      try await session.restoreState(from: transaction.artifact.stateURL)
    } catch {
      let operationError = error
      do {
        try await store.finishRestore(transaction, for: lease)
      } catch {
        throw MacVirtualMachineSavedStateError.operationAndCleanupFailed(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      throw operationError
    }

    // The active checkpoint was already atomically consumed before VZ saw it.
    // A failed tombstone deletion is recovered on the next inspection and must
    // not make a successfully restored, paused VM look stopped.
    try? await store.finishRestore(transaction, for: lease)
    return transaction.artifact.summary
  }

  func discardCheckpoint(for lease: MacVirtualMachineRuntimeLease) async throws {
    try await store.discard(for: lease)
  }
}
