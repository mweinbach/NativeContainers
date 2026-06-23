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
  private let cpuCount: Int
  private let memoryBytes: UInt64
  private let arguments: [String]
  private let environment: [ContainerEnvironmentVariable]
  private let workingDirectory: String?
  private let publishedPorts: [ContainerPortPublication]
  private let makeContainerID: @Sendable () -> String
  private var preparedContainer: PreparedContainer?

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    attachments: ContainerAttachmentSelection = .empty,
    cpuCount: Int = 1,
    memoryBytes: UInt64 = 256 * ContainerCreationRequest.bytesPerMiB,
    arguments: [String] = ["/bin/sleep", "3600"],
    environment: [ContainerEnvironmentVariable] = [],
    workingDirectory: String? = nil,
    publishedPorts: [ContainerPortPublication] = [],
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-perf-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) {
    self.containers = containers
    self.stateReader = stateReader
    self.imageReference = imageReference
    self.expectedImageDigest = expectedImageDigest
    self.attachments = attachments
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.publishedPorts = publishedPorts
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
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      publishedPorts: publishedPorts,
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

  func currentOperationID() throws -> UUID {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }
    return preparedContainer.operationID
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

  func stopCurrentContainer() async throws {
    guard let preparedContainer, preparedContainer.didCreate else {
      throw ColdContainerStartupBenchmarkError.invalidIterationState
    }
    try await stopIfNeeded(preparedContainer)
    try await validateCurrentContainer(expectedState: .stopped)
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

actor WarmContainerStartupPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.warmContainerStartup

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-warm-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) {
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      makeContainerID: makeContainerID
    )
  }

  func prepareIteration() async throws {
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
    try await lifecycle.stopCurrentContainer()
  }

  func prepareMeasurement() async throws {
    try await lifecycle.validateCurrentContainer(expectedState: .stopped)
  }

  func perform() async throws -> Int64? {
    try await lifecycle.perform()
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
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

struct BindMountMetadataObservation: Equatable, Sendable {
  let batches: Int
  let operationsPerBatch: Int
  let totalOperations: Int
}

actor BindMountMetadataPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  private static let successMarker = "nativecontainers-metadata-ok"
  private static let operationsPerBatch = 7
  private static let workload = """
    set -eu
    root=/workspace/nativecontainers-metadata
    count=$1
    cleanup() { rm -rf -- "$root"; }
    trap cleanup EXIT HUP INT TERM
    mkdir "$root"
    i=0
    while [ "$i" -lt "$count" ]; do
      source="$root/source-$i"
      target="$root/target-$i"
      directory="$root/directory-$i"
      : > "$source"
      stat "$source" >/dev/null
      chmod 600 "$source"
      mv "$source" "$target"
      rm "$target"
      mkdir "$directory"
      rmdir "$directory"
      i=$((i + 1))
    done
    printf 'operations=%s\\n%s\\n' "$((count * 7))" nativecontainers-metadata-ok
    """

  nonisolated let kind = PerformanceBenchmarkKind.bindMountMetadata

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let commands: any ContainerCommandRunning
  private let batches: Int
  private var recordedObservations: [BindMountMetadataObservation] = []

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    commands: any ContainerCommandRunning,
    attachments: ContainerAttachmentSelection,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    batches: Int = 256,
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-metadata-\(UUID().uuidString.lowercased().prefix(8))"
    }
  ) throws {
    guard
      attachments.hostDirectoryMounts.contains(where: {
        $0.containerPath == "/workspace" && !$0.isReadOnly
      })
    else {
      throw ContainerIOPerformanceBenchmarkError.missingWritableBindMount
    }
    guard (1...10_000).contains(batches) else {
      throw BindMountMetadataBenchmarkError.invalidBatchCount
    }
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      attachments: attachments,
      makeContainerID: makeContainerID
    )
    self.commands = commands
    self.batches = batches
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
        arguments: ["-c", Self.workload, "nativecontainers-metadata", String(batches)],
        timeoutSeconds: 180
      )
    )
    guard !result.outputWasTruncated else {
      throw BindMountMetadataBenchmarkError.outputWasTruncated
    }
    guard result.exitCode == 0 else {
      throw BindMountMetadataBenchmarkError.commandFailed(result.exitCode)
    }
    let totalOperations = try Self.parseOperations(result.standardOutput)
    let expectedOperations = batches * Self.operationsPerBatch
    guard totalOperations == expectedOperations else {
      throw BindMountMetadataBenchmarkError.operationCountMismatch(
        expected: expectedOperations,
        actual: totalOperations
      )
    }
    try await lifecycle.validateCurrentContainer(expectedState: .running)
    recordedObservations.append(
      BindMountMetadataObservation(
        batches: batches,
        operationsPerBatch: Self.operationsPerBatch,
        totalOperations: totalOperations
      )
    )
    return nil
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }

  func observations() -> [BindMountMetadataObservation] {
    recordedObservations
  }

  private static func parseOperations(_ output: String) throws -> Int {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard
      lines.count == 2,
      lines[0].hasPrefix("operations="),
      let operations = Int(lines[0].dropFirst("operations=".count)),
      operations > 0,
      lines[1] == successMarker
    else {
      throw BindMountMetadataBenchmarkError.invalidOutput
    }
    return operations
  }
}

enum BindMountMetadataBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidBatchCount
  case commandFailed(Int32)
  case outputWasTruncated
  case invalidOutput
  case operationCountMismatch(expected: Int, actual: Int)

  var errorDescription: String? {
    switch self {
    case .invalidBatchCount:
      "The bind-mount metadata benchmark requires between 1 and 10,000 batches."
    case .commandFailed(let exitCode):
      "The fixed bind-mount metadata workload exited with status \(exitCode)."
    case .outputWasTruncated:
      "The fixed bind-mount metadata workload exceeded its bounded output limit."
    case .invalidOutput:
      "The fixed bind-mount metadata workload returned an invalid verification record."
    case .operationCountMismatch(let expected, let actual):
      "The bind-mount metadata workload completed \(actual) operations instead of \(expected)."
    }
  }
}

struct PostgreSQLDurabilityObservation: Equatable, Sendable {
  let fsyncEnabled: Bool
  let synchronousCommitEnabled: Bool
  let pgTestFsyncCompleted: Bool
  let committedRowCount: Int
  let committedPayloadBytes: Int64
}

actor PostgreSQLDurabilityPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.postgreSQLDurability

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let commands: any ContainerCommandRunning
  private let rowCount: Int
  private let readinessAttempts: Int
  private let readinessDelay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recordedObservations: [PostgreSQLDurabilityObservation] = []

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    commands: any ContainerCommandRunning,
    imageReference: String = "docker.io/library/postgres:17-alpine",
    expectedImageDigest: String,
    rowCount: Int = 1_024,
    readinessAttempts: Int = 60,
    readinessDelay: Duration = .milliseconds(500),
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-postgres-\(UUID().uuidString.lowercased().prefix(8))"
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard
      (1...100_000).contains(rowCount),
      (1...300).contains(readinessAttempts),
      readinessDelay >= .milliseconds(10),
      readinessDelay <= .seconds(10)
    else {
      throw PostgreSQLDurabilityBenchmarkError.invalidConfiguration
    }
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      memoryBytes: 512 * ContainerCreationRequest.bytesPerMiB,
      arguments: [],
      environment: [
        try ContainerEnvironmentVariable(
          key: "POSTGRES_HOST_AUTH_METHOD",
          value: "trust"
        ),
        try ContainerEnvironmentVariable(
          key: "POSTGRES_INITDB_ARGS",
          value: "--data-checksums"
        ),
      ],
      makeContainerID: makeContainerID
    )
    self.commands = commands
    self.rowCount = rowCount
    self.readinessAttempts = readinessAttempts
    self.readinessDelay = readinessDelay
    self.sleep = sleep
  }

  func prepareIteration() async throws {
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
    try await awaitReadiness()
  }

  func prepareMeasurement() async throws {
    try await lifecycle.validateCurrentContainer(expectedState: .running)
  }

  func perform() async throws -> Int64? {
    let id = try await lifecycle.currentContainerID()
    let fsyncResult = try await commands.executeCommand(
      in: id,
      request: ContainerCommandRequest(
        executable: "/usr/local/bin/pg_test_fsync",
        arguments: ["-f", "/tmp/nativecontainers-pg-test-fsync"],
        timeoutSeconds: 180
      )
    )
    guard !fsyncResult.outputWasTruncated else {
      throw PostgreSQLDurabilityBenchmarkError.outputWasTruncated
    }
    guard fsyncResult.exitCode == 0 else {
      throw PostgreSQLDurabilityBenchmarkError.pgTestFsyncFailed(
        fsyncResult.exitCode
      )
    }

    let sql = """
      BEGIN;
      DROP TABLE IF EXISTS nativecontainers_durability;
      CREATE TABLE nativecontainers_durability (id integer PRIMARY KEY, payload text NOT NULL);
      INSERT INTO nativecontainers_durability
        SELECT value, repeat('x', 1024) FROM generate_series(1, \(rowCount)) AS value;
      COMMIT;
      CHECKPOINT;
      SELECT current_setting('fsync') || '|' || current_setting('synchronous_commit') || '|' || count(*)
        FROM nativecontainers_durability;
      """
    let transactionResult = try await commands.executeCommand(
      in: id,
      request: ContainerCommandRequest(
        executable: "/usr/local/bin/psql",
        arguments: [
          "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c",
          sql,
        ],
        timeoutSeconds: 180
      )
    )
    guard !transactionResult.outputWasTruncated else {
      throw PostgreSQLDurabilityBenchmarkError.outputWasTruncated
    }
    guard transactionResult.exitCode == 0 else {
      throw PostgreSQLDurabilityBenchmarkError.transactionFailed(
        transactionResult.exitCode
      )
    }
    let observedRows = try Self.parseVerification(transactionResult.standardOutput)
    guard observedRows == rowCount else {
      throw PostgreSQLDurabilityBenchmarkError.rowCountMismatch(
        expected: rowCount,
        actual: observedRows
      )
    }
    let payloadBytes = Int64(rowCount) * 1_024
    recordedObservations.append(
      PostgreSQLDurabilityObservation(
        fsyncEnabled: true,
        synchronousCommitEnabled: true,
        pgTestFsyncCompleted: true,
        committedRowCount: rowCount,
        committedPayloadBytes: payloadBytes
      )
    )
    try await lifecycle.validateCurrentContainer(expectedState: .running)
    return payloadBytes
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }

  func observations() -> [PostgreSQLDurabilityObservation] {
    recordedObservations
  }

  private func awaitReadiness() async throws {
    let id = try await lifecycle.currentContainerID()
    for attempt in 0..<readinessAttempts {
      let result = try await commands.executeCommand(
        in: id,
        request: ContainerCommandRequest(
          executable: "/usr/local/bin/pg_isready",
          arguments: ["-U", "postgres", "-d", "postgres"],
          timeoutSeconds: 10
        )
      )
      if result.exitCode == 0, !result.outputWasTruncated {
        return
      }
      if attempt + 1 < readinessAttempts {
        try await sleep(readinessDelay)
      }
    }
    throw PostgreSQLDurabilityBenchmarkError.readinessTimedOut
  }

  private static func parseVerification(_ output: String) throws -> Int {
    let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = line.split(separator: "|", omittingEmptySubsequences: false)
    guard
      fields.count == 3,
      fields[0] == "on",
      fields[1] == "on",
      let rows = Int(fields[2]),
      rows > 0
    else {
      throw PostgreSQLDurabilityBenchmarkError.invalidVerificationOutput
    }
    return rows
  }
}

enum PostgreSQLDurabilityBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case readinessTimedOut
  case pgTestFsyncFailed(Int32)
  case transactionFailed(Int32)
  case outputWasTruncated
  case invalidVerificationOutput
  case rowCountMismatch(expected: Int, actual: Int)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The PostgreSQL durability benchmark configuration is outside its bounded limits."
    case .readinessTimedOut:
      "The PostgreSQL durability benchmark did not reach database readiness."
    case .pgTestFsyncFailed(let exitCode):
      "PostgreSQL pg_test_fsync exited with status \(exitCode)."
    case .transactionFailed(let exitCode):
      "The fixed PostgreSQL transaction exited with status \(exitCode)."
    case .outputWasTruncated:
      "The PostgreSQL durability workload exceeded its bounded output limit."
    case .invalidVerificationOutput:
      "PostgreSQL did not verify fsync, synchronous commit, and the committed row count."
    case .rowCountMismatch(let expected, let actual):
      "PostgreSQL committed \(actual) rows instead of \(expected)."
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
      let secondOctetText = host.split(separator: ".").dropFirst().first,
      let secondOctet = Int(secondOctetText),
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

