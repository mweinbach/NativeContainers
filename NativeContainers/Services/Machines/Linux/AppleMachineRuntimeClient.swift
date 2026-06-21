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
      identity: LinuxMachineIdentity(
        id: machine.id,
        imageReference: machine.configuration.image.reference,
        platform: String(describing: machine.platform),
        createdAt: machine.createdDate
      ),
      state: RuntimeState(rawValue: machine.status.rawValue) ?? .unknown,
      backingContainerID: machine.containerId,
      isInitialized: machine.initialized
    )
  }
}
