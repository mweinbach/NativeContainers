import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import TerminalProgress

struct LinuxMachineRuntimeSnapshot: Equatable, Sendable {
  let identity: LinuxMachineIdentity
  let state: RuntimeState
  let backingContainerID: String?
  let isInitialized: Bool
  let imageDigest: String?
  let startedAt: Date?

  init(
    identity: LinuxMachineIdentity,
    state: RuntimeState,
    backingContainerID: String?,
    isInitialized: Bool,
    imageDigest: String? = nil,
    startedAt: Date? = nil
  ) {
    self.identity = identity
    self.state = state
    self.backingContainerID = backingContainerID
    self.isInitialized = isInitialized
    self.imageDigest = imageDigest
    self.startedAt = startedAt
  }
}

protocol LinuxMachineRuntime: Sendable {
  func snapshot(id: String) async throws -> LinuxMachineRuntimeSnapshot?
  func create(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineRuntimeSnapshot
  func boot(id: String) async throws -> LinuxMachineRuntimeSnapshot
  func provisionUser(id: String, timeoutSeconds: Int) async throws
  func stop(id: String) async throws
  func forceStop(backingContainerID: String) async throws
  func delete(_ target: LinuxMachineIdentity) async throws
}

actor AppleMachineRuntimeClient: LinuxMachineRuntime {
  private let imagePreparation: any LinuxMachineImagePreparing
  private let machineTransport: any AppleMachineTransport
  private let processClient: any LinuxMachineProcessCreating
  private let containerKillClient: any AppleContainerCleanupTransport

  init(
    imagePreparation: any LinuxMachineImagePreparing = AppleMachineImagePreparationService(),
    machineTransport: any AppleMachineTransport = AppleMachineXPCTransport(),
    processClient: any LinuxMachineProcessCreating = AppleContainerProcessXPCClient(),
    containerKillClient: any AppleContainerCleanupTransport = AppleContainerCleanupClient()
  ) {
    self.imagePreparation = imagePreparation
    self.machineTransport = machineTransport
    self.processClient = processClient
    self.containerKillClient = containerKillClient
  }

  func snapshot(id: String) async throws -> LinuxMachineRuntimeSnapshot? {
    let machines = try await machineTransport.list()
    guard machines.contains(where: { $0.id == id }) else {
      return nil
    }
    do {
      return Self.snapshot(from: try await machineTransport.inspect(id: id))
    } catch {
      let remaining = try await machineTransport.list()
      guard remaining.contains(where: { $0.id == id }) else {
        return nil
      }
      throw error
    }
  }

  func create(
    request: LinuxMachineCreationRequest,
    progress: @escaping ContainerProgressHandler
  ) async throws -> LinuxMachineRuntimeSnapshot {
    let relay = AppleContainerProgressRelay(handler: progress)
    await relay.emit(phase: .preparing, message: "Preparing Linux machine")

    let appleProgress: ProgressUpdateHandler = { events in
      await relay.consume(events)
    }
    let preparedCreation = try await imagePreparation.prepare(
      request: request,
      progressUpdate: appleProgress
    )

    try Task.checkCancellation()
    await relay.emit(phase: .creating, message: "Creating persistent Linux machine")
    try await machineTransport.create(
      configuration: preparedCreation.configuration,
      resources: preparedCreation.resources,
      bootConfig: preparedCreation.bootConfig
    )
    return Self.snapshot(from: try await machineTransport.inspect(id: request.name))
  }

  func boot(id: String) async throws -> LinuxMachineRuntimeSnapshot {
    var dynamicEnvironment: [String: String] = [:]
    if let sshAgentSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
      dynamicEnvironment["SSH_AUTH_SOCK"] = sshAgentSocket
    }
    return Self.snapshot(
      from: try await machineTransport.boot(id: id, dynamicEnvironment: dynamicEnvironment)
    )
  }