protocol PerformanceBenchmarkHTTPTransferring: Sendable {
  func fetch(_ url: URL) async throws -> Data
}

struct URLSessionPerformanceBenchmarkHTTPTransport:
  PerformanceBenchmarkHTTPTransferring
{
  private let session: URLSession

  init(timeout: TimeInterval = 30) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    session = URLSession(configuration: configuration)
  }

  func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30
    )
    request.httpMethod = "GET"
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("NativeContainers-Performance/1", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard
      let response = response as? HTTPURLResponse,
      response.statusCode == 200
    else {
      throw NATDirectNetworkBenchmarkError.invalidHTTPResponse
    }
    return data
  }
}

struct NetworkRoutePerformanceObservation: Equatable, Sendable {
  let samplesNanoseconds: [UInt64]
  let transferredByteCount: Int64

  var medianLatencyNanoseconds: UInt64 {
    percentile(0.5)
  }

  var p95LatencyNanoseconds: UInt64 {
    percentile(0.95)
  }

  var throughputMebibytesPerSecond: Double? {
    var total: UInt64 = 0
    for sample in samplesNanoseconds {
      let addition = total.addingReportingOverflow(sample)
      guard !addition.overflow else { return nil }
      total = addition.partialValue
    }
    guard transferredByteCount > 0, total > 0 else { return nil }
    return Double(transferredByteCount) / 1_048_576
      / (Double(total) / 1_000_000_000)
  }

  private func percentile(_ value: Double) -> UInt64 {
    guard !samplesNanoseconds.isEmpty else { return 0 }
    let sorted = samplesNanoseconds.sorted()
    let rank = Int(ceil(value * Double(sorted.count)))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}

struct NATDirectNetworkObservation: Equatable, Sendable {
  let publishedHost: String
  let publishedPort: UInt16
  let directHost: String
  let containerPort: UInt16
  let payloadByteCount: Int
  let requestCountPerRoute: Int
  let publishedRoute: NetworkRoutePerformanceObservation
  let directRoute: NetworkRoutePerformanceObservation
}

actor NATDirectNetworkPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  private static let successMarker = "nativecontainers-http-server-ok"
  private static let containerPort: UInt16 = 8_080
  private static let setupWorkload = """
    set -eu
    root=/tmp/nativecontainers-network-root
    payload="$root/payload.bin"
    bytes=$1
    rm -rf -- "$root"
    mkdir -p "$root"
    head -c "$bytes" /dev/zero > "$payload"
    busybox httpd -p 8080 -h "$root"
    actual=$(wc -c < "$payload" | tr -d '[:space:]')
    printf 'bytes=%s\\n%s\\n' "$actual" nativecontainers-http-server-ok
    """

