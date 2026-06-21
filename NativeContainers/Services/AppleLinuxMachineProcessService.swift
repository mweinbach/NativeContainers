import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient

struct LinuxMachineProcessTarget: Equatable, Sendable {
  let identity: LinuxMachineIdentity
  let backingContainerID: String
  let user: ProcessConfiguration.User
  let homeDirectory: String
}

protocol LinuxMachineProcessTargetResolving: Sendable {
  func resolve(_ target: LinuxMachineIdentity) async throws -> LinuxMachineProcessTarget
}

actor AppleLinuxMachineProcessTargetResolver: LinuxMachineProcessTargetResolving {
  private let lifecycle: any MachineLifecycleManaging
  private let machineTransport: any AppleMachineTransport

  init(
    lifecycle: any MachineLifecycleManaging,
    machineTransport: any AppleMachineTransport
  ) {
    self.lifecycle = lifecycle
    self.machineTransport = machineTransport
  }

  func resolve(_ target: LinuxMachineIdentity) async throws -> LinuxMachineProcessTarget {
    guard target.hasStableCreationIdentity else {
      throw LinuxMachineManagementError.stableIdentityRequired(target.id)
    }

    // startMachine is idempotent for a ready machine and owns boot/provision recovery.
    try await lifecycle.startMachine(target)

    // The backing container ID changes on every boot. Always inspect after readiness,
    // revalidate the complete durable identity, and use only this fresh process target.
    let machine = try await machineTransport.inspect(id: target.id)
    let currentIdentity = Self.identity(from: machine)
    guard currentIdentity == target else {
      throw LinuxMachineManagementError.staleTarget(target.id)
    }
    guard RuntimeState(rawValue: machine.status.rawValue) == .running else {
      throw LinuxMachineManagementError.notRunning(target.id)
    }
    guard machine.initialized else {
      throw LinuxMachineManagementError.initializationNotConfirmed(target.id)
    }
    guard let backingContainerID = machine.containerId else {
      throw LinuxMachineManagementError.backingContainerMissing(target.id)
    }

    return LinuxMachineProcessTarget(
      identity: currentIdentity,
      backingContainerID: backingContainerID,
      user: machine.configuration.user,
      homeDirectory: machine.configuration.home
    )
  }

  private static func identity(from machine: MachineSnapshot) -> LinuxMachineIdentity {
    LinuxMachineIdentity(
      id: machine.id,
      imageReference: machine.configuration.image.reference,
      platform: String(describing: machine.platform),
      createdAt: machine.createdDate
    )
  }
}

enum LinuxMachineProcessConfigurationFactory {
  private static let defaultEnvironment = [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  ]

  static func command(
    target: LinuxMachineProcessTarget,
    request: LinuxMachineCommandRequest
  ) throws -> ProcessConfiguration {
    try configuration(
      target: target,
      arguments: ["-s", request.command],
      environment: request.environment,
      workingDirectory: request.workingDirectory,
      terminal: false
    )
  }

  static func terminal(
    target: LinuxMachineProcessTarget,
    request: LinuxMachineTerminalRequest
  ) throws -> ProcessConfiguration {
    try configuration(
      target: target,
      arguments: ["-s"],
      environment: request.environment,
      workingDirectory: request.workingDirectory,
      terminal: true
    )
  }

  private static func configuration(
    target: LinuxMachineProcessTarget,
    arguments: [String],
    environment: [ContainerEnvironmentVariable],
    workingDirectory: String?,
    terminal: Bool
  ) throws -> ProcessConfiguration {
    ProcessConfiguration(
      executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
      arguments: arguments,
      environment: try Parser.allEnv(
        imageEnvs: defaultEnvironment,
        envFiles: [],
        envs: environment.map(\.entry)
      ),
      workingDirectory: workingDirectory ?? target.homeDirectory,
      terminal: terminal,
      user: target.user
    )
  }
}

actor AppleLinuxMachineProcessService: MachineCommandRunning, MachineTerminalOpening {
  private let targetResolver: any LinuxMachineProcessTargetResolving
  private let commandExecutor: any RuntimeCommandExecuting
  private let processClient: any AppleRuntimeProcessCreating

  init(
    targetResolver: any LinuxMachineProcessTargetResolving,
    commandExecutor: any RuntimeCommandExecuting = AppleRuntimeCommandExecutor(),
    processClient: any AppleRuntimeProcessCreating = AppleContainerProcessXPCClient()
  ) {
    self.targetResolver = targetResolver
    self.commandExecutor = commandExecutor
    self.processClient = processClient
  }

  func executeCommand(
    in target: LinuxMachineIdentity,
    request: LinuxMachineCommandRequest
  ) async throws -> ContainerCommandResult {
    let processTarget = try await targetResolver.resolve(target)
    let configuration = try LinuxMachineProcessConfigurationFactory.command(
      target: processTarget,
      request: request
    )
    return try await commandExecutor.execute(
      in: processTarget.backingContainerID,
      configuration: configuration,
      timeoutSeconds: request.timeoutSeconds
    )
  }

  func openTerminal(
    in target: LinuxMachineIdentity,
    request: LinuxMachineTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    let processTarget = try await targetResolver.resolve(target)
    let configuration = try LinuxMachineProcessConfigurationFactory.terminal(
      target: processTarget,
      request: request
    )
    let transport = PipeContainerTerminalTransport()

    do {
      let process = try await processClient.createRuntimeProcess(
        containerID: processTarget.backingContainerID,
        processID: UUID().uuidString.lowercased(),
        configuration: configuration,
        standardIO: [transport.childStandardInput, transport.childStandardOutput, nil]
      )
      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: request.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: request.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }
}
