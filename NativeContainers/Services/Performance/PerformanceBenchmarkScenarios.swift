import ContainerResource
import Foundation
import Network

struct InventoryPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.warmInventory

  private let inventory: any ContainerInventoryLoading

  init(inventory: any ContainerInventoryLoading) {
    self.inventory = inventory
  }

  func perform() async throws -> Int64? {
    _ = try await inventory.loadInventory()
    return nil
  }
}

struct ContainerStartupBenchmarkObservation: Equatable, Sendable {
  let state: RuntimeState
  let startedAt: Date?
  let operationID: UUID?
  let imageReference: String
  let imageDigest: String
}

protocol ContainerStartupBenchmarkStateReading: Sendable {
  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation
  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation?
}

struct AppleContainerStartupBenchmarkStateReader:
  ContainerStartupBenchmarkStateReading
{
  private let snapshots: any ContainerSnapshotReading

  init(
    snapshots: any ContainerSnapshotReading = AppleContainerSnapshotReader()
  ) {
    self.snapshots = snapshots
  }

  func observation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation {
    Self.observation(from: try await snapshots.get(id: id))
  }

  func listedObservation(
    forContainerID id: String
  ) async throws -> ContainerStartupBenchmarkObservation? {
    guard let snapshot = try await snapshots.list().first(where: { $0.id == id }) else {
      return nil
    }
    return Self.observation(from: snapshot)
  }

  private static func observation(
    from snapshot: ContainerSnapshot
  ) -> ContainerStartupBenchmarkObservation {
    ContainerStartupBenchmarkObservation(
      state: RuntimeState(rawValue: snapshot.status.rawValue) ?? .unknown,
      startedAt: snapshot.startedDate,
      operationID: snapshot.configuration.labels[
        AppleContainerOwnership.creationOperationLabel
      ].flatMap { UUID(uuidString: $0) },
      imageReference: snapshot.configuration.image.reference,
      imageDigest: snapshot.configuration.image.digest
    )
  }
}

actor ColdContainerStartupPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.coldContainerStartup

  private struct PreparedContainer: Sendable {
    let id: String
    let operationID: UUID
    var didCreate: Bool
  }

  private let containers: any ContainerCreating & ContainerLifecycleManaging
  private let stateReader: any ContainerStartupBenchmarkStateReading
  private let imageReference: String
  private let expectedImageDigest: String
  private let attachments: ContainerAttachmentSelection
  private let makeContainerID: @Sendable () -> String
  private var preparedContainer: PreparedContainer?

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    attachments: ContainerAttachmentSelection = .empty,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-perf-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) {
    self.containers = containers
    self.stateReader = stateReader
    self.imageReference = imageReference
    self.expectedImageDigest = expectedImageDigest
    self.attachments = attachments
    self.makeContainerID = makeContainerID
  }

  func prepareIteration() async throws {
    guard preparedContainer == nil else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }

    let id = makeContainerID()
    let operationID = UUID()
    preparedContainer = PreparedContainer(
      id: id,
      operationID: operationID,
      didCreate: false
    )
    let request = try ContainerCreationRequest(
      operationID: operationID,
      name: id,
      imageReference: imageReference,
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/sleep", "3600"],
      attachments: attachments,
      startAfterCreation: false,
      removeWhenStopped: false
    )
    try await containers.createContainer(request: request) { _ in }
    preparedContainer?.didCreate = true

    let observation = try await requireReviewedObservation(
      id: id,
      operationID: operationID
    )
    guard observation.state == .stopped, observation.startedAt == nil else {
      throw ColdContainerStartupBenchmarkError.containerWasNotPrepared(id)
    }
  }

  func prepareMeasurement() async throws {
    try await validateCurrentContainer(expectedState: .stopped)
  }

  func perform() async throws -> Int64? {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }

    try await containers.startContainer(id: preparedContainer.id)
    try await validateCurrentContainer(expectedState: .running)
    return nil
  }

  func currentContainerID() throws -> String {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }
    return preparedContainer.id
  }

  func validateCurrentContainer(expectedState: RuntimeState) async throws {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }
    let observation = try await requireReviewedObservation(
      id: preparedContainer.id,
      operationID: preparedContainer.operationID
    )
    guard observation.state == expectedState else {
      throw ColdContainerStartupBenchmarkError.unexpectedState(
        id: preparedContainer.id,
        expected: expectedState,
        actual: observation.state
      )
    }
    if expectedState == .running, observation.startedAt == nil {
      throw ColdContainerStartupBenchmarkError.startNotConfirmed(
        preparedContainer.id
      )
    }
  }

  func cleanUpIteration() async throws {
    guard let preparedContainer else { return }
    self.preparedContainer = nil
    guard preparedContainer.didCreate else { return }

    do {
      try await stopIfNeeded(preparedContainer)
      _ = try await requireOwnedObservation(
        id: preparedContainer.id,
        operationID: preparedContainer.operationID
      )
      try await containers.deleteContainer(id: preparedContainer.id)
      try await requireReviewedContainerAbsent(preparedContainer)
    } catch {
      let operation = error.localizedDescription
      do {
        try await forceDelete(preparedContainer)
      } catch {
        throw ColdContainerStartupBenchmarkError.cleanupFailed(
          id: preparedContainer.id,
          operation: operation,
          recovery: error.localizedDescription
        )
      }
      throw ColdContainerStartupBenchmarkError.cleanupRequiredRecovery(
        id: preparedContainer.id,
        operation: operation
      )
    }
  }

  private func stopIfNeeded(_ container: PreparedContainer) async throws {
    let observation = try await requireOwnedObservation(
      id: container.id,
      operationID: container.operationID
    )
    guard observation.state != .stopped else { return }

    do {
      try await containers.stopContainer(id: container.id)
      try await waitForStoppedContainer(container)
    } catch {
      _ = try await requireOwnedObservation(
        id: container.id,
        operationID: container.operationID
      )
      try await containers.forceStopContainer(id: container.id)
      try await waitForStoppedContainer(container)
    }
  }

  private func forceDelete(_ container: PreparedContainer) async throws {
    guard
      let observation = try await stateReader.listedObservation(
        forContainerID: container.id
      )
    else {
      return
    }
    guard observation.operationID == container.operationID else {
      throw ColdContainerStartupBenchmarkError.replacementPresent(container.id)
    }

    if observation.state != .stopped {
      try? await containers.forceStopContainer(id: container.id)
      try? await waitForStoppedContainer(container)
    }
    _ = try await requireOwnedObservation(
      id: container.id,
      operationID: container.operationID
    )
    try await containers.deleteContainer(id: container.id)
    try await requireReviewedContainerAbsent(container)
  }

  private func waitForStoppedContainer(
    _ container: PreparedContainer
  ) async throws {
    for _ in 0..<100 {
      let observation = try await requireOwnedObservation(
        id: container.id,
        operationID: container.operationID
      )
      if observation.state == .stopped {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ColdContainerStartupBenchmarkError.stopTimedOut(container.id)
  }

  private func requireOwnedObservation(
    id: String,
    operationID: UUID
  ) async throws -> ContainerStartupBenchmarkObservation {
    let observation = try await stateReader.observation(forContainerID: id)
    guard observation.operationID == operationID else {
      throw ColdContainerStartupBenchmarkError.identityChanged(id)
    }
    return observation
  }

  private func requireReviewedObservation(
    id: String,
    operationID: UUID
  ) async throws -> ContainerStartupBenchmarkObservation {
    let observation = try await requireOwnedObservation(
      id: id,
      operationID: operationID
    )
    guard
      observation.imageReference == imageReference,
      observation.imageDigest == expectedImageDigest
    else {
      throw ColdContainerStartupBenchmarkError.imageIdentityChanged(id)
    }
    return observation
  }

  private func requireReviewedContainerAbsent(
    _ container: PreparedContainer
  ) async throws {
    guard
      let remaining = try await stateReader.listedObservation(
        forContainerID: container.id
      )
    else {
      return
    }
    guard remaining.operationID == container.operationID else {
      throw ColdContainerStartupBenchmarkError.replacementPresent(container.id)
    }
    throw ColdContainerStartupBenchmarkError.deletionNotConfirmed(container.id)
  }
}

enum ColdContainerStartupBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidIterationState
  case containerWasNotPrepared(String)
  case startNotConfirmed(String)
  case identityChanged(String)
  case imageIdentityChanged(String)
  case unexpectedState(id: String, expected: RuntimeState, actual: RuntimeState)
  case replacementPresent(String)
  case stopTimedOut(String)
  case deletionNotConfirmed(String)
  case cleanupRequiredRecovery(id: String, operation: String)
  case cleanupFailed(id: String, operation: String, recovery: String)

  var errorDescription: String? {
    switch self {
    case .invalidIterationState:
      "The cold-start benchmark iteration is not in a valid state."
    case .containerWasNotPrepared(let id):
      "Benchmark container “\(id)” was not prepared in the stopped state."
    case .startNotConfirmed(let id):
      "Benchmark container “\(id)” did not reach an authoritative running state."
    case .identityChanged(let id):
      "Benchmark container “\(id)” changed after preparation."
    case .imageIdentityChanged(let id):
      "Benchmark container “\(id)” does not use the reviewed image identity."
    case .unexpectedState(let id, let expected, let actual):
      "Benchmark container “\(id)” is \(actual.rawValue), not \(expected.rawValue)."
    case .replacementPresent(let id):
      "A replacement named “\(id)” appeared during benchmark cleanup and was not modified."
    case .stopTimedOut(let id):
      "Benchmark container “\(id)” did not stop within five seconds."
    case .deletionNotConfirmed(let id):
      "Benchmark container “\(id)” remained after cleanup."
    case .cleanupRequiredRecovery(let id, let operation):
      "Benchmark container “\(id)” required force-cleanup after: \(operation)"
    case .cleanupFailed(let id, let operation, let recovery):
      "Benchmark container “\(id)” cleanup failed after “\(operation)”: \(recovery)"
    }
  }
}

