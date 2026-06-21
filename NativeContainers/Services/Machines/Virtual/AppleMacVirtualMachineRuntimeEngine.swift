import Foundation
@preconcurrency import Virtualization

@MainActor
final class AppleMacVirtualMachineRuntimeEngine: MacVirtualMachineRuntimeEngine {
  #if arch(arm64)
    private let configurationFactory: AppleMacVirtualMachineConfigurationFactory

    init(
      configurationFactory: AppleMacVirtualMachineConfigurationFactory =
        AppleMacVirtualMachineConfigurationFactory()
    ) {
      self.configurationFactory = configurationFactory
    }
  #else
    init() {}
  #endif

  func makeSession(
    for machine: ResolvedMacVirtualMachine,
    target: MacVirtualMachineRuntimeTarget
  ) throws -> any MacVirtualMachineRuntimeEngineSession {
    #if arch(arm64)
      guard machine.manifest.id == target.machineID else {
        throw MacVirtualMachineRuntimeError.staleTarget(target)
      }
      let runtimeConfiguration = try configurationFactory.makeRuntimeConfiguration(
        for: machine
      )
      let virtualMachine = VZVirtualMachine(
        configuration: runtimeConfiguration.configuration
      )
      let usbController: (any MacVirtualMachineUSBControlling)?
      if #available(macOS 27.0, *) {
        usbController = try AppleMacVirtualMachineUSBController(
          virtualMachine: virtualMachine
        )
      } else {
        usbController = nil
      }
      return AppleMacVirtualMachineRuntimeSession(
        target: target,
        virtualMachine: virtualMachine,
        saveRestoreSupport: runtimeConfiguration.saveRestoreSupport,
        sharedDirectoryAccess: runtimeConfiguration.sharedDirectoryAccess,
        usbController: usbController
      )
    #else
      throw MacVirtualMachineRuntimeError.requiresAppleSilicon
    #endif
  }
}

#if arch(arm64)
  @MainActor
  private final class AppleMacVirtualMachineRuntimeSession: NSObject,
    MacVirtualMachineRuntimeEngineSession,
    @preconcurrency VZVirtualMachineDelegate
  {
    let target: MacVirtualMachineRuntimeTarget
    let console: MacVirtualMachineConsole?
    let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
    let usbController: (any MacVirtualMachineUSBControlling)?
    var canForceStop: Bool { virtualMachine.canStop }
    var eventHandler: MacVirtualMachineRuntimeEventHandler?

    private let virtualMachine: VZVirtualMachine
    private let sharedDirectoryAccess: MacVirtualMachineSharedDirectoryAccess

    init(
      target: MacVirtualMachineRuntimeTarget,
      virtualMachine: VZVirtualMachine,
      saveRestoreSupport: MacVirtualMachineSaveRestoreSupport,
      sharedDirectoryAccess: MacVirtualMachineSharedDirectoryAccess,
      usbController: (any MacVirtualMachineUSBControlling)?
    ) {
      self.target = target
      self.virtualMachine = virtualMachine
      self.saveRestoreSupport = saveRestoreSupport
      self.sharedDirectoryAccess = sharedDirectoryAccess
      self.usbController = usbController
      self.console = MacVirtualMachineConsole(target: target, virtualMachine: virtualMachine)
      super.init()
      virtualMachine.delegate = self
    }

    func start() async throws {
      guard virtualMachine.canStart else {
        throw MacVirtualMachineRuntimeError.operationUnavailable("start")
      }
      let virtualMachine = virtualMachine
      let operation = Task { @MainActor in
        try await virtualMachine.start()
      }
      try await operation.value
    }

    func start(provisioning request: MacGuestProvisioningRequest?) async throws {
      guard let request else {
        try await start()
        return
      }
      guard #available(macOS 27.0, *) else {
        throw MacGuestProvisioningError.hostUnsupported
      }
      guard virtualMachine.canStart else {
        throw MacVirtualMachineRuntimeError.operationUnavailable("start")
      }

      let guestOptions = VZMacGuestProvisioningOptions()
      guestOptions.fullName = request.fullName
      guestOptions.username = request.username
      guestOptions.password = request.password
      guestOptions.logsInAutomatically = request.logsInAutomatically
      guestOptions.enablesRemoteLogin = request.enablesRemoteLogin

      let startOptions = VZMacOSVirtualMachineStartOptions()
      try startOptions.setGuestProvisioning(guestOptions)

      let virtualMachine = virtualMachine
      let operation = Task { @MainActor in
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          virtualMachine.start(options: startOptions) { error in
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

    func saveState(to url: URL) async throws {
      try requireSaveRestoreSupport()
      guard virtualMachine.state == .paused else {
        throw MacVirtualMachineRuntimeError.operationUnavailable(
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
        throw MacVirtualMachineRuntimeError.operationUnavailable(
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
        throw MacVirtualMachineRuntimeError.operationUnavailable("pause")
      }
      let virtualMachine = virtualMachine
      let operation = Task { @MainActor in
        try await virtualMachine.pause()
      }
      try await operation.value
    }

    func resume() async throws {
      guard virtualMachine.canResume else {
        throw MacVirtualMachineRuntimeError.operationUnavailable("resume")
      }
      let virtualMachine = virtualMachine
      let operation = Task { @MainActor in
        try await virtualMachine.resume()
      }
      try await operation.value
    }

    func requestStop() throws {
      guard virtualMachine.canRequestStop else {
        throw MacVirtualMachineRuntimeError.operationUnavailable("request a graceful stop for")
      }
      try virtualMachine.requestStop()
    }

    func forceStop() async throws {
      guard virtualMachine.canStop else {
        throw MacVirtualMachineRuntimeError.operationUnavailable("force stop")
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

    func close() {
      eventHandler = nil
      virtualMachine.delegate = nil
      usbController?.close()
      sharedDirectoryAccess.release()
    }

    private func requireSaveRestoreSupport() throws {
      switch saveRestoreSupport {
      case .supported:
        return
      case .unsupported(let reason):
        throw MacVirtualMachineRuntimeError.saveRestoreUnsupported(reason)
      case .unknown:
        throw MacVirtualMachineRuntimeError.saveRestoreUnsupported(
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
#endif
