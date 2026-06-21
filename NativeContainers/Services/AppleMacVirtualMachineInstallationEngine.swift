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
      let configuration = try configurationFactory.makeConfiguration(for: machine)
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
  struct AppleMacVirtualMachineConfigurationFactory {
    func makeConfiguration(
      for machine: PreparedMacVirtualMachine
    ) throws -> VZVirtualMachineConfiguration {
      let resources = machine.manifest.resources
      guard resources.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        resources.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount
      else {
        throw MacVirtualMachineInstallationError.unsupportedCPUCount(resources.cpuCount)
      }
      guard resources.memoryBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        resources.memoryBytes <= VZVirtualMachineConfiguration.maximumAllowedMemorySize,
        resources.memoryBytes.isMultiple(of: 1_048_576)
      else {
        throw MacVirtualMachineInstallationError.unsupportedMemorySize(resources.memoryBytes)
      }

      let diskSize = try diskSize(at: machine.diskImageURL)
      guard diskSize > 0, diskSize.isMultiple(of: 512) else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(diskSize)
      }

      let hardwareModelData = try Data(contentsOf: machine.hardwareModelURL)
      guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
        throw MacVirtualMachineInstallationError.invalidHardwareModel
      }
      let machineIdentifierData = try Data(contentsOf: machine.machineIdentifierURL)
      guard
        let machineIdentifier = VZMacMachineIdentifier(
          dataRepresentation: machineIdentifierData
        )
      else {
        throw MacVirtualMachineInstallationError.invalidMachineIdentifier
      }

      let platform = VZMacPlatformConfiguration()
      platform.hardwareModel = hardwareModel
      platform.machineIdentifier = machineIdentifier
      platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: machine.auxiliaryStorageURL)

      let diskAttachment = try VZDiskImageStorageDeviceAttachment(
        url: machine.diskImageURL,
        readOnly: false,
        cachingMode: .automatic,
        synchronizationMode: .full
      )
      let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

      let graphics = VZMacGraphicsDeviceConfiguration()
      graphics.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: 1_920,
          heightInPixels: 1_200,
          pixelsPerInch: 144
        )
      ]

      let network = VZVirtioNetworkDeviceConfiguration()
      network.attachment = VZNATNetworkDeviceAttachment()

      let configuration = VZVirtualMachineConfiguration()
      configuration.platform = platform
      configuration.bootLoader = VZMacOSBootLoader()
      configuration.cpuCount = resources.cpuCount
      configuration.memorySize = resources.memoryBytes
      configuration.storageDevices = [disk]
      configuration.graphicsDevices = [graphics]
      configuration.networkDevices = [network]
      configuration.keyboards = [VZMacKeyboardConfiguration()]
      configuration.pointingDevices = [VZMacTrackpadConfiguration()]
      configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
      configuration.memoryBalloonDevices = [
        VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
      ]

      do {
        try configuration.validate()
      } catch {
        throw MacVirtualMachineInstallationError.invalidConfiguration(
          error.localizedDescription
        )
      }
      return configuration
    }

    private func diskSize(at url: URL) throws -> UInt64 {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let number = attributes[.size] as? NSNumber else {
        throw MacVirtualMachineInstallationError.invalidDiskSize(0)
      }
      return number.uint64Value
    }
  }

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
          guard let self else { return }
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
