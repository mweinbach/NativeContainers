import Foundation
import Observation

enum VirtualMachineDiskImageMaintenanceOperation: Equatable, Sendable {
  case migration
  case rewrite

  var progressLabel: LocalizedStringResource {
    switch self {
    case .migration:
      "Converting virtual disk"
    case .rewrite:
      "Rewriting virtual disk"
    }
  }
}

enum VirtualMachineDiskImageMaintenanceCompletion: Equatable, Sendable {
  case migration(VirtualMachineDiskImageMigrationResult)
  case rewrite(VirtualMachineDiskImageRewriteResult)
}

@MainActor
@Observable
final class VirtualMachineDiskImageMaintenanceModel {
  let machineID: UUID

  private(set) var operation: VirtualMachineDiskImageMaintenanceOperation?
  private(set) var isRefreshing = false
  private(set) var completion: VirtualMachineDiskImageMaintenanceCompletion?
  private(set) var errorMessage: String?

  var isBusy: Bool {
    operation != nil || isRefreshing
  }

  var isMigrating: Bool {
    operation == .migration && !isRefreshing
  }

  var isRewriting: Bool {
    operation == .rewrite && !isRefreshing
  }

  @ObservationIgnored
  private let migration: any VirtualMachineDiskImageMigrating
  @ObservationIgnored
  private let rewrite: any VirtualMachineDiskImageRewriting
  @ObservationIgnored
  private let didMutate: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private let didSettle: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private var maintenanceTask: Task<Void, Never>?

  init(
    machineID: UUID,
    migration: any VirtualMachineDiskImageMigrating,
    rewrite: any VirtualMachineDiskImageRewriting,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {},
    didSettle: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    self.migration = migration
    self.rewrite = rewrite
    self.didMutate = didMutate
    self.didSettle = didSettle
  }

  func startMigration() {
    start(.migration)
  }

  func startRewrite() {
    start(.rewrite)
  }

  func cancelMaintenance() {
    guard operation != nil, !isRefreshing else { return }
    maintenanceTask?.cancel()
  }

  func clearError() {
    errorMessage = nil
  }

  func clearCompletion() {
    completion = nil
  }

  private func start(_ operation: VirtualMachineDiskImageMaintenanceOperation) {
    guard maintenanceTask == nil else { return }
    errorMessage = nil
    completion = nil
    self.operation = operation
    maintenanceTask = Task { [weak self] in
      await self?.perform(operation)
    }
  }

  private func perform(
    _ operation: VirtualMachineDiskImageMaintenanceOperation
  ) async {
    var completion: VirtualMachineDiskImageMaintenanceCompletion?
    var failureMessage: String?
    var didCommitMutation = false

    do {
      switch operation {
      case .migration:
        let result = try await migration.migrateToASIF(machineID: machineID)
        completion = .migration(result)
        didCommitMutation = result.didReplace
      case .rewrite:
        let result = try await rewrite.rewriteASIF(machineID: machineID)
        completion = .rewrite(result)
        didCommitMutation = result.didReplace
      }
    } catch is CancellationError {
      failureMessage = nil
    } catch let error as VirtualMachineDiskImageReplacementError {
      failureMessage = error.localizedDescription
      if case .committedCleanupPending = error {
        didCommitMutation = true
      } else if operation == .migration, case .alreadyASIF = error {
        didCommitMutation = true
      }
    } catch {
      failureMessage = error.localizedDescription
    }

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
    self.completion = completion
    errorMessage = failureMessage
    self.operation = nil
    maintenanceTask = nil
  }
}
