import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacVirtualMachineSavedStateServiceTests {
  @Test
  func saveCommitsOnlyAfterEngineCallbackSucceeds() async throws {
    let fixture = try SavedStateServiceFixture()
    let store = SavedStateServiceStore(target: fixture.lease.target)
    let service = MacVirtualMachineSavedStateService(store: store)
    let session = SavedStateServiceSession(target: fixture.lease.target)

    let summary = try await service.saveCheckpoint(
      session: session,
      lease: fixture.lease
    )

    let storedSummary = store.summary
    let stateURL = store.saveTransaction.stateURL
    #expect(summary == storedSummary)
    #expect(session.savedURLs == [stateURL])
    #expect(await store.commitCount == 1)
    #expect(await store.abortCount == 0)
  }

  @Test
  func saveFailureAbortsTheMatchingTransaction() async throws {
    let fixture = try SavedStateServiceFixture()
    let store = SavedStateServiceStore(target: fixture.lease.target)
    let service = MacVirtualMachineSavedStateService(store: store)
    let session = SavedStateServiceSession(target: fixture.lease.target)
    session.saveError = .expected

    await #expect(throws: SavedStateServiceTestError.expected) {
      _ = try await service.saveCheckpoint(session: session, lease: fixture.lease)
    }

    #expect(await store.commitCount == 0)
    #expect(await store.abortCount == 1)
  }

  @Test
  func restoreFailureStillFinishesSingleUseTransaction() async throws {
    let fixture = try SavedStateServiceFixture()
    let store = SavedStateServiceStore(target: fixture.lease.target)
    let service = MacVirtualMachineSavedStateService(store: store)
    let session = SavedStateServiceSession(target: fixture.lease.target)
    session.restoreError = .expected

    await #expect(throws: SavedStateServiceTestError.expected) {
      _ = try await service.restoreCheckpoint(session: session, lease: fixture.lease)
    }

    let stateURL = store.restoreTransaction.artifact.stateURL
    #expect(session.restoredURLs == [stateURL])
    #expect(await store.finishRestoreCount == 1)
  }

  @Test
  func successfulRestoreRemainsUsableWhenTombstoneCleanupIsDeferred() async throws {
    let fixture = try SavedStateServiceFixture()
    let store = SavedStateServiceStore(
      target: fixture.lease.target,
      finishRestoreError: .expected
    )
    let service = MacVirtualMachineSavedStateService(store: store)
    let session = SavedStateServiceSession(target: fixture.lease.target)

    let summary = try await service.restoreCheckpoint(
      session: session,
      lease: fixture.lease
    )

    let storedSummary = store.summary
    #expect(summary == storedSummary)
    #expect(await store.finishRestoreCount == 1)
  }
}

private struct SavedStateServiceFixture {
  let lease: MacVirtualMachineRuntimeLease

  init() throws {
    let identifier = UUID()
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    let manifest = try VirtualMachineManifest(
      id: identifier,
      name: "Saved State Service",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    let bundle = URL(
      filePath: "/tmp/\(identifier.uuidString).nativevm",
      directoryHint: .isDirectory
    )
    let machine = ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundle,
      diskImageURL: bundle.appending(path: "Disk.img"),
      auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
      hardwareModelURL: bundle.appending(path: "HardwareModel"),
      machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
    )
    lease = MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: identifier,
        generation: UUID()
      )
    ) {}
  }
}

private actor SavedStateServiceStore: MacVirtualMachineSavedStateStoring {
  let summary = MacVirtualMachineSavedStateSummary(
    createdAt: Date(timeIntervalSince1970: 10),
    stateSizeBytes: 42
  )
  let saveTransaction: MacVirtualMachineSavedStateTransaction
  let restoreTransaction: MacVirtualMachineSavedStateRestoreTransaction
  private let finishRestoreError: SavedStateServiceTestError?
  private(set) var commitCount = 0
  private(set) var abortCount = 0
  private(set) var finishRestoreCount = 0

  init(
    target: MacVirtualMachineRuntimeTarget,
    finishRestoreError: SavedStateServiceTestError? = nil
  ) {
    let operationID = UUID()
    let staging = URL(
      filePath: "/tmp/.SavedState-\(operationID.uuidString).partial",
      directoryHint: .isDirectory
    )
    saveTransaction = MacVirtualMachineSavedStateTransaction(
      operationID: operationID,
      target: target,
      stagingDirectoryURL: staging,
      stateURL: staging.appending(path: "Machine.vzvmsave")
    )
    let restoreOperationID = UUID()
    let restoring = URL(
      filePath: "/tmp/.SavedState-\(restoreOperationID.uuidString).restoring",
      directoryHint: .isDirectory
    )
    let artifact = MacVirtualMachineSavedStateArtifact(
      stateURL: restoring.appending(path: "Machine.vzvmsave"),
      summary: summary,
      configurationFingerprint: "fingerprint"
    )
    restoreTransaction = MacVirtualMachineSavedStateRestoreTransaction(
      operationID: restoreOperationID,
      target: target,
      consumingDirectoryURL: restoring,
      artifact: artifact
    )
    self.finishRestoreError = finishRestoreError
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateStatus {
    .none
  }

  func beginSave(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateTransaction {
    saveTransaction
  }

  func commitSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateSummary {
    commitCount += 1
    return summary
  }

  func abortSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) {
    abortCount += 1
  }

  func beginRestore(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateRestoreTransaction {
    restoreTransaction
  }

  func finishRestore(
    _ transaction: MacVirtualMachineSavedStateRestoreTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) throws {
    finishRestoreCount += 1
    if let finishRestoreError { throw finishRestoreError }
  }

  func discard(for lease: MacVirtualMachineRuntimeLease) {}
}

@MainActor
private final class SavedStateServiceSession: MacVirtualMachineRuntimeEngineSession {
  let target: MacVirtualMachineRuntimeTarget
  let console: MacVirtualMachineConsole? = nil
  let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport = .supported
  let canForceStop = true
  var eventHandler: MacVirtualMachineRuntimeEventHandler?
  var saveError: SavedStateServiceTestError?
  var restoreError: SavedStateServiceTestError?
  private(set) var savedURLs: [URL] = []
  private(set) var restoredURLs: [URL] = []

  init(target: MacVirtualMachineRuntimeTarget) {
    self.target = target
  }

  func start() async throws {}

  func saveState(to url: URL) async throws {
    savedURLs.append(url)
    if let saveError { throw saveError }
  }

  func restoreState(from url: URL) async throws {
    restoredURLs.append(url)
    if let restoreError { throw restoreError }
  }

  func pause() async throws {}
  func resume() async throws {}
  func requestStop() throws {}
  func forceStop() async throws {}
}

private enum SavedStateServiceTestError: LocalizedError {
  case expected

  var errorDescription: String? { "Expected saved-state service failure." }
}