  func provisionUser(id: String, timeoutSeconds: Int) async throws {
    let machine = try await machineTransport.inspect(id: id)
    guard !machine.initialized else { return }
    guard let containerID = machine.containerId else {
      throw LinuxMachineManagementError.backingContainerMissing(id)
    }

    let configuration = ProcessConfiguration(
      executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
      arguments: ["-u"],
      environment: machine.configuration.processEnvironment,
      terminal: false
    )
    let process = try await processClient.createProcess(
      containerID: containerID,
      processID: UUID().uuidString.lowercased(),
      configuration: configuration
    )

    try await process.start()
    let exitCode = try await RuntimeProcessWaiter.wait(
      for: process,
      timeoutSeconds: timeoutSeconds
    )
    guard exitCode == 0 else {
      throw LinuxMachineManagementError.initializationFailed(id: id, exitCode: exitCode)
    }

    guard try await machineTransport.inspect(id: id).initialized else {
      throw LinuxMachineManagementError.initializationNotConfirmed(id)
    }
  }

  func stop(id: String) async throws {
    try await machineTransport.stop(id: id)
  }

  func forceStop(backingContainerID: String) async throws {
    try await containerKillClient.kill(id: backingContainerID)
  }

  func delete(_ target: LinuxMachineIdentity) async throws {
    guard let current = try await snapshot(id: target.id) else {
      throw LinuxMachineManagementError.missing(target.id)
    }
    guard current.identity == target else {
      throw LinuxMachineManagementError.staleTarget(target.id)
    }
    try await machineTransport.delete(id: target.id)
  }

  private static func snapshot(from machine: MachineSnapshot) -> LinuxMachineRuntimeSnapshot {
    LinuxMachineRuntimeSnapshot(
      identity: AppleLinuxMachineSnapshotMapper.identity(from: machine),
      state: AppleLinuxMachineSnapshotMapper.state(from: machine),
      backingContainerID: machine.containerId,
      isInitialized: machine.initialized,
      imageDigest: machine.configuration.image.digest,
      startedAt: machine.startedDate
    )
  }
}

protocol LinuxMachineSnapshotTransport: Sendable {
  func list(machineID: String) async throws -> MachineSnapshotCatalogV1
  func create(
    _ request: MachineSnapshotCreateRequestV1
  ) async throws -> MachineSnapshotCatalogV1
  func restore(
    _ request: MachineSnapshotRestoreRequestV1
  ) async throws -> MachineSnapshotCatalogV1
  func clone(
    _ request: MachineSnapshotCloneRequestV1
  ) async throws -> MachineSnapshotCloneResultV1
  func delete(
    _ request: MachineSnapshotDeleteRequestV1
  ) async throws -> MachineSnapshotCatalogV1
}

struct AppleLinuxMachineSnapshotTransport: LinuxMachineSnapshotTransport {
  func list(machineID: String) async throws -> MachineSnapshotCatalogV1 {
    try await MachineClient().listSnapshots(machineID: machineID)
  }

  func create(
    _ request: MachineSnapshotCreateRequestV1
  ) async throws -> MachineSnapshotCatalogV1 {
    try await MachineClient().createSnapshot(request)
  }

  func restore(
    _ request: MachineSnapshotRestoreRequestV1
  ) async throws -> MachineSnapshotCatalogV1 {
    try await MachineClient().restoreSnapshot(request)
  }

  func clone(
    _ request: MachineSnapshotCloneRequestV1
  ) async throws -> MachineSnapshotCloneResultV1 {
    try await MachineClient().cloneSnapshot(request)
  }

  func delete(
    _ request: MachineSnapshotDeleteRequestV1
  ) async throws -> MachineSnapshotCatalogV1 {
    try await MachineClient().deleteSnapshot(request)
  }
}

protocol LinuxMachineSnapshotRuntimeVerifying: Sendable {
  func verifySnapshotSupport() async throws
}

struct NativeContainersLinuxMachineSnapshotRuntimeVerifier:
  LinuxMachineSnapshotRuntimeVerifying
{
  static let requiredVersion = "1.0.0-nc.2"

  private let activeRuntimeVerifier: any ActiveNativeRuntimeVerifying

  init(
    activeRuntimeVerifier: any ActiveNativeRuntimeVerifying =
      ProductionActiveNativeRuntimeVerifier()
  ) {
    self.activeRuntimeVerifier = activeRuntimeVerifier
  }

  func verifySnapshotSupport() async throws {
    do {
      let verified = try await activeRuntimeVerifier.verifyActiveNativeRuntime()
      guard
        verified.origin == .nativeContainers,
        verified.version == Self.requiredVersion,
        verified.builderArtifact == .pinned
      else {
        throw LinuxMachineSnapshotError.requiresNativeContainersRuntime(
          Self.requiredVersion
        )
      }
    } catch {
      throw LinuxMachineSnapshotError.requiresNativeContainersRuntime(
        Self.requiredVersion
      )
    }
  }
}