protocol LinuxMachineStartupBenchmarkStateReading: Sendable {
  func snapshot(id: String) async throws -> LinuxMachineRuntimeSnapshot?
}

extension AppleMachineRuntimeClient: LinuxMachineStartupBenchmarkStateReading {}

actor ColdLinuxMachineStartupPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.coldLinuxMachineStartup

  private struct PreparedMachine: Sendable {
    let id: String
    var identity: LinuxMachineIdentity?
  }

  private let machines: any MachineCreating & MachineLifecycleManaging
  private let stateReader: any LinuxMachineStartupBenchmarkStateReading
  private let imageReference: String
  private let expectedImageDigest: String
  private let expectedPlatform: String
  private let makeMachineID: @Sendable () -> String
  private var preparedMachine: PreparedMachine?

  init(
    machines: any MachineCreating & MachineLifecycleManaging,
    stateReader: any LinuxMachineStartupBenchmarkStateReading,
    imageReference: String = "docker.io/library/alpine:3.22",
    expectedImageDigest: String,
    expectedPlatform: String = "linux/arm64",
    makeMachineID: @escaping @Sendable () -> String = {
      "nativecontainers-vm-\(UUID().uuidString.lowercased())"
    }
  ) {
    self.machines = machines
    self.stateReader = stateReader
    self.imageReference = imageReference
    self.expectedImageDigest = expectedImageDigest
    self.expectedPlatform = expectedPlatform
    self.makeMachineID = makeMachineID
  }

  func prepareIteration() async throws {
    guard preparedMachine == nil else {
      throw ColdLinuxMachineStartupBenchmarkError.invalidIterationState
    }

    let id = makeMachineID()
    preparedMachine = PreparedMachine(id: id, identity: nil)
    let request = try LinuxMachineCreationRequest(
      name: id,
      imageReference: imageReference,
      architecture: .arm64,
      cpuCount: 1,
      memoryBytes: LinuxMachineCreationRequest.minimumMemoryBytes,
      homeMount: .none,
      startAfterCreation: false
    )

    do {
      let result = try await machines.createMachine(request: request) { _ in }
      preparedMachine?.identity = result.identity
      try validateIdentity(result.identity, expectedID: id)
      guard result.state == .stopped, !result.isInitialized else {
        throw ColdLinuxMachineStartupBenchmarkError.machineWasNotPrepared(id)
      }
      let snapshot = try await requireReviewedSnapshot(result.identity)
      guard
        snapshot.state == .stopped,
        !snapshot.isInitialized,
        snapshot.startedAt == nil
      else {
        throw ColdLinuxMachineStartupBenchmarkError.machineWasNotPrepared(id)
      }
    } catch {
      if let partial = error as? LinuxMachinePartialCompletionError {
        preparedMachine?.identity = partial.result.identity
      } else if preparedMachine?.identity == nil {
        await adoptReviewedMachineIfPresent(id: id)
      }
      throw error
    }
  }

  func prepareMeasurement() async throws {
    let identity = try currentIdentity()
    let snapshot = try await requireReviewedSnapshot(identity)
    guard
      snapshot.state == .stopped,
      !snapshot.isInitialized,
      snapshot.startedAt == nil
    else {
      throw ColdLinuxMachineStartupBenchmarkError.machineWasNotPrepared(
        identity.id
      )
    }
  }

  func perform() async throws -> Int64? {
    let identity = try currentIdentity()
    try await machines.startMachine(identity)
    let snapshot = try await requireReviewedSnapshot(identity)
    guard
      snapshot.state == .running,
      snapshot.isInitialized,
      snapshot.startedAt != nil
    else {
      throw ColdLinuxMachineStartupBenchmarkError.startupNotConfirmed(
        identity.id
      )
    }
    return nil
  }

  func cleanUpIteration() async throws {
    guard let preparedMachine else { return }
    self.preparedMachine = nil

    do {
      let identity: LinuxMachineIdentity
      if let preparedIdentity = preparedMachine.identity {
        identity = preparedIdentity
      } else {
        guard
          let current = try await stateReader.snapshot(id: preparedMachine.id)
        else {
          return
        }
        try validateReviewedSnapshot(
          current,
          expectedID: preparedMachine.id
        )
        identity = current.identity
      }

      guard
        var current = try await ownedSnapshotIfPresent(identity)
      else {
        return
      }
      if current.state != .stopped {
        do {
          try await machines.stopMachine(identity)
        } catch {
          current = try await requireOwnedSnapshot(identity)
          if current.state != .stopped {
            try await machines.forceStopMachine(
              identity,
              authorization: .confirmed(for: identity)
            )
          }
        }
        current = try await requireOwnedSnapshot(identity)
        guard current.state == .stopped else {
          throw ColdLinuxMachineStartupBenchmarkError.stopNotConfirmed(
            identity.id
          )
        }
      }

      do {
        try await machines.deleteMachine(identity)
      } catch {
        guard let remaining = try await stateReader.snapshot(id: identity.id)
        else {
          return
        }
        guard remaining.identity == identity else {
          throw ColdLinuxMachineStartupBenchmarkError.replacementPresent(
            identity.id
          )
        }
        throw error
      }
      guard let remaining = try await stateReader.snapshot(id: identity.id)
      else {
        return
      }
      guard remaining.identity == identity else {
        throw ColdLinuxMachineStartupBenchmarkError.replacementPresent(
          identity.id
        )
      }
      throw ColdLinuxMachineStartupBenchmarkError.deletionNotConfirmed(
        identity.id
      )
    } catch let error as ColdLinuxMachineStartupBenchmarkError {
      throw error
    } catch {
      throw ColdLinuxMachineStartupBenchmarkError.cleanupFailed(
        id: preparedMachine.id,
        operation: error.localizedDescription
      )
    }
  }

  private func currentIdentity() throws -> LinuxMachineIdentity {
    guard let identity = preparedMachine?.identity else {
      throw ColdLinuxMachineStartupBenchmarkError.invalidIterationState
    }
    return identity
  }

  private func adoptReviewedMachineIfPresent(id: String) async {
    do {
      guard let snapshot = try await stateReader.snapshot(id: id) else {
        return
      }
      try validateReviewedSnapshot(snapshot, expectedID: id)
      preparedMachine?.identity = snapshot.identity
    } catch {
      return
    }
  }

  private func ownedSnapshotIfPresent(
    _ identity: LinuxMachineIdentity
  ) async throws -> LinuxMachineRuntimeSnapshot? {
    guard let snapshot = try await stateReader.snapshot(id: identity.id) else {
      return nil
    }
    guard snapshot.identity == identity else {
      throw ColdLinuxMachineStartupBenchmarkError.identityChanged(identity.id)
    }
    return snapshot
  }

  private func requireOwnedSnapshot(
    _ identity: LinuxMachineIdentity
  ) async throws -> LinuxMachineRuntimeSnapshot {
    guard let snapshot = try await ownedSnapshotIfPresent(identity) else {
      throw ColdLinuxMachineStartupBenchmarkError.machineMissing(identity.id)
    }
    return snapshot
  }

  private func requireReviewedSnapshot(
    _ identity: LinuxMachineIdentity
  ) async throws -> LinuxMachineRuntimeSnapshot {
    let snapshot = try await requireOwnedSnapshot(identity)
    try validateReviewedSnapshot(snapshot, expectedID: identity.id)
    return snapshot
  }

  private func validateIdentity(
    _ identity: LinuxMachineIdentity,
    expectedID: String
  ) throws {
    guard identity.hasStableCreationIdentity else {
      throw ColdLinuxMachineStartupBenchmarkError.unstableIdentity(expectedID)
    }
    guard
      identity.id == expectedID,
      identity.imageReference == imageReference,
      identity.platform == expectedPlatform
    else {
      throw ColdLinuxMachineStartupBenchmarkError.imageIdentityChanged(
        expectedID
      )
    }
  }

  private func validateReviewedSnapshot(
    _ snapshot: LinuxMachineRuntimeSnapshot,
    expectedID: String
  ) throws {
    try validateIdentity(snapshot.identity, expectedID: expectedID)
    guard snapshot.imageDigest == expectedImageDigest else {
      throw ColdLinuxMachineStartupBenchmarkError.imageIdentityChanged(
        expectedID
      )
    }
  }
}

