import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineInstallationModel {
  let machine: VirtualMachineManifest

  private(set) var phase: MacVirtualMachineInstallationPhase?
  private(set) var fractionCompleted: Double?
  private(set) var errorMessage: String?
  private(set) var didFinish = false

  private let installer: any MacVirtualMachineInstalling
  private let refresh: @MainActor @Sendable () async -> Void

  init(
    machine: VirtualMachineManifest,
    installer: any MacVirtualMachineInstalling,
    refresh: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.machine = machine
    self.installer = installer
    self.refresh = refresh
  }

  var isWorking: Bool {
    phase != nil && !didFinish
  }

  func install() async -> Bool {
    guard !isWorking else { return false }
    phase = .preparing
    fractionCompleted = nil
    errorMessage = nil
    didFinish = false

    do {
      try await installer.install(id: machine.id) { [weak self] update in
        self?.receive(update)
      }
      didFinish = true
      phase = .finalizing
      fractionCompleted = 1
      await refresh()
      return true
    } catch is CancellationError {
      phase = nil
      fractionCompleted = nil
      errorMessage =
        "Installation was cancelled safely through Virtualization.framework. The pristine prepared media is ready to retry."
      await refresh()
      return false
    } catch {
      phase = nil
      fractionCompleted = nil
      errorMessage = error.localizedDescription
      await refresh()
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func receive(_ update: MacVirtualMachineInstallationProgress) {
    phase = update.phase
    fractionCompleted = update.fractionCompleted
  }
}
