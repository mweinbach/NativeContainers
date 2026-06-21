import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine disk snapshot model")
@MainActor
struct MacVirtualMachineDiskSnapshotModelTests {
  @Test
  func loadUsesPersistedHistoryOnlyOnce() async throws {
    let initial = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Persisted").configuration
    let service = DiskSnapshotModelService(configuration: initial)
    let model = MacVirtualMachineDiskSnapshotModel(
      machineID: UUID(),
      service: service
    )

    await model.load()
    await model.load()

    #expect(model.snapshots.map(\.name) == ["Persisted"])
    #expect(model.revision == 1)
    #expect(await service.snapshotCount == 1)
  }

  @Test
  func creationPublishesManifestRefreshesRuntimeAndSurfacesCleanupWarning()
    async throws
  {
    let manifest = try makeDiskSnapshotModelManifest()
    let service = DiskSnapshotModelService(
      configuration: .empty,
      manifest: manifest,
      cleanupWarning: "Newer layer cleanup is pending."
    )
    let recorder = DiskSnapshotModelCallbackRecorder()
    let model = MacVirtualMachineDiskSnapshotModel(
      machineID: manifest.id,
      service: service
    ) { manifest in
      recorder.committedManifest = manifest
    } didSettle: {
      recorder.settleCount += 1
    }

    let didCreate = await model.createSnapshot(named: "Before Upgrade")

    #expect(didCreate)
    #expect(model.snapshots.map(\.name) == ["Before Upgrade"])
    #expect(model.warningMessage == "Newer layer cleanup is pending.")
    #expect(recorder.committedManifest?.id == manifest.id)
    #expect(recorder.settleCount == 1)
    #expect(model.operation == nil)
  }

  @Test
  func failedRestoreSettlesWithoutChangingHistory() async throws {
    let initial = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Stable").configuration
    let service = DiskSnapshotModelService(
      configuration: initial,
      operationError: DiskSnapshotModelFixtureError.failed
    )
    let recorder = DiskSnapshotModelCallbackRecorder()
    let model = MacVirtualMachineDiskSnapshotModel(
      machineID: UUID(),
      initialConfiguration: initial,
      service: service
    ) { _ in
      recorder.commitCount += 1
    } didSettle: {
      recorder.settleCount += 1
    }

    let didRestore = await model.restoreSnapshot(
      id: initial.snapshots[0].id
    )

    #expect(!didRestore)
    #expect(model.snapshots == initial.snapshots)
    #expect(model.errorMessage == "Snapshot model fixture failed.")
    #expect(recorder.commitCount == 0)
    #expect(recorder.settleCount == 1)
    #expect(model.operation == nil)
  }
}

private actor DiskSnapshotModelService:
  MacVirtualMachineDiskSnapshotManaging
{
  private var configuration: MacVirtualMachineDiskSnapshotConfiguration
  private var manifest: VirtualMachineManifest?
  private let cleanupWarning: String?
  private let operationError: (any Error)?
  private(set) var snapshotCount = 0

  init(
    configuration: MacVirtualMachineDiskSnapshotConfiguration,
    manifest: VirtualMachineManifest? = nil,
    cleanupWarning: String? = nil,
    operationError: (any Error)? = nil
  ) {
    self.configuration = configuration
    self.manifest = manifest
    self.cleanupWarning = cleanupWarning
    self.operationError = operationError
  }

  func snapshot(
    id: UUID
  ) -> MacVirtualMachineDiskSnapshotConfiguration {
    snapshotCount += 1
    return configuration
  }

  func createSnapshot(
    named name: String,
    for machineID: UUID
  ) throws -> MacVirtualMachineDiskSnapshotOperationResult {
    if let operationError {
      throw operationError
    }
    configuration = try configuration.creatingSnapshot(
      named: name
    ).configuration
    return try result(machineID: machineID)
  }

  func restoreSnapshot(
    id snapshotID: UUID,
    for machineID: UUID
  ) throws -> MacVirtualMachineDiskSnapshotOperationResult {
    if let operationError {
      throw operationError
    }
    configuration = try configuration.restoring(
      snapshotID: snapshotID
    ).configuration
    return try result(machineID: machineID)
  }

  private func result(
    machineID: UUID
  ) throws -> MacVirtualMachineDiskSnapshotOperationResult {
    var updated = try manifest ?? makeDiskSnapshotModelManifest(
      id: machineID
    )
    updated.macOSDiskSnapshotConfiguration = configuration
    manifest = updated
    return MacVirtualMachineDiskSnapshotOperationResult(
      manifest: updated,
      cleanupWarning: cleanupWarning
    )
  }
}

@MainActor
private final class DiskSnapshotModelCallbackRecorder {
  var committedManifest: VirtualMachineManifest?
  var commitCount = 0
  var settleCount = 0
}

private enum DiskSnapshotModelFixtureError: LocalizedError {
  case failed

  var errorDescription: String? {
    "Snapshot model fixture failed."
  }
}

private func makeDiskSnapshotModelManifest(
  id: UUID = UUID()
) throws -> VirtualMachineManifest {
  try VirtualMachineManifest(
    id: id,
    name: "Snapshot Model",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
}
