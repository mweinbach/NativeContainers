import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineDiskImageMigrationModel {
  let machineID: UUID

  private(set) var isMigrating = false
  private(set) var isRefreshing = false
  private(set) var lastResult: VirtualMachineDiskImageMigrationResult?
  private(set) var errorMessage: String?

  var isBusy: Bool {
    isMigrating || isRefreshing
  }

  @ObservationIgnored
  private let service: any VirtualMachineDiskImageMigrating
  @ObservationIgnored
  private let didMutate: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private let didSettle: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private var migrationTask: Task<Void, Never>?

  init(
    machineID: UUID,
    service: any VirtualMachineDiskImageMigrating,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {},
    didSettle: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    self.service = service
    self.didMutate = didMutate
    self.didSettle = didSettle
  }

  func startMigration() {
    guard migrationTask == nil else { return }
    errorMessage = nil
    lastResult = nil
    isMigrating = true
    migrationTask = Task { [weak self] in
      await self?.performMigration()
    }
  }

  func cancelMigration() {
    guard isMigrating else { return }
    migrationTask?.cancel()
  }

  func clearError() {
    errorMessage = nil
  }

  private func performMigration() async {
    var result: VirtualMachineDiskImageMigrationResult?
    var failureMessage: String?
    var didCommitMutation = false

    do {
      result = try await service.migrateToASIF(machineID: machineID)
      didCommitMutation = true
    } catch is CancellationError {
      failureMessage = nil
    } catch let error as VirtualMachineDiskImageMigrationError {
      failureMessage = error.localizedDescription
      if case .committedCleanupPending = error {
        didCommitMutation = true
      } else if case .alreadyASIF = error {
        didCommitMutation = true
      }
    } catch {
      failureMessage = error.localizedDescription
    }

    isMigrating = false
    isRefreshing = true
    let didMutate = didMutate
    let didSettle = didSettle
    await Task { @MainActor in
      if didCommitMutation {
        await didMutate()
      }
      await didSettle()
    }.value
    isRefreshing = false
    lastResult = result
    errorMessage = failureMessage
    migrationTask = nil
  }
}
