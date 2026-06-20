import Foundation
import Observation

@MainActor
@Observable
final class ContainerToolsModel {
  private(set) var isRunningCommand = false
  private(set) var isTransferring = false
  private(set) var commandResult: ContainerCommandResult?
  private(set) var errorMessage: String?
  private(set) var transferMessage: String?

  let containerID: String
  private let service: any ContainerManaging

  init(containerID: String, service: any ContainerManaging) {
    self.containerID = containerID
    self.service = service
  }

  func execute(_ request: ContainerCommandRequest) async {
    guard !isRunningCommand else { return }
    isRunningCommand = true
    commandResult = nil
    errorMessage = nil
    defer { isRunningCommand = false }

    do {
      commandResult = try await service.executeCommand(in: containerID, request: request)
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
        try await service.copyIntoContainer(
          id: containerID,
          source: request.localURL,
          destination: request.containerPath
        )
      case .fromContainer:
        try await service.copyFromContainer(
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
    transferMessage = nil
  }
}
