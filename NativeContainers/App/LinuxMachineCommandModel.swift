import Foundation
import Observation

@MainActor
@Observable
final class LinuxMachineCommandModel {
  private(set) var isRunningCommand = false
  private(set) var commandResult: ContainerCommandResult?
  private(set) var errorMessage: String?

  let machineID: String

  private let target: LinuxMachineIdentity
  private let service: any MachineCommandRunning
  private let didFinish: @MainActor @Sendable () async -> Void

  init(
    machine: LinuxMachineRecord,
    service: any MachineCommandRunning,
    didFinish: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    machineID = machine.id
    target = LinuxMachineIdentity(machine: machine)
    self.service = service
    self.didFinish = didFinish
  }

  func execute(_ request: LinuxMachineCommandRequest) async {
    guard !isRunningCommand else { return }
    isRunningCommand = true
    commandResult = nil
    errorMessage = nil
    defer { isRunningCommand = false }

    do {
      commandResult = try await service.executeCommand(in: target, request: request)
    } catch is CancellationError {
      errorMessage = "The command was cancelled and its process was KILLed."
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshIgnoringCancellation()
  }

  func clearError() {
    errorMessage = nil
  }

  private func refreshIgnoringCancellation() async {
    let didFinish = self.didFinish
    await Task.detached {
      await didFinish()
    }.value
  }
}