enum ColdLinuxMachineStartupBenchmarkError:
  LocalizedError,
  Equatable,
  Sendable
{
  case invalidIterationState
  case machineWasNotPrepared(String)
  case unstableIdentity(String)
  case machineMissing(String)
  case identityChanged(String)
  case imageIdentityChanged(String)
  case startupNotConfirmed(String)
  case stopNotConfirmed(String)
  case replacementPresent(String)
  case deletionNotConfirmed(String)
  case cleanupFailed(id: String, operation: String)

  var errorDescription: String? {
    switch self {
    case .invalidIterationState:
      "The cold Linux-machine benchmark iteration is not in a valid state."
    case .machineWasNotPrepared(let id):
      "Benchmark Linux machine “\(id)” was not prepared in a fresh stopped state."
    case .unstableIdentity(let id):
      "Benchmark Linux machine “\(id)” has no stable creation identity."
    case .machineMissing(let id):
      "Benchmark Linux machine “\(id)” is missing."
    case .identityChanged(let id):
      "Benchmark Linux machine “\(id)” changed after preparation."
    case .imageIdentityChanged(let id):
      "Benchmark Linux machine “\(id)” does not use the reviewed image identity."
    case .startupNotConfirmed(let id):
      "Benchmark Linux machine “\(id)” did not reach initialized running readiness."
    case .stopNotConfirmed(let id):
      "Benchmark Linux machine “\(id)” did not confirm its stopped state."
    case .replacementPresent(let id):
      "A replacement Linux machine named “\(id)” appeared during benchmark cleanup and was not modified."
    case .deletionNotConfirmed(let id):
      "Benchmark Linux machine “\(id)” remained after cleanup."
    case .cleanupFailed(let id, let operation):
      "Benchmark Linux machine “\(id)” cleanup failed: \(operation)"
    }
  }
}

protocol MacVirtualMachineStartupBenchmarkRuntime: Sendable {
  func refreshSavedState(id: UUID) async
  func snapshot(id: UUID) async -> MacVirtualMachineRuntimeSnapshot
  func start(id: UUID) async throws
  func requestStop(target: MacVirtualMachineRuntimeTarget) async throws
  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws
  func hasConsole(for target: MacVirtualMachineRuntimeTarget) async -> Bool
}

