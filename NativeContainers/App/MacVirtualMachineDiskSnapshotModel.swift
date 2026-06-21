import Foundation
import Observation

enum MacVirtualMachineDiskSnapshotOperation: Equatable, Sendable {
  case creating
  case restoring(UUID)

  var progressLabel: LocalizedStringResource {
    switch self {
    case .creating:
      "Creating disk snapshot"
    case .restoring:
      "Restoring disk snapshot"
    }
  }
}

@MainActor
@Observable
final class MacVirtualMachineDiskSnapshotModel {
  let machineID: UUID

  private(set) var revision: UInt64
  private(set) var snapshots: [MacVirtualMachineDiskSnapshot]
  private(set) var isLoading = false
  private(set) var operation: MacVirtualMachineDiskSnapshotOperation?
  private(set) var errorMessage: String?
  private(set) var warningMessage: String?

  var isBusy: Bool {
    isLoading || operation != nil
  }

  var isAtLimit: Bool {
    snapshots.count
      >= MacVirtualMachineDiskSnapshotConfiguration.maximumSnapshotCount
  }

  @ObservationIgnored
  private let service: any MacVirtualMachineDiskSnapshotManaging
  @ObservationIgnored
  private let didCommit:
    @MainActor @Sendable (VirtualMachineManifest) async -> Void
  @ObservationIgnored
  private let didSettle: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private var hasLoaded = false

  init(
    machineID: UUID,
    initialConfiguration: MacVirtualMachineDiskSnapshotConfiguration = .empty,
    service: any MacVirtualMachineDiskSnapshotManaging,
    didCommit:
      @escaping @MainActor @Sendable (VirtualMachineManifest) async -> Void = { _ in },
    didSettle: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    revision = initialConfiguration.revision
    snapshots = initialConfiguration.snapshots
    self.service = service
    self.didCommit = didCommit
    self.didSettle = didSettle
  }

  func load() async {
    guard !hasLoaded, !isBusy else { return }

    isLoading = true
    errorMessage = nil
    warningMessage = nil
    defer { isLoading = false }

    do {
      apply(try await service.snapshot(id: machineID))
      hasLoaded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func createSnapshot(named name: String) async -> Bool {
    await perform(.creating) {
      try await service.createSnapshot(named: name, for: machineID)
    }
  }

  @discardableResult
  func restoreSnapshot(id snapshotID: UUID) async -> Bool {
    await perform(.restoring(snapshotID)) {
      try await service.restoreSnapshot(id: snapshotID, for: machineID)
    }
  }

  func clearMessages() {
    errorMessage = nil
    warningMessage = nil
  }

  private func perform(
    _ operation: MacVirtualMachineDiskSnapshotOperation,
    action: () async throws -> MacVirtualMachineDiskSnapshotOperationResult
  ) async -> Bool {
    guard !isBusy else { return false }

    self.operation = operation
    errorMessage = nil
    warningMessage = nil
    var didSucceed = false

    do {
      let result = try await action()
      apply(result.configuration)
      warningMessage = result.cleanupWarning
      hasLoaded = true
      await didCommit(result.manifest)
      didSucceed = true
    } catch is CancellationError {
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }

    await didSettle()
    self.operation = nil
    return didSucceed
  }

  private func apply(
    _ configuration: MacVirtualMachineDiskSnapshotConfiguration
  ) {
    revision = configuration.revision
    snapshots = configuration.snapshots
  }
}
