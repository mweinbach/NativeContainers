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
    let configuration = try configurationFactory.makeConfiguration(for: machine)
    let virtualMachine = VZVirtualMachine(configuration: configuration)
    return AppleLinuxVirtualMachineRuntimeSession(
      target: target,
      virtualMachine: virtualMachine,
      hasInstallationMedia: machine.installationMediaURL != nil
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
  private(set) var hasInstallationMedia: Bool
  var canForceStop: Bool { virtualMachine.canStop }
  var eventHandler: LinuxVirtualMachineRuntimeEventHandler?

  private let virtualMachine: VZVirtualMachine

  init(
    target: LinuxVirtualMachineRuntimeTarget,
    virtualMachine: VZVirtualMachine,
    hasInstallationMedia: Bool
  ) {
    self.target = target
    self.virtualMachine = virtualMachine
    self.hasInstallationMedia = hasInstallationMedia
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
  }

  func close() {
    eventHandler = nil
    virtualMachine.delegate = nil
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