struct AppleMacVirtualMachineStartupBenchmarkRuntime:
  MacVirtualMachineStartupBenchmarkRuntime
{
  private let runtime: any MacVirtualMachineRuntimeManaging

  init(runtime: any MacVirtualMachineRuntimeManaging) {
    self.runtime = runtime
  }

  func refreshSavedState(id: UUID) async {
    await runtime.refreshSavedState(id: id)
  }

  func snapshot(id: UUID) async -> MacVirtualMachineRuntimeSnapshot {
    await runtime.snapshot(for: id)
  }

  func start(id: UUID) async throws {
    try await runtime.start(id: id)
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) async throws {
    try await runtime.requestStop(target: target)
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    try await runtime.forceStop(target: target)
  }

  func hasConsole(for target: MacVirtualMachineRuntimeTarget) async -> Bool {
    await MainActor.run {
      runtime.console(for: target) != nil
    }
  }
}

actor ColdMacVirtualMachineStartupPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.coldMacVirtualMachineStartup

  private struct PreparedClone: Sendable {
    let manifest: VirtualMachineManifest
    var preflightRevision: UInt64?
    var runtimeTarget: MacVirtualMachineRuntimeTarget?
  }

  private let source: VirtualMachineManifest
  private let inventory: any VirtualMachineInventoryLoading
  private let cloner: any VirtualMachineCloning
  private let discarder: any VirtualMachineIdentityDiscarding
  private let runtime: any MacVirtualMachineStartupBenchmarkRuntime
  private let makeCloneName: @Sendable () -> String
  private var preparedClone: PreparedClone?

  init(
    source: VirtualMachineManifest,
    inventory: any VirtualMachineInventoryLoading,
    cloner: any VirtualMachineCloning,
    discarder: any VirtualMachineIdentityDiscarding,
    runtime: any MacVirtualMachineStartupBenchmarkRuntime,
    makeCloneName: @escaping @Sendable () -> String = {
      "NativeContainers Performance \(UUID().uuidString.lowercased().prefix(8))"
    }
  ) {
    self.source = source
    self.inventory = inventory
    self.cloner = cloner
    self.discarder = discarder
    self.runtime = runtime
    self.makeCloneName = makeCloneName
  }

  func prepareIteration() async throws {
    guard preparedClone == nil else {
      throw ColdMacVirtualMachineStartupBenchmarkError.invalidIterationState
    }
    try validateSource(try await requireManifest(source.id))

    let name = makeCloneName()
    let clone = try await cloner.cloneVirtualMachine(id: source.id, name: name)
    preparedClone = PreparedClone(
      manifest: clone,
      preflightRevision: nil,
      runtimeTarget: nil
    )
    try validateClone(clone, expectedName: name)
    _ = try await requireExactClone(clone)
    try validateSource(try await requireManifest(source.id))
    await runtime.refreshSavedState(id: clone.id)
  }

  func prepareMeasurement() async throws {
    guard var preparedClone else {
      throw ColdMacVirtualMachineStartupBenchmarkError.invalidIterationState
    }
    _ = try await requireExactClone(preparedClone.manifest)
    try validateSource(try await requireManifest(source.id))

    let snapshot = await runtime.snapshot(id: preparedClone.manifest.id)
    guard
      snapshot.machineID == preparedClone.manifest.id,
      snapshot.target == nil,
      snapshot.state == .stopped,
      snapshot.savedStateStatus == .none,
      snapshot.errorMessage == nil
    else {
      throw ColdMacVirtualMachineStartupBenchmarkError.cloneWasNotPrepared(
        preparedClone.manifest.id
      )
    }
    preparedClone.preflightRevision = snapshot.revision
    self.preparedClone = preparedClone
  }

  func perform() async throws -> Int64? {
    guard
      var preparedClone,
      let preflightRevision = preparedClone.preflightRevision
    else {
      throw ColdMacVirtualMachineStartupBenchmarkError.invalidIterationState
    }

    try await runtime.start(id: preparedClone.manifest.id)
    let snapshot = await runtime.snapshot(id: preparedClone.manifest.id)
    if let target = snapshot.target {
      preparedClone.runtimeTarget = target
      self.preparedClone = preparedClone
    }
    guard
      snapshot.machineID == preparedClone.manifest.id,
      snapshot.revision > preflightRevision,
      let target = snapshot.target,
      target.machineID == preparedClone.manifest.id,
      snapshot.state == .running,
      snapshot.savedStateStatus == .none,
      snapshot.errorMessage == nil
    else {
      throw ColdMacVirtualMachineStartupBenchmarkError.startupNotConfirmed(
        preparedClone.manifest.id
      )
    }
    guard await runtime.hasConsole(for: target) else {
      throw ColdMacVirtualMachineStartupBenchmarkError.consoleNotReady(
        preparedClone.manifest.id
      )
    }
    return nil
  }

  func cleanUpIteration() async throws {
    guard let preparedClone else { return }
    self.preparedClone = nil

    do {
      guard let current = try await manifestIfPresent(preparedClone.manifest.id) else {
        try validateSource(try await requireManifest(source.id))
        return
      }
      guard current == preparedClone.manifest else {
        throw ColdMacVirtualMachineStartupBenchmarkError.cloneIdentityChanged(
          preparedClone.manifest.id
        )
      }

      var snapshot = await runtime.snapshot(id: preparedClone.manifest.id)
      if let reviewedTarget = preparedClone.runtimeTarget,
        let currentTarget = snapshot.target,
        currentTarget != reviewedTarget
      {
        throw ColdMacVirtualMachineStartupBenchmarkError.runtimeIdentityChanged(
          preparedClone.manifest.id
        )
      }

      if snapshot.canRequestStop, let target = snapshot.target {
        do {
          try await runtime.requestStop(target: target)
          snapshot = await waitForStoppedClone(id: preparedClone.manifest.id)
        } catch {
          snapshot = await runtime.snapshot(id: preparedClone.manifest.id)
        }
      }
      if snapshot.state != .stopped || snapshot.target != nil {
        guard let target = snapshot.target else {
          throw ColdMacVirtualMachineStartupBenchmarkError.stopNotConfirmed(
            preparedClone.manifest.id
          )
        }
        if let reviewedTarget = preparedClone.runtimeTarget,
          target != reviewedTarget
        {
          throw ColdMacVirtualMachineStartupBenchmarkError.runtimeIdentityChanged(
            preparedClone.manifest.id
          )
        }
        try await runtime.forceStop(target: target)
        snapshot = await waitForStoppedClone(id: preparedClone.manifest.id)
      }
      guard snapshot.state == .stopped, snapshot.target == nil else {
        throw ColdMacVirtualMachineStartupBenchmarkError.stopNotConfirmed(
          preparedClone.manifest.id
        )
      }

      _ = try await requireExactClone(preparedClone.manifest)
      try await discarder.discardVirtualMachine(
        ifUnchanged: preparedClone.manifest
      )
      if let remaining = try await manifestIfPresent(preparedClone.manifest.id) {
        guard remaining == preparedClone.manifest else {
          throw ColdMacVirtualMachineStartupBenchmarkError.replacementPresent(
            preparedClone.manifest.id
          )
        }
        throw ColdMacVirtualMachineStartupBenchmarkError.deletionNotConfirmed(
          preparedClone.manifest.id
        )
      }
      try validateSource(try await requireManifest(source.id))
    } catch let error as ColdMacVirtualMachineStartupBenchmarkError {
      throw error
    } catch {
      throw ColdMacVirtualMachineStartupBenchmarkError.cleanupFailed(
        id: preparedClone.manifest.id,
        operation: error.localizedDescription
      )
    }
  }

  private func waitForStoppedClone(
    id: UUID
  ) async -> MacVirtualMachineRuntimeSnapshot {
    var snapshot = await runtime.snapshot(id: id)
    for _ in 0..<100 where snapshot.state != .stopped || snapshot.target != nil {
      try? await Task.sleep(for: .milliseconds(50))
      snapshot = await runtime.snapshot(id: id)
    }
    return snapshot
  }

  private func requireManifest(_ id: UUID) async throws -> VirtualMachineManifest {
    guard let manifest = try await manifestIfPresent(id) else {
      throw ColdMacVirtualMachineStartupBenchmarkError.machineMissing(id)
    }
    return manifest
  }

  private func manifestIfPresent(_ id: UUID) async throws -> VirtualMachineManifest? {
    try await inventory.list().first { $0.id == id }
  }

  private func requireExactClone(
    _ expected: VirtualMachineManifest
  ) async throws -> VirtualMachineManifest {
    guard let current = try await manifestIfPresent(expected.id) else {
      throw ColdMacVirtualMachineStartupBenchmarkError.machineMissing(expected.id)
    }
    guard current == expected else {
      throw ColdMacVirtualMachineStartupBenchmarkError.cloneIdentityChanged(expected.id)
    }
    return current
  }

  private func validateSource(_ current: VirtualMachineManifest) throws {
    guard current == source else {
      throw ColdMacVirtualMachineStartupBenchmarkError.sourceIdentityChanged(source.id)
    }
    guard
      current.guest == .macOS,
      current.installState == .stopped,
      current.macOSGuestOperatingSystem != nil,
      current.macOSFirstBootState == .started,
      current.restoreImageURL == nil,
      current.auxiliaryStoragePath != nil,
      current.hardwareModelPath != nil,
      current.machineIdentifierPath != nil
    else {
      throw ColdMacVirtualMachineStartupBenchmarkError.sourceNotReady(source.id)
    }
  }

  private func validateClone(
    _ clone: VirtualMachineManifest,
    expectedName: String
  ) throws {
    guard
      clone.id != source.id,
      clone.name == expectedName,
      clone.guest == source.guest,
      clone.installState == .stopped,
      clone.resources == source.resources,
      clone.effectiveDiskImageFormat == source.effectiveDiskImageFormat,
      clone.macOSGuestOperatingSystem == source.macOSGuestOperatingSystem,
      clone.macOSFirstBootState == .started,
      clone.restoreImageURL == nil,
      clone.installationOperationID == nil,
      clone.installationFailure == nil
    else {
      throw ColdMacVirtualMachineStartupBenchmarkError.invalidClone(clone.id)
    }
  }
}

