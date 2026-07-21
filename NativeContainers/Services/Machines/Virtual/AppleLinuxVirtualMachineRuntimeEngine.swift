import Foundation
@preconcurrency import Virtualization

@MainActor
final class AppleLinuxVirtualMachineRuntimeEngine: LinuxVirtualMachineRuntimeEngine {
  private let configurationFactory: AppleLinuxVirtualMachineConfigurationFactory

  init(
    configurationFactory: AppleLinuxVirtualMachineConfigurationFactory =
      AppleLinuxVirtualMachineConfigurationFactory()
  ) {
    self.configurationFactory = configurationFactory
  }

  func makeSession(
    for machine: ResolvedLinuxVirtualMachine,
    target: LinuxVirtualMachineRuntimeTarget
  ) throws -> any LinuxVirtualMachineRuntimeEngineSession {
    guard machine.manifest.id == target.machineID else {
      throw LinuxVirtualMachineRuntimeError.staleTarget(target)
    }
    let runtimeConfiguration = try configurationFactory.makeRuntimeConfiguration(
      for: machine
    )
    let virtualMachine = VZVirtualMachine(
      configuration: runtimeConfiguration.configuration
    )
    let memoryBalloonController = try AppleVirtualMachineMemoryBalloonController(
      virtualMachine: virtualMachine,
      configuredMemoryBytes: machine.manifest.resources.memoryBytes,
      minimumTargetMemoryBytes: VirtualMachineResources.bytesPerGiB
    )
    return AppleLinuxVirtualMachineRuntimeSession(
      target: target,
      virtualMachine: virtualMachine,
      saveRestoreSupport: machine.manifest.isHardenedLinuxBox
        ? .unsupported(
          "Residential Linux boxes never serialize guest memory to a saved-state file."
        )
        : runtimeConfiguration.saveRestoreSupport,
      hasInstallationMedia: machine.installationMediaURL != nil,
      isManagedLinuxBox: machine.manifest.isManagedLinuxBox,
      sharedDirectoryAccess: runtimeConfiguration.sharedDirectoryAccess,
      memoryBalloonController: memoryBalloonController
    )
  }
}

