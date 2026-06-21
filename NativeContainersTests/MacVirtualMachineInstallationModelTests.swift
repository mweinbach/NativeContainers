import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacVirtualMachineInstallationModelTests {
  @Test
  func successPublishesProgressAndRefreshesInventory() async throws {
    let machine = try makeMachine()
    let installer = ModelTestMacInstaller(behavior: .succeed)
    let refresh = ModelRefreshRecorder()
    let model = MacVirtualMachineInstallationModel(
      machine: machine,
      installer: installer
    ) {
      refresh.record()
    }

    let succeeded = await model.install()

    #expect(succeeded)
    #expect(model.didFinish)
    #expect(model.phase == .finalizing)
    #expect(model.fractionCompleted == 1)
    #expect(model.errorMessage == nil)
    #expect(refresh.count == 1)
  }

  @Test
  func failureIsVisibleAndRefreshesPersistedState() async throws {
    let machine = try makeMachine()
    let refresh = ModelRefreshRecorder()
    let model = MacVirtualMachineInstallationModel(
      machine: machine,
      installer: ModelTestMacInstaller(behavior: .fail)
    ) {
      refresh.record()
    }

    let succeeded = await model.install()

    #expect(!succeeded)
    #expect(!model.didFinish)
    #expect(model.phase == nil)
    #expect(model.errorMessage?.contains("expected") == true)
    #expect(refresh.count == 1)
  }

  @Test
  func taskCancellationProducesRecoveryGuidance() async throws {
    let machine = try makeMachine()
    let installer = ModelTestMacInstaller(behavior: .wait)
    let model = MacVirtualMachineInstallationModel(
      machine: machine,
      installer: installer
    ) {}

    let task = Task {
      await model.install()
    }
    await installer.waitUntilStarted()
    task.cancel()
    let succeeded = await task.value

    #expect(!succeeded)
    #expect(model.errorMessage?.contains("ready to retry") == true)
  }

  private func makeMachine() throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: "Model Test",
      guest: .macOS,
      installState: .readyToInstall,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}

private enum ModelTestMacInstallerError: LocalizedError {
  case expected

  var errorDescription: String? {
    "The expected installation failure occurred."
  }
}

@MainActor
private final class ModelTestMacInstaller: MacVirtualMachineInstalling {
  enum Behavior {
    case succeed
    case fail
    case wait
  }

  private let behavior: Behavior
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func install(
    id: UUID,
    progress: @escaping MacVirtualMachineInstallationProgressHandler
  ) async throws {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }

    progress(
      MacVirtualMachineInstallationProgress(
        phase: .installing,
        fractionCompleted: 0.5
      )
    )

    switch behavior {
    case .succeed:
      return
    case .fail:
      throw ModelTestMacInstallerError.expected
    case .wait:
      try await Task.sleep(for: .seconds(60))
    }
  }

  func recoverInterruptedInstallations() async throws {}

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }
}

@MainActor
private final class ModelRefreshRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