enum ColdMacVirtualMachineStartupBenchmarkError:
  LocalizedError,
  Equatable,
  Sendable
{
  case invalidIterationState
  case machineMissing(UUID)
  case sourceIdentityChanged(UUID)
  case sourceNotReady(UUID)
  case invalidClone(UUID)
  case cloneIdentityChanged(UUID)
  case cloneWasNotPrepared(UUID)
  case runtimeIdentityChanged(UUID)
  case startupNotConfirmed(UUID)
  case consoleNotReady(UUID)
  case stopNotConfirmed(UUID)
  case replacementPresent(UUID)
  case deletionNotConfirmed(UUID)
  case cleanupFailed(id: UUID, operation: String)

  var errorDescription: String? {
    switch self {
    case .invalidIterationState:
      "The cold macOS virtual-machine benchmark iteration is not in a valid state."
    case .machineMissing(let id):
      "Benchmark macOS virtual machine \(id.uuidString) is missing."
    case .sourceIdentityChanged(let id):
      "Source macOS virtual machine \(id.uuidString) changed after review."
    case .sourceNotReady(let id):
      "Source macOS virtual machine \(id.uuidString) must be installed, stopped, and through first boot."
    case .invalidClone(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) does not match the reviewed source."
    case .cloneIdentityChanged(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) changed after preparation."
    case .cloneWasNotPrepared(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) was not prepared without saved state."
    case .runtimeIdentityChanged(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) changed runtime generation."
    case .startupNotConfirmed(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) did not reach authoritative running readiness."
    case .consoleNotReady(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) did not expose its graphical console."
    case .stopNotConfirmed(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) did not confirm its stopped state."
    case .replacementPresent(let id):
      "A replacement macOS virtual machine with identifier \(id.uuidString) appeared during cleanup and was not modified."
    case .deletionNotConfirmed(let id):
      "Benchmark macOS virtual machine clone \(id.uuidString) remained after cleanup."
    case .cleanupFailed(let id, let operation):
      "Benchmark macOS virtual machine clone \(id.uuidString) cleanup failed: \(operation)"
    }
  }
}

enum ContainerIOPerformanceStorage: Equatable, Sendable {
  case guestRoot
  case bindMount

  var kind: PerformanceBenchmarkKind {
    switch self {
    case .guestRoot:
      .guestRootFileIO
    case .bindMount:
      .bindMountFileIO
    }
  }

  var targetPath: String {
    switch self {
    case .guestRoot:
      "/tmp/nativecontainers-performance.bin"
    case .bindMount:
      "/workspace/nativecontainers-performance.bin"
    }
  }
}

actor ContainerIOPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  private static let successMarker = "nativecontainers-io-ok"
  private static let workload = """
    set -eu
    target=$1
    count=$2
    cleanup() { rm -f -- "$target"; }
    trap cleanup EXIT HUP INT TERM
    dd if=/dev/zero of="$target" bs=1048576 count="$count" conv=fsync 2>/dev/null
    dd if="$target" of=/dev/null bs=1048576 2>/dev/null
    printf '%s\\n' nativecontainers-io-ok
    """

  nonisolated let kind: PerformanceBenchmarkKind

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let commands: any ContainerCommandRunning
  private let storage: ContainerIOPerformanceStorage
  private let payloadMebibytes: Int

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    commands: any ContainerCommandRunning,
    storage: ContainerIOPerformanceStorage,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    attachments: ContainerAttachmentSelection = .empty,
    payloadMebibytes: Int = 16,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-io-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) throws {
    if storage == .bindMount {
      guard
        attachments.hostDirectoryMounts.contains(where: {
          $0.containerPath == "/workspace" && !$0.isReadOnly
        })
      else {
        throw ContainerIOPerformanceBenchmarkError.missingWritableBindMount
      }
    }

    kind = storage.kind
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      attachments: attachments,
      makeContainerID: makeContainerID
    )
    self.commands = commands
    self.storage = storage
    self.payloadMebibytes = min(128, max(1, payloadMebibytes))
  }

  func prepareIteration() async throws {
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
  }

  func prepareMeasurement() async throws {
    try await lifecycle.validateCurrentContainer(expectedState: .running)
  }

  func perform() async throws -> Int64? {
    let id = try await lifecycle.currentContainerID()
    let result = try await commands.executeCommand(
      in: id,
      request: ContainerCommandRequest(
        executable: "/bin/sh",
        arguments: [
          "-c",
          Self.workload,
          "nativecontainers-io",
          storage.targetPath,
          String(payloadMebibytes),
        ],
        timeoutSeconds: 180
      )
    )
    guard !result.outputWasTruncated else {
      throw ContainerIOPerformanceBenchmarkError.outputWasTruncated
    }
    guard result.exitCode == 0 else {
      throw ContainerIOPerformanceBenchmarkError.commandFailed(result.exitCode)
    }
    guard
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        == Self.successMarker
    else {
      throw ContainerIOPerformanceBenchmarkError.invalidSuccessMarker
    }
    try await lifecycle.validateCurrentContainer(expectedState: .running)
    return Int64(payloadMebibytes) * 2 * 1_048_576
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }
}