actor AppleLinuxMachineSnapshotService: LinuxMachineSnapshotManaging {
  private let machineTransport: any AppleMachineTransport
  private let snapshotTransport: any LinuxMachineSnapshotTransport
  private let runtimeVerifier: any LinuxMachineSnapshotRuntimeVerifying
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    machineTransport: any AppleMachineTransport = AppleMachineXPCTransport(),
    snapshotTransport: any LinuxMachineSnapshotTransport =
      AppleLinuxMachineSnapshotTransport(),
    runtimeVerifier: any LinuxMachineSnapshotRuntimeVerifying =
      NativeContainersLinuxMachineSnapshotRuntimeVerifier(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.machineTransport = machineTransport
    self.snapshotTransport = snapshotTransport
    self.runtimeVerifier = runtimeVerifier
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func loadSnapshots(
    for target: LinuxMachineIdentity
  ) async throws -> LinuxMachineSnapshotCatalog {
    try await runtimeVerifier.verifySnapshotSupport()
    try await requireStoppedMachine(target)
    return try map(try await snapshotTransport.list(machineID: target.id), target: target)
  }

  func createSnapshot(
    named name: String,
    in catalog: LinuxMachineSnapshotCatalog
  ) async throws -> LinuxMachineSnapshotCatalog {
    let reviewedName = try validateSnapshotName(name, catalog: catalog)
    guard catalog.canCreate else { throw LinuxMachineSnapshotError.snapshotLimit }
    return try await runtimeMutationCoordinator.perform { [self] in
      try await runtimeVerifier.verifySnapshotSupport()
      try await requireStoppedMachine(catalog.target)
      let response = try await snapshotTransport.create(
        MachineSnapshotCreateRequestV1(
          machineID: catalog.target.id,
          name: reviewedName,
          precondition: precondition(for: catalog)
        )
      )
      return try map(response, target: catalog.target)
    }
  }

  func restoreSnapshot(
    _ snapshotID: UUID,
    in catalog: LinuxMachineSnapshotCatalog
  ) async throws -> LinuxMachineSnapshotCatalog {
    try requireSnapshot(snapshotID, in: catalog)
    return try await runtimeMutationCoordinator.perform { [self] in
      try await runtimeVerifier.verifySnapshotSupport()
      try await requireStoppedMachine(catalog.target)
      let response = try await snapshotTransport.restore(
        MachineSnapshotRestoreRequestV1(
          machineID: catalog.target.id,
          snapshotID: snapshotID,
          precondition: precondition(for: catalog)
        )
      )
      return try map(response, target: catalog.target)
    }
  }

  func cloneSnapshot(
    _ snapshotID: UUID,
    as machineID: String,
    in catalog: LinuxMachineSnapshotCatalog
  ) async throws -> LinuxMachineSnapshotCloneResult {
    try requireSnapshot(snapshotID, in: catalog)
    let cloneID = try validateCloneName(machineID, sourceID: catalog.target.id)
    return try await runtimeMutationCoordinator.perform { [self] in
      try await runtimeVerifier.verifySnapshotSupport()
      try await requireStoppedMachine(catalog.target)
      let response = try await snapshotTransport.clone(
        MachineSnapshotCloneRequestV1(
          machineID: catalog.target.id,
          snapshotID: snapshotID,
          cloneMachineID: cloneID,
          precondition: precondition(for: catalog)
        )
      )
      let clone = AppleLinuxMachineSnapshotMapper.identity(from: response.clone)
      guard AppleLinuxMachineSnapshotMapper.state(from: response.clone) == .stopped else {
        throw LinuxMachineSnapshotError.staleMachine(clone.id)
      }
      return LinuxMachineSnapshotCloneResult(
        sourceCatalog: try map(response.sourceCatalog, target: catalog.target),
        clone: clone
      )
    }
  }

  func deleteSnapshot(
    _ snapshotID: UUID,
    in catalog: LinuxMachineSnapshotCatalog
  ) async throws -> LinuxMachineSnapshotCatalog {
    try requireSnapshot(snapshotID, in: catalog)
    return try await runtimeMutationCoordinator.perform { [self] in
      try await runtimeVerifier.verifySnapshotSupport()
      try await requireStoppedMachine(catalog.target)
      let response = try await snapshotTransport.delete(
        MachineSnapshotDeleteRequestV1(
          machineID: catalog.target.id,
          snapshotID: snapshotID,
          precondition: precondition(for: catalog)
        )
      )
      return try map(response, target: catalog.target)
    }
  }

  private func requireStoppedMachine(_ target: LinuxMachineIdentity) async throws {
    guard target.hasStableCreationIdentity else {
      throw LinuxMachineSnapshotError.stableIdentityRequired(target.id)
    }
    let current: MachineSnapshot
    do {
      current = try await machineTransport.inspect(id: target.id)
    } catch {
      let machines = try await machineTransport.list()
      guard machines.contains(where: { $0.id == target.id }) else {
        throw LinuxMachineSnapshotError.missingMachine(target.id)
      }
      throw error
    }
    guard AppleLinuxMachineSnapshotMapper.identity(from: current) == target else {
      throw LinuxMachineSnapshotError.staleMachine(target.id)
    }
    guard AppleLinuxMachineSnapshotMapper.state(from: current) == .stopped else {
      throw LinuxMachineSnapshotError.machineMustBeStopped(target.id)
    }
  }

  private nonisolated func validateSnapshotName(
    _ name: String,
    catalog: LinuxMachineSnapshotCatalog
  ) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= MachineSnapshotAPIV1.maximumNameLength,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw LinuxMachineSnapshotError.invalidName
    }
    guard !catalog.snapshots.contains(where: { $0.name == value }) else {
      throw LinuxMachineSnapshotError.duplicateName(value)
    }
    return value
  }

  private nonisolated func validateCloneName(
    _ name: String,
    sourceID: String
  ) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != sourceID, value.count <= LinuxMachineCreationRequest.maximumNameLength,
      value.range(
        of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#,
        options: .regularExpression
      ) != nil
    else {
      throw LinuxMachineSnapshotError.invalidCloneName
    }
    return value
  }

  private nonisolated func requireSnapshot(
    _ id: UUID,
    in catalog: LinuxMachineSnapshotCatalog
  ) throws {
    guard catalog.snapshots.contains(where: { $0.id == id }) else {
      throw LinuxMachineSnapshotError.missingSnapshot(id)
    }
  }

  private nonisolated func precondition(
    for catalog: LinuxMachineSnapshotCatalog
  ) -> MachineSnapshotPreconditionV1 {
    MachineSnapshotPreconditionV1(
      machineGeneration: catalog.machineGeneration,
      catalogRevision: catalog.catalogRevision
    )
  }

  private nonisolated func map(
    _ catalog: MachineSnapshotCatalogV1,
    target: LinuxMachineIdentity
  ) throws -> LinuxMachineSnapshotCatalog {
    guard catalog.schemaVersion == MachineSnapshotAPIV1.schemaVersion,
      catalog.machineID == target.id,
      catalog.snapshots.count <= MachineSnapshotAPIV1.maximumSnapshotsPerMachine
    else {
      throw LinuxMachineSnapshotError.staleMachine(target.id)
    }
    return LinuxMachineSnapshotCatalog(
      target: target,
      machineGeneration: catalog.machineGeneration,
      catalogRevision: catalog.catalogRevision,
      snapshots: catalog.snapshots.map {
        LinuxMachineSnapshotRecord(
          id: $0.id,
          name: $0.name,
          createdAt: $0.createdAt,
          allocatedSize: $0.allocatedSize,
          capturedMachineGeneration: $0.capturedMachineGeneration
        )
      }
    )
  }
}
