import Foundation
import Observation

enum VirtualMachineDiskImageMaintenanceOperation: Equatable, Sendable {
  case migration
  case rewrite
  case resize(UInt64)

  var progressLabel: LocalizedStringResource {
    switch self {
    case .migration:
      "Converting virtual disk"
    case .rewrite:
      "Rewriting virtual disk"
    case .resize:
      "Growing virtual disk"
    }
  }

  var canCancel: Bool {
    switch self {
    case .migration, .rewrite:
      true
    case .resize:
      false
    }
  }
}

enum VirtualMachineDiskImageMaintenanceCompletion: Equatable, Sendable {
  case migration(VirtualMachineDiskImageMigrationResult)
  case rewrite(VirtualMachineDiskImageRewriteResult)
  case resize(VirtualMachineDiskImageResizeResult)
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

  var isResizing: Bool {
    guard case .resize = operation else { return false }
    return !isRefreshing
  }

  @ObservationIgnored
  private let migration: any VirtualMachineDiskImageMigrating
  @ObservationIgnored
  private let rewrite: any VirtualMachineDiskImageRewriting
  @ObservationIgnored
  private let resize: any VirtualMachineDiskImageResizing
  @ObservationIgnored
  private let guest: VirtualMachineGuest
  @ObservationIgnored
  private let didMutate: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private let didSettle: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private var maintenanceTask: Task<Void, Never>?

  init(
    machineID: UUID,
    guest: VirtualMachineGuest = .macOS,
    migration: any VirtualMachineDiskImageMigrating,
    rewrite: any VirtualMachineDiskImageRewriting,
    resize: any VirtualMachineDiskImageResizing =
      UnavailableVirtualMachineDiskImageResizeService(),
    didMutate: @escaping @MainActor @Sendable () async -> Void = {},
    didSettle: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    self.guest = guest
    self.migration = migration
    self.rewrite = rewrite
    self.resize = resize
    self.didMutate = didMutate
    self.didSettle = didSettle
  }

  func startMigration() {
    start(.migration)
  }

  func startRewrite() {
    start(.rewrite)
  }

  func startResize(to targetLogicalBytes: UInt64) {
    start(.resize(targetLogicalBytes))
  }

  func cancelMaintenance() {
    guard operation?.canCancel == true, !isRefreshing else { return }
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
      case .resize(let targetLogicalBytes):
        let result = try await resize.grow(
          machineID: machineID,
          guest: guest,
          to: targetLogicalBytes
        )
        completion = .resize(result)
        didCommitMutation = result.didResize
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
    } catch let error as VirtualMachineDiskImageResizeError {
      failureMessage = error.localizedDescription
      if case .committedCleanupPending = error {
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
