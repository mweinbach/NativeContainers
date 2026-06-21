import Foundation

@MainActor
protocol MacVirtualMachineInstalling: Sendable {
  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws
  func recoverInterruptedInstallations() async throws
}

extension MacVirtualMachineInstalling {
  func install(id: UUID) async throws {
    try await install(id: id) { _ in }
  }
}

@MainActor
protocol MacVirtualMachineInstallationEngine: Sendable {
  func makeSession(
    for machine: PreparedMacVirtualMachine
  ) throws -> any MacVirtualMachineInstallationSession
}

@MainActor
protocol MacVirtualMachineInstallationSession: AnyObject {
  func install(progress: @escaping MacVirtualMachineInstallationProgressHandler) async throws
}

@MainActor
final class MacVirtualMachineInstallationService: MacVirtualMachineInstalling {
  private let store: any MacVirtualMachineInstallationStoring
  private let engine: any MacVirtualMachineInstallationEngine
  private var activeMachineIDs = Set<UUID>()

  init(
    store: any MacVirtualMachineInstallationStoring,
    engine: any MacVirtualMachineInstallationEngine
  ) {
    self.store = store
    self.engine = engine
  }

  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {
    guard activeMachineIDs.insert(id).inserted else {
      throw MacVirtualMachineInstallationError.duplicateInstallation(id)
    }
    defer { activeMachineIDs.remove(id) }

    progress(MacVirtualMachineInstallationProgress(phase: .preparing))
    let operationID = UUID()
    var leaseStarted = false
    do {
      let preparedMachine = try await store.stageMacOSInstallation(
        id: id,
        operationID: operationID
      )
      let session = try engine.makeSession(for: preparedMachine)
      try Task.checkCancellation()
      try await store.beginMacOSInstallation(id: id, operationID: operationID)
      leaseStarted = true

      var lastFraction = 0.0
      try await session.install { update in
        let normalizedFraction = update.fractionCompleted.map {
          max(lastFraction, min(1, max(0, $0)))
        }
        if let normalizedFraction {
          lastFraction = normalizedFraction
        }
        progress(
          MacVirtualMachineInstallationProgress(
            phase: .installing,
            fractionCompleted: normalizedFraction
          )
        )
      }
      progress(
        MacVirtualMachineInstallationProgress(
          phase: .finalizing,
          fractionCompleted: 1
        )
      )
      try await store.completeMacOSInstallation(id: id, operationID: operationID)
    } catch {
      let wasCancelled = error is CancellationError || Task.isCancelled
      let operationMessage =
        wasCancelled
        ? "macOS installation was cancelled. The pristine prepared media is ready to retry."
        : error.localizedDescription

      do {
        if leaseStarted {
          try await store.abortMacOSInstallation(
            id: id,
            operationID: operationID,
            kind: wasCancelled ? .cancelled : .failed,
            message: operationMessage
          )
        } else {
          try await store.discardStagedMacOSInstallation(
            id: id,
            operationID: operationID
          )
        }
      } catch let persistenceError {
        throw MacVirtualMachineInstallationError.statePersistenceFailed(
          operation: operationMessage,
          persistence: persistenceError.localizedDescription
        )
      }

      if wasCancelled {
        throw CancellationError()
      }
      throw error
    }
  }

  func recoverInterruptedInstallations() async throws {
    try await store.recoverInterruptedMacOSInstallations()
  }
}

@MainActor
struct UnavailableMacVirtualMachineInstaller: MacVirtualMachineInstalling {
  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {
    throw MacVirtualMachineInstallationError.unavailable
  }

  func recoverInterruptedInstallations() async throws {}
}
