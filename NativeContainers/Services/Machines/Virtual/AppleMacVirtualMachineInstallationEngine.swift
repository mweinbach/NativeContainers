import Foundation
@preconcurrency import Virtualization

@MainActor
final class AppleMacVirtualMachineInstallationEngine: MacVirtualMachineInstallationEngine {
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
    for machine: PreparedMacVirtualMachine
  ) throws -> any MacVirtualMachineInstallationSession {
    #if arch(arm64)
      let configuration = try configurationFactory.makeConfiguration(
        for: machine.resolvedMachine
      )
      let virtualMachine = VZVirtualMachine(configuration: configuration)
      let installer = VZMacOSInstaller(
        virtualMachine: virtualMachine,
        restoringFromImageAt: machine.restoreImageURL
      )
      return AppleMacVirtualMachineInstallationSession(
        virtualMachine: virtualMachine,
        installer: installer
      )
    #else
      throw MacVirtualMachineInstallationError.requiresAppleSilicon
    #endif
  }
}

#if arch(arm64)
  @MainActor
  private final class AppleMacVirtualMachineInstallationSession:
    MacVirtualMachineInstallationSession
  {
    private let virtualMachine: VZVirtualMachine
    private let installer: VZMacOSInstaller
    private var progressObservation: NSKeyValueObservation?
    private var hasStarted = false
    private var hasFinished = false
    private var cancellationPending = false
    private var cancellationIssued = false
    private var lastFraction = 0.0

    init(virtualMachine: VZVirtualMachine, installer: VZMacOSInstaller) {
      self.virtualMachine = virtualMachine
      self.installer = installer
    }

    func install(
      progress: @escaping MacVirtualMachineInstallationProgressHandler
    ) async throws {
      try Task.checkCancellation()
      observeProgress(progress)
      defer {
        progressObservation?.invalidate()
        progressObservation = nil
      }

      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          installer.install { result in
            Task { @MainActor in
              self.hasFinished = true
              continuation.resume(with: result)
            }
          }
          hasStarted = true
          if cancellationPending {
            issueCancellationIfPossible()
          }
        }
      } onCancel: {
        Task { @MainActor in
          self.requestCancellation()
        }
      }
    }

    private func observeProgress(
      _ handler: @escaping MacVirtualMachineInstallationProgressHandler
    ) {
      progressObservation = installer.progress.observe(
        \.fractionCompleted,
        options: [.initial, .new]
      ) { [weak self] observedProgress, _ in
        let fraction = observedProgress.fractionCompleted
        Task { @MainActor [weak self] in
          guard let self, !hasFinished else { return }
          let normalized = max(lastFraction, min(1, max(0, fraction)))
          lastFraction = normalized
          handler(
            MacVirtualMachineInstallationProgress(
              phase: .installing,
              fractionCompleted: normalized
            )
          )
        }
      }
    }

    private func requestCancellation() {
      guard !hasFinished else { return }
      guard hasStarted else {
        cancellationPending = true
        return
      }
      issueCancellationIfPossible()
    }

    private func issueCancellationIfPossible() {
      guard !cancellationIssued, !hasFinished, !installer.progress.isFinished else { return }
      cancellationIssued = true
      installer.progress.cancel()
    }
  }
#endif