enum ContainerIOPerformanceBenchmarkError: LocalizedError, Equatable, Sendable {
  case missingWritableBindMount
  case commandFailed(Int32)
  case outputWasTruncated
  case invalidSuccessMarker

  var errorDescription: String? {
    switch self {
    case .missingWritableBindMount:
      "The bind-mount benchmark requires a reviewed writable host folder at /workspace."
    case .commandFailed(let exitCode):
      "The fixed container I/O workload exited with status \(exitCode)."
    case .outputWasTruncated:
      "The fixed container I/O workload exceeded its bounded output limit."
    case .invalidSuccessMarker:
      "The fixed container I/O workload did not return its completion marker."
    }
  }
}

actor ExternalNetworkPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  private static let successMarker = "nativecontainers-network-ok"
  private static let targetPath = "/tmp/nativecontainers-external-network.bin"
  private static let allowedSHA256Characters = Set("0123456789abcdef")
  private static let workload = """
    set -eu
    url=$1
    target=$2
    cleanup() { rm -f -- "$target"; }
    trap cleanup EXIT HUP INT TERM
    wget -q -T 180 --header 'Cache-Control: no-cache' -U 'NativeContainers-Performance/1' -O "$target" "$url"
    actual_bytes=$(wc -c < "$target" | tr -d '[:space:]')
    actual_sha256=$(sha256sum "$target")
    actual_sha256=${actual_sha256%% *}
    printf 'bytes=%s\nsha256=%s\n%s\n' "$actual_bytes" "$actual_sha256" nativecontainers-network-ok
    """

  nonisolated let kind = PerformanceBenchmarkKind.externalNetworkTransfer

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let commands: any ContainerCommandRunning
  private let endpoint: URL
  private let expectedByteCount: Int64
  private let expectedSHA256: String

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    commands: any ContainerCommandRunning,
    endpoint: URL,
    expectedByteCount: Int64,
    expectedSHA256: String,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-network-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) throws {
    guard Self.isExternalHTTPSEndpoint(endpoint) else {
      throw ExternalNetworkPerformanceBenchmarkError.invalidEndpoint
    }
    guard (1...128 * 1_048_576).contains(expectedByteCount) else {
      throw ExternalNetworkPerformanceBenchmarkError.invalidExpectedByteCount
    }
    guard
      expectedSHA256.count == 64,
      expectedSHA256.allSatisfy(Self.allowedSHA256Characters.contains)
    else {
      throw ExternalNetworkPerformanceBenchmarkError.invalidExpectedDigest
    }

    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      makeContainerID: makeContainerID
    )
    self.commands = commands
    self.endpoint = endpoint
    self.expectedByteCount = expectedByteCount
    self.expectedSHA256 = expectedSHA256
  }

  func prepareIteration() async throws {
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
  }

  func prepareMeasurement() async throws {
    try await lifecycle.validateCurrentContainer(expectedState: .running)
  }

  func perform() async throws -> Int64? {
    let id = try await lifecycle.currentContainerID()
    let result = try await commands.executeCommand(
      in: id,
      request: ContainerCommandRequest(
        executable: "/bin/sh",
        arguments: [
          "-c",
          Self.workload,
          "nativecontainers-network",
          endpoint.absoluteString,
          Self.targetPath,
        ],
        timeoutSeconds: 300
      )
    )
    guard !result.outputWasTruncated else {
      throw ExternalNetworkPerformanceBenchmarkError.outputWasTruncated
    }
    guard result.exitCode == 0 else {
      throw ExternalNetworkPerformanceBenchmarkError.commandFailed(
        result.exitCode
      )
    }
    let observation = try Self.parse(result.standardOutput)
    guard observation.byteCount == expectedByteCount else {
      throw ExternalNetworkPerformanceBenchmarkError.byteCountMismatch(
        expected: expectedByteCount,
        actual: observation.byteCount
      )
    }
    guard observation.sha256 == expectedSHA256 else {
      throw ExternalNetworkPerformanceBenchmarkError.digestMismatch
    }
    try await lifecycle.validateCurrentContainer(expectedState: .running)
    return expectedByteCount
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }

  private static func parse(
    _ output: String
  ) throws -> (byteCount: Int64, sha256: String) {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard
      lines.count == 3,
      lines[0].hasPrefix("bytes="),
      let byteCount = Int64(lines[0].dropFirst("bytes=".count)),
      lines[1].hasPrefix("sha256="),
      lines[2] == successMarker
    else {
      throw ExternalNetworkPerformanceBenchmarkError.invalidOutput
    }
    let sha256 = String(lines[1].dropFirst("sha256=".count))
    guard
      sha256.count == 64,
      sha256.allSatisfy(allowedSHA256Characters.contains)
    else {
      throw ExternalNetworkPerformanceBenchmarkError.invalidOutput
    }
    return (byteCount, sha256)
  }

  private static func isExternalHTTPSEndpoint(_ endpoint: URL) -> Bool {
    guard
      endpoint.scheme?.lowercased() == "https",
      let host = endpoint.host?.lowercased(),
      !host.isEmpty,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.fragment == nil,
      endpoint.absoluteString.utf8.count <= 2_048
    else {
      return false
    }
    let isIPv6Literal = host.contains(":")
    if host == "localhost" || host == "::1" || host == "[::1]"
      || host == "0.0.0.0" || host.hasSuffix(".local")
      || host.hasPrefix("127.") || host.hasPrefix("10.")
      || host.hasPrefix("192.168.") || host.hasPrefix("169.254.")
      || (isIPv6Literal
        && (host.hasPrefix("fc") || host.hasPrefix("fd")
          || host.hasPrefix("fe80:")))
    {
      return false
    }
    if host.hasPrefix("172."),
      let secondOctet = host.split(separator: ".").dropFirst().first.flatMap(Int.init),
      (16...31).contains(secondOctet)
    {
      return false
    }
    return true
  }
}

