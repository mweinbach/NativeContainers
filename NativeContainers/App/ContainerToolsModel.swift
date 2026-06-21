import Foundation
import Observation

@MainActor
@Observable
final class ContainerToolsModel {
  private(set) var isRunningCommand = false
  private(set) var isTransferring = false
  private(set) var isDetectingShell = false
  private(set) var commandResult: ContainerCommandResult?
  private(set) var detectedShell: ContainerShell?
  private(set) var errorMessage: String?
  private(set) var shellDetectionMessage: String?
  private(set) var transferMessage: String?

  let containerID: String
  private let tooling: any ContainerTooling
  private let shellDiscovery: any ContainerShellDiscovering

  init(
    containerID: String,
    tooling: any ContainerTooling,
    shellDiscovery: any ContainerShellDiscovering
  ) {
    self.containerID = containerID
    self.tooling = tooling
    self.shellDiscovery = shellDiscovery
  }

  func detectShell() async -> ContainerShell? {
    if let detectedShell {
      return detectedShell
    }
    guard !isDetectingShell else { return nil }

    isDetectingShell = true
    shellDetectionMessage = nil
    defer { isDetectingShell = false }

    do {
      let shell = try await shellDiscovery.discoverShell(in: containerID)
      detectedShell = shell
      return shell
    } catch is CancellationError {
      return nil
    } catch {
      shellDetectionMessage = error.localizedDescription
      return nil
    }
  }

  func execute(_ request: ContainerCommandRequest) async {
    guard !isRunningCommand else { return }
    isRunningCommand = true
    commandResult = nil
    errorMessage = nil
    shellDetectionMessage = nil
    defer { isRunningCommand = false }

    do {
      commandResult = try await tooling.executeCommand(in: containerID, request: request)
    } catch is CancellationError {
      errorMessage = "The command was cancelled."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func transfer(_ request: ContainerFileTransferRequest) async -> Bool {
    guard !isTransferring else { return false }
    isTransferring = true
    errorMessage = nil
    transferMessage = nil
    defer { isTransferring = false }

    do {
      switch request.direction {
      case .intoContainer:
        try await tooling.copyIntoContainer(
          id: containerID,
          source: request.localURL,
          destination: request.containerPath
        )
      case .fromContainer:
        try await tooling.copyFromContainer(
          id: containerID,
          source: request.containerPath,
          destination: request.localURL
        )
      }
      transferMessage = "Copy completed."
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearMessages() {
    errorMessage = nil
    shellDetectionMessage = nil
    transferMessage = nil
  }
}