  nonisolated let kind = PerformanceBenchmarkKind.natDirectNetworkComparison

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let inventory: any ContainerInventoryLoading
  private let commands: any ContainerCommandRunning
  private let transport: any PerformanceBenchmarkHTTPTransferring
  private let clock: any PerformanceBenchmarkClock
  private let expectedImageReference: String
  private let expectedImageDigest: String
  private let hostPort: UInt16
  private let payload: Data
  private let requestCount: Int
  private let readinessAttempts: Int
  private let readinessDelay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var publishedURL: URL?
  private var directURL: URL?
  private var recordedObservations: [NATDirectNetworkObservation] = []

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    inventory: any ContainerInventoryLoading,
    commands: any ContainerCommandRunning,
    hostPort: UInt16,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    payloadByteCount: Int = 1_048_576,
    requestCount: Int = 8,
    readinessAttempts: Int = 60,
    readinessDelay: Duration = .milliseconds(100),
    transport: any PerformanceBenchmarkHTTPTransferring =
      URLSessionPerformanceBenchmarkHTTPTransport(),
    clock: any PerformanceBenchmarkClock = ContinuousPerformanceBenchmarkClock(),
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-network-compare-\(UUID().uuidString.lowercased().prefix(8))"
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard
      hostPort > 1,
      (1...4 * 1_048_576).contains(payloadByteCount),
      (1...100).contains(requestCount),
      (1...300).contains(readinessAttempts),
      readinessDelay >= .milliseconds(10),
      readinessDelay <= .seconds(5)
    else {
      throw NATDirectNetworkBenchmarkError.invalidConfiguration
    }
    let publication = try ContainerPortPublication(
      hostAddress: "127.0.0.1",
      hostPort: hostPort,
      containerPort: Self.containerPort,
      transportProtocol: .tcp
    )
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      publishedPorts: [publication],
      makeContainerID: makeContainerID
    )
    self.inventory = inventory
    self.commands = commands
    self.transport = transport
    self.clock = clock
    expectedImageReference = imageReference
    self.expectedImageDigest = expectedImageDigest
    self.hostPort = hostPort
    payload = Data(repeating: 0, count: payloadByteCount)
    self.requestCount = requestCount
    self.readinessAttempts = readinessAttempts
    self.readinessDelay = readinessDelay
    self.sleep = sleep
  }

  func prepareIteration() async throws {
    guard publishedURL == nil, directURL == nil else {
      throw NATDirectNetworkBenchmarkError.invalidIterationState
    }
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
    let id = try await lifecycle.currentContainerID()
    let setup = try await commands.executeCommand(
      in: id,
      request: ContainerCommandRequest(
        executable: "/bin/sh",
        arguments: [
          "-c", Self.setupWorkload, "nativecontainers-http-server",
          String(payload.count),
        ],
        timeoutSeconds: 120
      )
    )
    guard !setup.outputWasTruncated else {
      throw NATDirectNetworkBenchmarkError.outputWasTruncated
    }
    guard setup.exitCode == 0 else {
      throw NATDirectNetworkBenchmarkError.serverSetupFailed(setup.exitCode)
    }
    guard try Self.parseSetupByteCount(setup.standardOutput) == payload.count else {
      throw NATDirectNetworkBenchmarkError.payloadChanged
    }
    try await resolveEndpoints()
    try await awaitReadiness()
  }

  func prepareMeasurement() async throws {
    try await lifecycle.validateCurrentContainer(expectedState: .running)
    try await resolveEndpoints()
  }

  func perform() async throws -> Int64? {
    guard let publishedURL, let directURL else {
      throw NATDirectNetworkBenchmarkError.invalidIterationState
    }
    var publishedSamples: [UInt64] = []
    var directSamples: [UInt64] = []
    publishedSamples.reserveCapacity(requestCount)
    directSamples.reserveCapacity(requestCount)

    for index in 0..<requestCount {
      if index.isMultiple(of: 2) {
        publishedSamples.append(try await measure(publishedURL))
        directSamples.append(try await measure(directURL))
      } else {
        directSamples.append(try await measure(directURL))
        publishedSamples.append(try await measure(publishedURL))
      }
    }

    let bytesPerRoute = try Self.checkedTransferredBytes(
      payloadBytes: payload.count,
      requestCount: requestCount
    )
    let directHost = try URL.requireHost(directURL)
    recordedObservations.append(
      NATDirectNetworkObservation(
        publishedHost: "127.0.0.1",
        publishedPort: hostPort,
        directHost: directHost,
        containerPort: Self.containerPort,
        payloadByteCount: payload.count,
        requestCountPerRoute: requestCount,
        publishedRoute: NetworkRoutePerformanceObservation(
          samplesNanoseconds: publishedSamples,
          transferredByteCount: bytesPerRoute
        ),
        directRoute: NetworkRoutePerformanceObservation(
          samplesNanoseconds: directSamples,
          transferredByteCount: bytesPerRoute
        )
      )
    )
    let total = bytesPerRoute.multipliedReportingOverflow(by: 2)
    guard !total.overflow else {
      throw NATDirectNetworkBenchmarkError.byteCountOverflow
    }
    return total.partialValue
  }

  func cleanUpIteration() async throws {
    publishedURL = nil
    directURL = nil
    try await lifecycle.cleanUpIteration()
  }

  func observations() -> [NATDirectNetworkObservation] {
    recordedObservations
  }

  private func resolveEndpoints() async throws {
    let id = try await lifecycle.currentContainerID()
    let operationID = try await lifecycle.currentOperationID()
    let snapshot = try await inventory.loadInventory()
    guard
      let container = snapshot.containers.first(where: { $0.id == id }),
      container.state == .running,
      container.imageReference == expectedImageReference,
      container.imageDigest == expectedImageDigest,
      container.labels[AppleContainerOwnership.creationOperationLabel]
        == operationID.uuidString,
      container.ports.contains(where: {
        $0.hostAddress == "127.0.0.1"
          && $0.hostPort == hostPort
          && $0.containerPort == Self.containerPort
          && $0.protocolName == "tcp"
      }),
      let rawAddress = container.ipAddress
    else {
      throw NATDirectNetworkBenchmarkError.containerIdentityChanged
    }
    let address = String(rawAddress.split(separator: "/", maxSplits: 1)[0])
    guard
      address != "127.0.0.1",
      address != "::1",
      IPv4Address(address) != nil || IPv6Address(address) != nil
    else {
      throw NATDirectNetworkBenchmarkError.invalidDirectAddress
    }
    publishedURL = try Self.makeURL(host: "127.0.0.1", port: hostPort)
    directURL = try Self.makeURL(host: address, port: Self.containerPort)
  }

  private func awaitReadiness() async throws {
    guard let publishedURL, let directURL else {
      throw NATDirectNetworkBenchmarkError.invalidIterationState
    }
    for attempt in 0..<readinessAttempts {
      do {
        let published = try await transport.fetch(publishedURL)
        let direct = try await transport.fetch(directURL)
        guard published == payload, direct == payload else {
          throw NATDirectNetworkBenchmarkError.payloadChanged
        }
        return
      } catch {
        if attempt + 1 == readinessAttempts {
          throw NATDirectNetworkBenchmarkError.readinessTimedOut(
            error.localizedDescription
          )
        }
        try await sleep(readinessDelay)
      }
    }
  }

  private func measure(_ url: URL) async throws -> UInt64 {
    let startedAt = clock.nowNanoseconds()
    let data = try await transport.fetch(url)
    let finishedAt = clock.nowNanoseconds()
    guard finishedAt >= startedAt else {
      throw PerformanceBenchmarkError.nonMonotonicClock
    }
    guard data == payload else {
      throw NATDirectNetworkBenchmarkError.payloadChanged
    }
    return finishedAt - startedAt
  }

  private static func parseSetupByteCount(_ output: String) throws -> Int {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard
      lines.count == 2,
      lines[0].hasPrefix("bytes="),
      let bytes = Int(lines[0].dropFirst("bytes=".count)),
      bytes > 0,
      lines[1] == successMarker
    else {
      throw NATDirectNetworkBenchmarkError.invalidSetupOutput
    }
    return bytes
  }

  private static func makeURL(host: String, port: UInt16) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(port)
    components.path = "/payload.bin"
    guard let url = components.url else {
      throw NATDirectNetworkBenchmarkError.invalidDirectAddress
    }
    return url
  }

  private static func checkedTransferredBytes(
    payloadBytes: Int,
    requestCount: Int
  ) throws -> Int64 {
    guard
      let payload = Int64(exactly: payloadBytes),
      let count = Int64(exactly: requestCount)
    else {
      throw NATDirectNetworkBenchmarkError.byteCountOverflow
    }
    let result = payload.multipliedReportingOverflow(by: count)
    guard !result.overflow else {
      throw NATDirectNetworkBenchmarkError.byteCountOverflow
    }
    return result.partialValue
  }
}

extension URL {
  fileprivate static func requireHost(_ url: URL) throws -> String {
    guard let host = url.host, !host.isEmpty else {
      throw NATDirectNetworkBenchmarkError.invalidDirectAddress
    }
    return host
  }
}

enum NATDirectNetworkBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case invalidIterationState
  case serverSetupFailed(Int32)
  case outputWasTruncated
  case invalidSetupOutput
  case payloadChanged
  case containerIdentityChanged
  case invalidDirectAddress
  case invalidHTTPResponse
  case readinessTimedOut(String)
  case byteCountOverflow

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The NAT/direct-IP benchmark configuration is outside its bounded limits."
    case .invalidIterationState:
      "The NAT/direct-IP benchmark iteration is not in a valid state."
    case .serverSetupFailed(let exitCode):
      "The fixed container HTTP server setup exited with status \(exitCode)."
    case .outputWasTruncated:
      "The fixed container HTTP server setup exceeded its bounded output limit."
    case .invalidSetupOutput:
      "The fixed container HTTP server returned an invalid verification record."
    case .payloadChanged:
      "The NAT/direct-IP benchmark payload changed between the compared routes."
    case .containerIdentityChanged:
      "The NAT/direct-IP benchmark container identity or published port changed."
    case .invalidDirectAddress:
      "The NAT/direct-IP benchmark did not receive a dedicated container IP address."
    case .invalidHTTPResponse:
      "The NAT/direct-IP benchmark received a non-successful HTTP response."
    case .readinessTimedOut(let message):
      "The NAT/direct-IP benchmark server did not become ready: \(message)"
    case .byteCountOverflow:
      "The NAT/direct-IP benchmark byte count overflowed."
    }
  }
}