enum ExternalNetworkPerformanceBenchmarkError:
  LocalizedError,
  Equatable,
  Sendable
{
  case invalidEndpoint
  case invalidExpectedByteCount
  case invalidExpectedDigest
  case commandFailed(Int32)
  case outputWasTruncated
  case invalidOutput
  case byteCountMismatch(expected: Int64, actual: Int64)
  case digestMismatch

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The external-network benchmark requires a bounded non-local HTTPS URL without embedded credentials."
    case .invalidExpectedByteCount:
      "The external-network benchmark payload must be between 1 and 128 MiB."
    case .invalidExpectedDigest:
      "The external-network benchmark requires a lowercase SHA-256 payload digest."
    case .commandFailed(let exitCode):
      "The external HTTPS workload exited with status \(exitCode)."
    case .outputWasTruncated:
      "The external HTTPS workload exceeded its bounded output limit."
    case .invalidOutput:
      "The external HTTPS workload returned an invalid verification record."
    case .byteCountMismatch(let expected, let actual):
      "The external HTTPS payload contained \(actual) bytes instead of \(expected)."
    case .digestMismatch:
      "The external HTTPS payload did not match the reviewed SHA-256 digest."
    }
  }
}

actor ImageBuildPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  nonisolated let kind = PerformanceBenchmarkKind.imageBuild

  private let builder: any ImageBuilding
  private let request: ImageBuildRequest
  private let authorization: ImageBuildAuthorization
  private let outputDestination: URL
  private let fileManager = FileManager.default
  private var preparedPlan: ImageBuildPlan?
  private var buildIDs: [UUID] = []
  private var stagedContextDirectories: [URL] = []
  private var outputTags: [String] = []

  init(
    builder: any ImageBuilding,
    request: ImageBuildRequest,
    authorization: ImageBuildAuthorization = ImageBuildAuthorization(
      allowsTagReplacement: false,
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: false
    )
  ) throws {
    guard
      request.cachePolicy == .disabled,
      !request.pullLatest,
      request.output.kind == .ociArchive,
      let outputDestination = request.output.destinationURL,
      request.platforms == [.current],
      request.tags.count == 1,
      request.secrets.isEmpty,
      request.buildArguments.isEmpty,
      request.targetStage.isEmpty,
      !authorization.allowsTagReplacement,
      !authorization.allowsOutputReplacement
    else {
      throw ImageBuildPerformanceBenchmarkError.invalidConfiguration
    }

    self.builder = builder
    self.request = request
    self.authorization = authorization
    self.outputDestination = outputDestination.standardizedFileURL
      .resolvingSymlinksInPath()
  }

  func prepareIteration() async throws {
    guard preparedPlan == nil else {
      throw ImageBuildPerformanceBenchmarkError.invalidIterationState
    }
    guard !outputExists else {
      throw ImageBuildPerformanceBenchmarkError.outputAlreadyExists
    }

    let plan = try await builder.prepareBuild(request) { _ in }
    preparedPlan = plan
    buildIDs.append(plan.id)
    stagedContextDirectories.append(plan.stagedContextDirectory)
    outputTags.append(contentsOf: plan.tags.map(\.reference))
    try validate(plan)
  }

  func prepareMeasurement() async throws {
    guard let preparedPlan else {
      throw ImageBuildPerformanceBenchmarkError.invalidIterationState
    }
    try validate(preparedPlan)
    guard !outputExists else {
      throw ImageBuildPerformanceBenchmarkError.outputAlreadyExists
    }
  }

  func perform() async throws -> Int64? {
    guard let preparedPlan else {
      throw ImageBuildPerformanceBenchmarkError.invalidIterationState
    }
    let result = try await builder.build(
      preparedPlan,
      authorization: authorization
    ) { _ in }
    guard
      result.buildID == preparedPlan.id,
      result.platforms == preparedPlan.platforms,
      case .ociArchive(let destination, let sha256, let byteCount) = result.output,
      destination.standardizedFileURL == outputDestination,
      byteCount > 0,
      Self.isSHA256(sha256)
    else {
      throw ImageBuildPerformanceBenchmarkError.resultChanged
    }

    let values = try outputDestination.resourceValues(
      forKeys: [.isRegularFileKey, .fileSizeKey]
    )
    guard
      values.isRegularFile == true,
      values.fileSize.map { Int64($0) } == byteCount
    else {
      throw ImageBuildPerformanceBenchmarkError.invalidOutputArchive
    }
    return nil
  }

  func cleanUpIteration() async throws {
    guard let preparedPlan else { return }
    self.preparedPlan = nil
    await builder.discardBuild(preparedPlan)

    if outputExists {
      do {
        try fileManager.removeItem(at: outputDestination)
      } catch {
        throw ImageBuildPerformanceBenchmarkError.outputRemovalFailed(
          error.localizedDescription
        )
      }
      guard !outputExists else {
        throw ImageBuildPerformanceBenchmarkError.outputRemovalNotConfirmed
      }
    }
    guard
      !fileManager.fileExists(
        atPath: preparedPlan.stagedContextDirectory.path(percentEncoded: false)
      )
    else {
      throw ImageBuildPerformanceBenchmarkError.stagedContextRemovalNotConfirmed(
        preparedPlan.stagedContextDirectory.path(percentEncoded: false)
      )
    }
  }

  func reviewedBuildIDs() -> [UUID] {
    buildIDs
  }

  func reviewedStagedContextDirectories() -> [URL] {
    stagedContextDirectories
  }

  func reviewedOutputTags() -> [String] {
    outputTags
  }

  private var outputExists: Bool {
    fileManager.fileExists(atPath: outputDestination.path(percentEncoded: false))
  }

  private func validate(_ plan: ImageBuildPlan) throws {
    guard
      plan.sourceContextDirectory == request.contextDirectory.standardizedFileURL,
      plan.tags.count == 1,
      plan.tags.first?.reference.isEmpty == false,
      !plan.replacesExistingTags,
      plan.platforms == request.platforms,
      plan.buildArguments == request.buildArguments,
      plan.labels == request.labels,
      plan.targetStage == request.targetStage,
      plan.cachePolicy == .disabled,
      !plan.pullLatest,
      plan.secrets.isEmpty,
      plan.output.kind == .ociArchive,
      plan.output.destinationURL?.standardizedFileURL == outputDestination,
      !plan.output.replacesExistingDestination
    else {
      throw ImageBuildPerformanceBenchmarkError.planChanged
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      }
  }
}