@MainActor
private final class AppleLinuxVirtualMachineRuntimeSession: NSObject,
  LinuxVirtualMachineRuntimeEngineSession,
  @preconcurrency VZVirtualMachineDelegate
{
  let target: LinuxVirtualMachineRuntimeTarget
  let console: LinuxVirtualMachineConsole?
  private(set) var saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport
  let memoryBalloonController: (any VirtualMachineMemoryBalloonControlling)?
  private(set) var hasInstallationMedia: Bool
  var canForceStop: Bool { virtualMachine.canStop }
  let isManagedLinuxBox: Bool
  var eventHandler: LinuxVirtualMachineRuntimeEventHandler?

  private let virtualMachine: VZVirtualMachine
  private let sharedDirectoryAccess: LinuxVirtualMachineSharedDirectoryAccess
  private var agentTransports: [any LinuxVirtualMachineAgentTransport] = []

  init(
    target: LinuxVirtualMachineRuntimeTarget,
    virtualMachine: VZVirtualMachine,
    saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport,
    hasInstallationMedia: Bool,
    isManagedLinuxBox: Bool,
    sharedDirectoryAccess: LinuxVirtualMachineSharedDirectoryAccess,
    memoryBalloonController: any VirtualMachineMemoryBalloonControlling
  ) {
    self.target = target
    self.virtualMachine = virtualMachine
    self.saveRestoreSupport = saveRestoreSupport
    self.hasInstallationMedia = hasInstallationMedia
    self.isManagedLinuxBox = isManagedLinuxBox
    self.sharedDirectoryAccess = sharedDirectoryAccess
    self.memoryBalloonController = memoryBalloonController
    console = LinuxVirtualMachineConsole(
      target: target,
      virtualMachine: virtualMachine
    )
    super.init()
    virtualMachine.delegate = self
  }

  func start() async throws {
    guard virtualMachine.canStart else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable("start")
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await virtualMachine.start()
    }
    try await operation.value
  }

  func saveState(to url: URL) async throws {
    try requireSaveRestoreSupport()
    guard virtualMachine.state == .paused else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "save the state of"
      )
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        virtualMachine.saveMachineStateTo(url: url) { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      }
    }
    try await operation.value
  }

  func restoreState(from url: URL) async throws {
    try requireSaveRestoreSupport()
    guard virtualMachine.state == .stopped else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "restore the state of"
      )
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        virtualMachine.restoreMachineStateFrom(url: url) { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      }
    }
    try await operation.value
  }

  func pause() async throws {
    guard virtualMachine.canPause else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable("pause")
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await virtualMachine.pause()
    }
    try await operation.value
  }

  func resume() async throws {
    guard virtualMachine.canResume else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable("resume")
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await virtualMachine.resume()
    }
    try await operation.value
  }

  func requestStop() throws {
    guard virtualMachine.canRequestStop else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "request a graceful stop for"
      )
    }
    try virtualMachine.requestStop()
  }

  func forceStop() async throws {
    guard virtualMachine.canStop else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable("force stop")
    }
    let virtualMachine = virtualMachine
    let operation = Task { @MainActor in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        virtualMachine.stop { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      }
    }
    try await operation.value
  }

  func connectAgent(
    port: UInt32
  ) async throws -> any LinuxVirtualMachineAgentTransport {
    guard isManagedLinuxBox else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "connect a guest agent for"
      )
    }
    let devices = virtualMachine.socketDevices.compactMap {
      $0 as? VZVirtioSocketDevice
    }
    guard devices.count == 1 else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "find the managed guest-agent socket for"
      )
    }
    let connection = try await devices[0].connect(toPort: port)
    let holder = VZVirtioSocketConnectionHolder(connection)
    do {
      let transport = try POSIXLinuxVirtualMachineAgentTransport(
        descriptor: connection.fileDescriptor,
        label: "com.nativecontainers.linux-box.agent.\(target.machineID.uuidString.lowercased())"
      ) {
        holder.close()
      }
      agentTransports.append(transport)
      return transport
    } catch {
      holder.close()
      throw error
    }
  }

  func ejectInstallationMedia() async throws {
    guard hasInstallationMedia else {
      throw LinuxVirtualMachineRuntimeError.installationMediaNotAttached(
        target.machineID
      )
    }
    guard let controller = virtualMachine.usbControllers.first,
      let device = controller.usbDevices.first
    else {
      throw LinuxVirtualMachineRuntimeError.operationUnavailable(
        "find attached installation media for"
      )
    }

    let operation = Task { @MainActor in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        controller.detach(device: device) { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      }
    }
    try await operation.value
    hasInstallationMedia = false
    saveRestoreSupport = .unsupported(
      "Restart the VM after finishing installation before suspending it."
    )
  }

  func close() {
    for transport in agentTransports {
      transport.close()
    }
    agentTransports.removeAll()
    eventHandler = nil
    virtualMachine.delegate = nil
    console?.invalidate()
    sharedDirectoryAccess.release()
  }

  private func requireSaveRestoreSupport() throws {
    switch saveRestoreSupport {
    case .supported:
      return
    case .unsupported(let reason):
      throw LinuxVirtualMachineRuntimeError.saveRestoreUnsupported(reason)
    case .unknown:
      throw LinuxVirtualMachineRuntimeError.saveRestoreUnsupported(
        "capability validation did not complete"
      )
    }
  }


  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    eventHandler?(.guestStopped)
  }

  func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    didStopWithError error: any Error
  ) {
    eventHandler?(.stoppedWithError(error.localizedDescription))
  }
}

private final class VZVirtioSocketConnectionHolder: @unchecked Sendable {
  private let connection: VZVirtioSocketConnection
  private let lock = NSLock()
  private var closed = false

  init(_ connection: VZVirtioSocketConnection) {
    self.connection = connection
  }

  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    connection.close()
  }
}