struct IdleContainerResourceObservation: Equatable, Sendable {
  let initialMemoryUsageBytes: UInt64
  let finalMemoryUsageBytes: UInt64
  let memoryLimitBytes: UInt64
  let cpuUsageDeltaMicroseconds: UInt64
  let networkReceivedDeltaBytes: UInt64?
  let networkTransmittedDeltaBytes: UInt64?
  let blockReadDeltaBytes: UInt64?
  let blockWrittenDeltaBytes: UInt64?
  let processCount: UInt64
}

protocol IdleContainerStatisticsSampling: Sendable {
  func sampleContainer(id: String) async throws -> ContainerStatistics?
}

extension AppleContainerService: IdleContainerStatisticsSampling {}

actor IdleContainerResourcePerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.idleContainerResources

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let statistics: any IdleContainerStatisticsSampling
  private let settlingDuration: Duration
  private let samplingDuration: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recordedObservations: [IdleContainerResourceObservation] = []

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    statistics: any IdleContainerStatisticsSampling,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    settlingDuration: Duration = .seconds(2),
    samplingDuration: Duration = .seconds(10),
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-idle-\(UUID().uuidString.lowercased().prefix(8))"
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard
      settlingDuration >= .zero,
      settlingDuration <= .seconds(60),
      samplingDuration >= .seconds(1),
      samplingDuration <= .seconds(300)
    else {
      throw IdleContainerResourceBenchmarkError.invalidSamplingDuration
    }
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      makeContainerID: makeContainerID
    )
    self.statistics = statistics
    self.settlingDuration = settlingDuration
    self.samplingDuration = samplingDuration
    self.sleep = sleep
  }

  func prepareIteration() async throws {
    try await lifecycle.prepareIteration()
    try await lifecycle.prepareMeasurement()
    _ = try await lifecycle.perform()
  }

  func prepareMeasurement() async throws {
    try await sleep(settlingDuration)
    try await lifecycle.validateCurrentContainer(expectedState: .running)
  }

  func perform() async throws -> Int64? {
    let id = try await lifecycle.currentContainerID()
    let initial = try await requireStatistics(id: id)
    try await sleep(samplingDuration)
    let final = try await requireStatistics(id: id)
    try await lifecycle.validateCurrentContainer(expectedState: .running)

    guard
      let initialMemoryUsage = initial.memoryUsageBytes,
      let finalMemoryUsage = final.memoryUsageBytes,
      let initialMemoryLimit = initial.memoryLimitBytes,
      let finalMemoryLimit = final.memoryLimitBytes,
      let initialCPU = initial.cpuUsageMicroseconds,
      let finalCPU = final.cpuUsageMicroseconds,
      let processCount = final.processCount
    else {
      throw IdleContainerResourceBenchmarkError.requiredCountersUnavailable
    }
    guard
      initialMemoryLimit == finalMemoryLimit,
      finalMemoryLimit == 256 * ContainerCreationRequest.bytesPerMiB
    else {
      throw IdleContainerResourceBenchmarkError.memoryLimitChanged
    }
    guard finalCPU >= initialCPU else {
      throw IdleContainerResourceBenchmarkError.counterRegressed("CPU")
    }

    recordedObservations.append(
      IdleContainerResourceObservation(
        initialMemoryUsageBytes: initialMemoryUsage,
        finalMemoryUsageBytes: finalMemoryUsage,
        memoryLimitBytes: finalMemoryLimit,
        cpuUsageDeltaMicroseconds: finalCPU - initialCPU,
        networkReceivedDeltaBytes: try Self.delta(
          named: "network receive",
          initial: initial.networkReceivedBytes,
          final: final.networkReceivedBytes
        ),
        networkTransmittedDeltaBytes: try Self.delta(
          named: "network transmit",
          initial: initial.networkTransmittedBytes,
          final: final.networkTransmittedBytes
        ),
        blockReadDeltaBytes: try Self.delta(
          named: "block read",
          initial: initial.blockReadBytes,
          final: final.blockReadBytes
        ),
        blockWrittenDeltaBytes: try Self.delta(
          named: "block write",
          initial: initial.blockWrittenBytes,
          final: final.blockWrittenBytes
        ),
        processCount: processCount
      )
    )
    return nil
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }

  func observations() -> [IdleContainerResourceObservation] {
    recordedObservations
  }

  private func requireStatistics(id: String) async throws -> ContainerStatistics {
    guard let sample = try await statistics.sampleContainer(id: id) else {
      throw IdleContainerResourceBenchmarkError.statisticsUnavailable
    }
    return sample
  }

  private static func delta(
    named name: String,
    initial: UInt64?,
    final: UInt64?
  ) throws -> UInt64? {
    switch (initial, final) {
    case (nil, nil):
      return nil
    case (.some(let initial), .some(let final)):
      guard final >= initial else {
        throw IdleContainerResourceBenchmarkError.counterRegressed(name)
      }
      return final - initial
    case (.some, nil), (nil, .some):
      throw IdleContainerResourceBenchmarkError.requiredCountersUnavailable
    }
  }
}

enum IdleContainerResourceBenchmarkError:
  LocalizedError,
  Equatable,
  Sendable
{
  case invalidSamplingDuration
  case statisticsUnavailable
  case requiredCountersUnavailable
  case memoryLimitChanged
  case counterRegressed(String)

  var errorDescription: String? {
    switch self {
    case .invalidSamplingDuration:
      "The idle-resource benchmark requires a 1–300 second sampling window and at most 60 seconds of settling time."
    case .statisticsUnavailable:
      "The idle-resource benchmark could not sample the running container."
    case .requiredCountersUnavailable:
      "The idle-resource benchmark did not receive a complete counter pair."
    case .memoryLimitChanged:
      "The idle-resource benchmark container did not retain its reviewed memory limit."
    case .counterRegressed(let name):
      "The idle-resource benchmark \(name) counter moved backward."
    }
  }
}

enum IdleContainerDensity: Int, CaseIterable, Sendable {
  case ten = 10
  case fifty = 50

  var kind: PerformanceBenchmarkKind {
    switch self {
    case .ten: .idleContainerDensity10
    case .fifty: .idleContainerDensity50
    }
  }
}