enum ImageBuildPerformanceBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case invalidIterationState
  case outputAlreadyExists
  case planChanged
  case resultChanged
  case invalidOutputArchive
  case outputRemovalFailed(String)
  case outputRemovalNotConfirmed
  case stagedContextRemovalNotConfirmed(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The image-build benchmark requires one current-platform, no-cache OCI export with no secrets or registry refresh."
    case .invalidIterationState:
      "The image-build benchmark iteration is not in a valid state."
    case .outputAlreadyExists:
      "The reviewed image-build benchmark output already exists."
    case .planChanged:
      "The prepared image-build benchmark plan changed after review."
    case .resultChanged:
      "The image-build benchmark result did not match its reviewed plan."
    case .invalidOutputArchive:
      "The image-build benchmark did not produce the reviewed OCI archive."
    case .outputRemovalFailed(let message):
      "The image-build benchmark output could not be removed: \(message)"
    case .outputRemovalNotConfirmed:
      "The image-build benchmark output remained after cleanup."
    case .stagedContextRemovalNotConfirmed(let path):
      "The image-build benchmark staged context remained after cleanup: \(path)"
    }
  }
}

struct PrivateDiskPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.privateDiskIO

  private static let chunk = Data(repeating: 0xA5, count: 1_048_576)

  private let workspaceDirectoryURL: URL
  private let payloadByteCount: Int

  init(
    workspaceDirectoryURL: URL,
    payloadByteCount: Int = 16 * 1_048_576
  ) {
    self.workspaceDirectoryURL = workspaceDirectoryURL
    self.payloadByteCount = max(1, payloadByteCount)
  }

  func perform() async throws -> Int64? {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: workspaceDirectoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw PerformanceBenchmarkError.privateDiskWorkspaceUnavailable
    }

    let fileURL = workspaceDirectoryURL.appending(
      path: "disk-\(UUID().uuidString.lowercased()).benchmark"
    )
    guard
      fileManager.createFile(
        atPath: fileURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw PerformanceBenchmarkError.privateDiskWriteFailed
    }
    defer { try? fileManager.removeItem(at: fileURL) }

    do {
      let writer = try FileHandle(forWritingTo: fileURL)
      defer { try? writer.close() }

      var remaining = payloadByteCount
      while remaining > 0 {
        try Task.checkCancellation()
        let count = min(remaining, Self.chunk.count)
        try writer.write(contentsOf: Self.chunk.prefix(count))
        remaining -= count
      }
      try writer.synchronize()
      try writer.close()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PerformanceBenchmarkError.privateDiskWriteFailed
    }

    do {
      let reader = try FileHandle(forReadingFrom: fileURL)
      defer { try? reader.close() }

      var readByteCount = 0
      while let data = try reader.read(upToCount: Self.chunk.count), !data.isEmpty {
        try Task.checkCancellation()
        readByteCount += data.count
      }
      guard readByteCount == payloadByteCount else {
        throw PerformanceBenchmarkError.privateDiskReadFailed
      }
      try reader.close()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as PerformanceBenchmarkError {
      throw error
    } catch {
      throw PerformanceBenchmarkError.privateDiskReadFailed
    }

    return Int64(payloadByteCount) * 2
  }
}

struct LoopbackNetworkPerformanceBenchmarkScenario: PerformanceBenchmarkScenario {
  let kind = PerformanceBenchmarkKind.loopbackNetwork

  private static let defaultPayloadByteCount = 16 * 1_048_576
  private static let defaultPayload = Data(
    repeating: 0x5A,
    count: defaultPayloadByteCount
  )

  private let payloadByteCount: Int
  private let timeout: Duration

  init(
    payloadByteCount: Int = defaultPayloadByteCount,
    timeout: Duration = .seconds(10)
  ) {
    self.payloadByteCount = max(1, payloadByteCount)
    self.timeout = timeout
  }

  func perform() async throws -> Int64? {
    let payload =
      payloadByteCount == Self.defaultPayloadByteCount
      ? Self.defaultPayload
      : Data(repeating: 0x5A, count: payloadByteCount)
    let transfer = NetworkFrameworkLoopbackTransfer(payload: payload)

    return try await withThrowingTaskGroup(of: Int64.self) { group in
      group.addTask {
        try await transfer.run()
        return Int64(payload.count)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw PerformanceBenchmarkError.loopbackTimedOut
      }

      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw PerformanceBenchmarkError.loopbackConnectionFailed
      }
      return result
    }
  }
}

private final class NetworkFrameworkLoopbackTransfer: @unchecked Sendable {
  private let payload: Data
  private let queue = DispatchQueue(
    label: "com.nativecontainers.performance.loopback",
    qos: .userInitiated
  )

  private var listener: NWListener?
  private var client: NWConnection?
  private var server: NWConnection?
  private var continuation: CheckedContinuation<Void, any Error>?
  private var receivedByteCount = 0
  private var didStartClientSend = false
  private var didStartServerReceive = false
  private var isFinished = false

  init(payload: Data) {
    self.payload = payload
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          self.start(continuation: continuation)
        }
      }
    } onCancel: {
      queue.async {
        self.finish(.failure(CancellationError()))
      }
    }
  }

  private func start(continuation: CheckedContinuation<Void, any Error>) {
    guard !isFinished else {
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation

    do {
      let listener = try NWListener(using: .tcp, on: .any)
      self.listener = listener
      listener.newConnectionLimit = 1
      listener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerState(state)
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: queue)
    } catch {
      finish(.failure(PerformanceBenchmarkError.loopbackListenerUnavailable))
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let port = listener?.port, client == nil else { return }
      let client = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: port,
        using: .tcp
      )
      self.client = client
      client.stateUpdateHandler = { [weak self] state in
        self?.handleClientState(state)
      }
      client.start(queue: queue)
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackListenerUnavailable))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    guard server == nil, !isFinished else {
      connection.cancel()
      return
    }
    server = connection
    connection.stateUpdateHandler = { [weak self] state in
      self?.handleServerState(state)
    }
    connection.start(queue: queue)
  }

  private func handleClientState(_ state: NWConnection.State) {
    switch state {
    case .ready:
      guard !didStartClientSend else { return }
      didStartClientSend = true
      client?.send(
        content: payload,
        contentContext: .defaultStream,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          guard error != nil else { return }
          self?.finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
        }
      )
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func handleServerState(_ state: NWConnection.State) {
    switch state {
    case .ready:
      guard !didStartServerReceive else { return }
      didStartServerReceive = true
      receiveNextChunk()
    case .failed:
      finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
    case .cancelled:
      if !isFinished {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      }
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func receiveNextChunk() {
    server?.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1_024
    ) { [weak self] data, _, isComplete, error in
      guard let self, !isFinished else { return }

      if let data {
        receivedByteCount += data.count
      }
      if error != nil {
        finish(.failure(PerformanceBenchmarkError.loopbackConnectionFailed))
      } else if receivedByteCount == payload.count {
        finish(.success(()))
      } else if receivedByteCount > payload.count || isComplete {
        finish(
          .failure(
            PerformanceBenchmarkError.loopbackTransferIncomplete(
              expected: payload.count,
              actual: receivedByteCount
            )
          )
        )
      } else {
        receiveNextChunk()
      }
    }
  }

  private func finish(_ result: Result<Void, any Error>) {
    guard !isFinished else { return }
    isFinished = true

    listener?.cancel()
    client?.cancel()
    server?.cancel()
    listener = nil
    client = nil
    server = nil

    let continuation = continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }
}