struct IdleContainerDensityObservation: Equatable, Sendable {
  let containerCount: Int
  let initialTotalMemoryUsageBytes: UInt64
  let finalTotalMemoryUsageBytes: UInt64
  let initialMemoryUsageBytes: [UInt64]
  let finalMemoryUsageBytes: [UInt64]
}

actor IdleContainerDensityPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind: PerformanceBenchmarkKind

  private let density: IdleContainerDensity
  private let lifecycles: [ColdContainerStartupPerformanceBenchmarkScenario]
  private let statistics: any IdleContainerStatisticsSampling
  private let settlingDuration: Duration
  private let samplingDuration: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recordedObservations: [IdleContainerDensityObservation] = []

  init(
    density: IdleContainerDensity,
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    statistics: any IdleContainerStatisticsSampling,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    settlingDuration: Duration = .seconds(2),
    samplingDuration: Duration = .seconds(10),
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-density-\(UUID().uuidString.lowercased().prefix(8))"
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard
      settlingDuration >= .zero,
      settlingDuration <= .seconds(60),
      samplingDuration >= .seconds(1),
      samplingDuration <= .seconds(300)
    else {
      throw IdleContainerResourceBenchmarkError.invalidSamplingDuration
    }
    self.density = density
    kind = density.kind
    lifecycles = (0..<density.rawValue).map { _ in
      ColdContainerStartupPerformanceBenchmarkScenario(
        containers: containers,
        stateReader: stateReader,
        imageReference: imageReference,
        expectedImageDigest: expectedImageDigest,
        makeContainerID: makeContainerID
      )
    }
    self.statistics = statistics
    self.settlingDuration = settlingDuration
    self.samplingDuration = samplingDuration
    self.sleep = sleep
  }

  func prepareIteration() async throws {
    for lifecycle in lifecycles {
      try await lifecycle.prepareIteration()
      try await lifecycle.prepareMeasurement()
      _ = try await lifecycle.perform()
    }
  }

  func prepareMeasurement() async throws {
    try await sleep(settlingDuration)
    for lifecycle in lifecycles {
      try await lifecycle.validateCurrentContainer(expectedState: .running)
    }
  }

  func perform() async throws -> Int64? {
    let initial = try await memorySamples()
    try await sleep(samplingDuration)
    let final = try await memorySamples()
    guard initial.count == density.rawValue, final.count == density.rawValue else {
      throw IdleContainerDensityBenchmarkError.containerCountChanged
    }
    recordedObservations.append(
      IdleContainerDensityObservation(
        containerCount: density.rawValue,
        initialTotalMemoryUsageBytes: try Self.checkedSum(initial),
        finalTotalMemoryUsageBytes: try Self.checkedSum(final),
        initialMemoryUsageBytes: initial,
        finalMemoryUsageBytes: final
      )
    )
    return nil
  }

  func cleanUpIteration() async throws {
    var failures: [String] = []
    for lifecycle in lifecycles.reversed() {
      do {
        try await lifecycle.cleanUpIteration()
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    guard failures.isEmpty else {
      throw IdleContainerDensityBenchmarkError.cleanupFailed(failures)
    }
  }

  func observations() -> [IdleContainerDensityObservation] {
    recordedObservations
  }

  private func memorySamples() async throws -> [UInt64] {
    var values: [UInt64] = []
    values.reserveCapacity(density.rawValue)
    var ids: Set<String> = []
    for lifecycle in lifecycles {
      let id = try await lifecycle.currentContainerID()
      guard ids.insert(id).inserted else {
        throw IdleContainerDensityBenchmarkError.duplicateContainerIdentity(id)
      }
      try await lifecycle.validateCurrentContainer(expectedState: .running)
      guard
        let sample = try await statistics.sampleContainer(id: id),
        let memoryUsage = sample.memoryUsageBytes,
        let memoryLimit = sample.memoryLimitBytes
      else {
        throw IdleContainerResourceBenchmarkError.requiredCountersUnavailable
      }
      guard
        memoryLimit == 256 * ContainerCreationRequest.bytesPerMiB,
        memoryUsage <= memoryLimit
      else {
        throw IdleContainerResourceBenchmarkError.memoryLimitChanged
      }
      values.append(memoryUsage)
    }
    return values
  }

  private static func checkedSum(_ values: [UInt64]) throws -> UInt64 {
    try values.reduce(0) { partial, value in
      let result = partial.addingReportingOverflow(value)
      guard !result.overflow else {
        throw IdleContainerDensityBenchmarkError.memoryTotalOverflow
      }
      return result.partialValue
    }
  }
}

enum IdleContainerDensityBenchmarkError: LocalizedError, Equatable, Sendable {
  case duplicateContainerIdentity(String)
  case containerCountChanged
  case memoryTotalOverflow
  case cleanupFailed([String])

  var errorDescription: String? {
    switch self {
    case .duplicateContainerIdentity(let id):
      "The idle-density benchmark received duplicate container identity “\(id)”."
    case .containerCountChanged:
      "The idle-density benchmark did not retain its exact reviewed container count."
    case .memoryTotalOverflow:
      "The idle-density benchmark memory total overflowed."
    case .cleanupFailed(let failures):
      "Idle-density cleanup failed for \(failures.count) container(s): \(failures.joined(separator: "; "))"
    }
  }
}

struct PostStressMemoryObservation: Equatable, Sendable {
  let baselineMemoryUsageBytes: UInt64
  let stressedMemoryUsageBytes: UInt64
  let retainedMemoryUsageBytes: UInt64
  let memoryLimitBytes: UInt64
  let workloadMebibytes: Int
  let stopConfirmed: Bool
}

actor PostStressMemoryPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  private static let successMarker = "nativecontainers-memory-stress-ok"
  private static let workload = """
    set -eu
    target=/tmp/nativecontainers-memory-stress.bin
    size_mib=$1
    hold_seconds=$2
    cleanup() { rm -f -- "$target"; }
    trap cleanup EXIT HUP INT TERM
    dd if=/dev/zero of="$target" bs=1048576 count="$size_mib" 2>/dev/null
    dd if="$target" of=/dev/null bs=1048576 2>/dev/null
    sleep "$hold_seconds"
    dd if="$target" of=/dev/null bs=1048576 2>/dev/null
    printf '%s\\n' nativecontainers-memory-stress-ok
    """

  nonisolated let kind = PerformanceBenchmarkKind.postStressRetainedMemory

  private let lifecycle: ColdContainerStartupPerformanceBenchmarkScenario
  private let commands: any ContainerCommandRunning
  private let statistics: any IdleContainerStatisticsSampling
  private let workloadMebibytes: Int
  private let stressHoldSeconds: Int
  private let stressSamplingDelay: Duration
  private let retainedIdleDuration: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recordedObservations: [PostStressMemoryObservation] = []

  init(
    containers: any ContainerCreating & ContainerLifecycleManaging,
    stateReader: any ContainerStartupBenchmarkStateReading =
      AppleContainerStartupBenchmarkStateReader(),
    commands: any ContainerCommandRunning,
    statistics: any IdleContainerStatisticsSampling,
    imageReference: String = "docker.io/library/alpine:3.21",
    expectedImageDigest: String,
    workloadMebibytes: Int = 64,
    stressHoldSeconds: Int = 3,
    stressSamplingDelay: Duration = .seconds(1),
    retainedIdleDuration: Duration = .seconds(10),
    makeContainerID: @escaping @Sendable () -> String = {
      "nativecontainers-stress-\(UUID().uuidString.lowercased().prefix(8))"
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard
      (1...128).contains(workloadMebibytes),
      (2...60).contains(stressHoldSeconds),
      stressSamplingDelay >= .milliseconds(100),
      stressSamplingDelay < .seconds(stressHoldSeconds),
      retainedIdleDuration >= .seconds(1),
      retainedIdleDuration <= .seconds(300)
    else {
      throw PostStressMemoryBenchmarkError.invalidConfiguration
    }
    lifecycle = ColdContainerStartupPerformanceBenchmarkScenario(
      containers: containers,
      stateReader: stateReader,
      imageReference: imageReference,
      expectedImageDigest: expectedImageDigest,
      makeContainerID: makeContainerID
    )
    self.commands = commands
    self.statistics = statistics
    self.workloadMebibytes = workloadMebibytes
    self.stressHoldSeconds = stressHoldSeconds
    self.stressSamplingDelay = stressSamplingDelay
    self.retainedIdleDuration = retainedIdleDuration
    self.sleep = sleep
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
    let baseline = try await requireMemorySample(id: id)
    let request = try ContainerCommandRequest(
      executable: "/bin/sh",
      arguments: [
        "-c", Self.workload, "nativecontainers-memory-stress",
        String(workloadMebibytes), String(stressHoldSeconds),
      ],
      timeoutSeconds: stressHoldSeconds + 120
    )
    let commandTask = Task {
      try await commands.executeCommand(in: id, request: request)
    }

    let stressed: (usage: UInt64, limit: UInt64)
    do {
      try await sleep(stressSamplingDelay)
      stressed = try await requireMemorySample(id: id)
    } catch {
      commandTask.cancel()
      _ = try? await commandTask.value
      throw error
    }

    let result = try await commandTask.value
    guard !result.outputWasTruncated else {
      throw PostStressMemoryBenchmarkError.outputWasTruncated
    }
    guard result.exitCode == 0 else {
      throw PostStressMemoryBenchmarkError.commandFailed(result.exitCode)
    }
    guard
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        == Self.successMarker
    else {
      throw PostStressMemoryBenchmarkError.invalidSuccessMarker
    }

    try await sleep(retainedIdleDuration)
    let retained = try await requireMemorySample(id: id)
    guard baseline.limit == stressed.limit, stressed.limit == retained.limit else {
      throw PostStressMemoryBenchmarkError.memoryLimitChanged
    }
    guard stressed.usage >= baseline.usage else {
      throw PostStressMemoryBenchmarkError.stressNotObserved
    }
    try await lifecycle.stopCurrentContainer()
    recordedObservations.append(
      PostStressMemoryObservation(
        baselineMemoryUsageBytes: baseline.usage,
        stressedMemoryUsageBytes: stressed.usage,
        retainedMemoryUsageBytes: retained.usage,
        memoryLimitBytes: retained.limit,
        workloadMebibytes: workloadMebibytes,
        stopConfirmed: true
      )
    )
    return nil
  }

  func cleanUpIteration() async throws {
    try await lifecycle.cleanUpIteration()
  }

  func observations() -> [PostStressMemoryObservation] {
    recordedObservations
  }

  private func requireMemorySample(
    id: String
  ) async throws -> (usage: UInt64, limit: UInt64) {
    guard
      let sample = try await statistics.sampleContainer(id: id),
      let usage = sample.memoryUsageBytes,
      let limit = sample.memoryLimitBytes,
      limit == 256 * ContainerCreationRequest.bytesPerMiB,
      usage <= limit
    else {
      throw PostStressMemoryBenchmarkError.statisticsUnavailable
    }
    return (usage, limit)
  }
}

enum PostStressMemoryBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case statisticsUnavailable
  case commandFailed(Int32)
  case outputWasTruncated
  case invalidSuccessMarker
  case memoryLimitChanged
  case stressNotObserved

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The post-stress benchmark configuration is outside its bounded limits."
    case .statisticsUnavailable:
      "The post-stress benchmark could not obtain bounded resident-memory counters."
    case .commandFailed(let exitCode):
      "The fixed guest-memory workload exited with status \(exitCode)."
    case .outputWasTruncated:
      "The fixed guest-memory workload exceeded its bounded output limit."
    case .invalidSuccessMarker:
      "The fixed guest-memory workload did not return its completion marker."
    case .memoryLimitChanged:
      "The post-stress benchmark container memory limit changed during measurement."
    case .stressNotObserved:
      "The post-stress benchmark did not observe memory growth during the fixed workload."
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
      values.fileSize.map({ Int64($0) }) == byteCount
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

struct ImagePullDiskGrowthObservation: Equatable, Sendable {
  let reference: String
  let digest: String
  let allocatedImageBytesBefore: UInt64
  let allocatedImageBytesAfter: UInt64
  let allocatedImageGrowthBytes: UInt64
  let imageCountBefore: Int
  let imageCountAfter: Int
}

actor ImagePullDiskGrowthPerformanceBenchmarkScenario:
  PerformanceBenchmarkScenario
{
  nonisolated let kind = PerformanceBenchmarkKind.imagePullAndDiskGrowth

  private let images: any ImageManaging
  private let storage: any AppleRuntimeStorageUsageLoading
  private let reference: String
  private let maxConcurrentDownloads: Int
  private var preparedPlan: ImagePullPlan?
  private var storageBeforePull: AppleRuntimeStorageUsage?
  private var pulledResult: ImagePullResult?
  private var recordedObservations: [ImagePullDiskGrowthObservation] = []

  init(
    images: any ImageManaging,
    storage: any AppleRuntimeStorageUsageLoading,
    reference: String,
    maxConcurrentDownloads: Int = 4
  ) throws {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !reference.isEmpty,
      !reference.contains("@"),
      (1...16).contains(maxConcurrentDownloads)
    else {
      throw ImagePullDiskGrowthBenchmarkError.invalidConfiguration
    }
    self.images = images
    self.storage = storage
    self.reference = reference
    self.maxConcurrentDownloads = maxConcurrentDownloads
  }

  func prepareIteration() async throws {
    guard preparedPlan == nil, storageBeforePull == nil, pulledResult == nil else {
      throw ImagePullDiskGrowthBenchmarkError.invalidIterationState
    }
    let plan = try await images.prepareImagePull(
      reference: reference,
      platform: .current,
      transport: .https,
      unpackAfterPull: false,
      maxConcurrentDownloads: maxConcurrentDownloads
    )
    try validate(plan)
    preparedPlan = plan
  }

  func prepareMeasurement() async throws {
    guard let preparedPlan else {
      throw ImagePullDiskGrowthBenchmarkError.invalidIterationState
    }
    let refreshed = try await images.prepareImagePull(
      reference: reference,
      platform: .current,
      transport: .https,
      unpackAfterPull: false,
      maxConcurrentDownloads: maxConcurrentDownloads
    )
    try validate(refreshed)
    guard Self.hasSameExecutionIdentity(refreshed, preparedPlan) else {
      throw ImagePullDiskGrowthBenchmarkError.planChanged
    }
    storageBeforePull = try await storage.loadAppleRuntimeStorageUsage()
  }

  func perform() async throws -> Int64? {
    guard let preparedPlan, let storageBeforePull else {
      throw ImagePullDiskGrowthBenchmarkError.invalidIterationState
    }
    let result: ImagePullResult
    do {
      result = try await images.pullImage(
        preparedPlan,
        authorization: .none
      ) { _ in }
      pulledResult = result
    } catch let partial as ImagePullPartialCompletionError {
      pulledResult = partial.result
      throw partial
    }
    guard
      result.reference == preparedPlan.normalizedReference,
      !result.digest.isEmpty,
      result.replacedDigest == nil,
      result.unpackOutcome == nil
    else {
      throw ImagePullDiskGrowthBenchmarkError.resultChanged
    }
    let storageAfterPull = try await storage.loadAppleRuntimeStorageUsage()
    guard
      storageAfterPull.images.allocatedBytes
        >= storageBeforePull.images.allocatedBytes,
      storageAfterPull.images.totalCount >= storageBeforePull.images.totalCount
    else {
      throw ImagePullDiskGrowthBenchmarkError.storageAccountingRegressed
    }
    let growth =
      storageAfterPull.images.allocatedBytes
      - storageBeforePull.images.allocatedBytes
    recordedObservations.append(
      ImagePullDiskGrowthObservation(
        reference: result.reference,
        digest: result.digest,
        allocatedImageBytesBefore: storageBeforePull.images.allocatedBytes,
        allocatedImageBytesAfter: storageAfterPull.images.allocatedBytes,
        allocatedImageGrowthBytes: growth,
        imageCountBefore: storageBeforePull.images.totalCount,
        imageCountAfter: storageAfterPull.images.totalCount
      )
    )
    return nil
  }

  func cleanUpIteration() async throws {
    let result = pulledResult
    preparedPlan = nil
    storageBeforePull = nil
    pulledResult = nil
    guard let result else { return }

    let plan = try await images.prepareImageDeletion(reference: result.reference)
    guard
      plan.reference == result.reference,
      plan.digest == result.digest,
      plan.usedByContainerIDs.isEmpty,
      !plan.isInfrastructureImage
    else {
      throw ImagePullDiskGrowthBenchmarkError.cleanupIdentityChanged
    }
    let cleanup = try await images.deleteImage(plan)
    guard
      cleanup.completedWithoutFailures,
      cleanup.removedReferences.contains(result.reference)
    else {
      throw ImagePullDiskGrowthBenchmarkError.cleanupNotConfirmed
    }
  }

  func observations() -> [ImagePullDiskGrowthObservation] {
    recordedObservations
  }

  private func validate(_ plan: ImagePullPlan) throws {
    guard
      plan.existingDigest == nil,
      plan.platform != .all,
      plan.requestedTransport == .https,
      plan.resolvedTransport == .https,
      !plan.unpackAfterPull,
      plan.maxConcurrentDownloads == maxConcurrentDownloads,
      !plan.normalizedReference.isEmpty
    else {
      throw ImagePullDiskGrowthBenchmarkError.invalidPlan
    }
  }

  private static func hasSameExecutionIdentity(
    _ lhs: ImagePullPlan,
    _ rhs: ImagePullPlan
  ) -> Bool {
    lhs.normalizedReference == rhs.normalizedReference
      && lhs.registryHost == rhs.registryHost
      && lhs.existingDigest == rhs.existingDigest
      && lhs.platform == rhs.platform
      && lhs.requestedTransport == rhs.requestedTransport
      && lhs.resolvedTransport == rhs.resolvedTransport
      && lhs.unpackAfterPull == rhs.unpackAfterPull
      && lhs.maxConcurrentDownloads == rhs.maxConcurrentDownloads
  }
}

enum ImagePullDiskGrowthBenchmarkError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case invalidIterationState
  case invalidPlan
  case planChanged
  case resultChanged
  case storageAccountingRegressed
  case cleanupIdentityChanged
  case cleanupNotConfirmed

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The image-pull benchmark requires an unpinned reference and 1–16 concurrent downloads."
    case .invalidIterationState:
      "The image-pull benchmark iteration is not in a valid state."
    case .invalidPlan:
      "The image-pull benchmark requires an absent current-platform image over HTTPS without unpacking."
    case .planChanged:
      "The reviewed image-pull benchmark plan changed before execution."
    case .resultChanged:
      "The image-pull benchmark result did not match its reviewed plan."
    case .storageAccountingRegressed:
      "Apple runtime image allocation or count regressed during the isolated pull measurement."
    case .cleanupIdentityChanged:
      "The pulled image identity changed before benchmark cleanup."
    case .cleanupNotConfirmed:
      "The exact pulled image reference was not confirmed removed after the benchmark."
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
