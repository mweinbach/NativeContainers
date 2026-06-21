import Foundation
import TerminalProgress

actor AppleContainerProgressRelay {
  private let handler: ContainerProgressHandler
  private var phase: ContainerOperationProgress.Phase = .preparing
  private var message = "Preparing"
  private var submessage: String?
  private var completedItems = 0
  private var totalItems = 0
  private var transferredBytes: Int64 = 0
  private var totalBytes: Int64 = 0

  init(handler: @escaping ContainerProgressHandler) {
    self.handler = handler
  }

  func emit(phase: ContainerOperationProgress.Phase, message: String) async {
    self.phase = phase
    self.message = message
    submessage = nil
    completedItems = 0
    totalItems = 0
    transferredBytes = 0
    totalBytes = 0
    await publish()
  }

  func consume(_ events: [ProgressUpdateEvent]) async {
    for event in events {
      switch event {
      case .setDescription(let value):
        phase = Self.phase(for: value)
        message = value
        submessage = nil
        completedItems = 0
        totalItems = 0
        transferredBytes = 0
        totalBytes = 0
      case .setSubDescription(let value):
        submessage = value
      case .addItems(let value):
        completedItems += value
      case .setItems(let value):
        completedItems = value
      case .addTotalItems(let value):
        totalItems += value
      case .setTotalItems(let value):
        totalItems = value
      case .addSize(let value):
        transferredBytes += value
      case .setSize(let value):
        transferredBytes = value
      case .addTotalSize(let value):
        totalBytes += value
      case .setTotalSize(let value):
        totalBytes = value
      case .custom(let value):
        submessage = value
      case .addTasks, .setTasks, .addTotalTasks, .setTotalTasks, .setItemsName:
        break
      }
    }
    await publish()
  }

  private func publish() async {
    let displayMessage = submessage.map { "\(message) — \($0)" } ?? message
    await handler(
      ContainerOperationProgress(
        phase: phase,
        message: displayMessage,
        completedItems: max(completedItems, 0),
        totalItems: max(totalItems, 0),
        transferredBytes: max(transferredBytes, 0),
        totalBytes: max(totalBytes, 0)
      )
    )
  }

  private static func phase(for description: String) -> ContainerOperationProgress.Phase {
    switch description.lowercased() {
    case let value where value.contains("unpack") && value.contains("init"):
      .unpackingInitImage
    case let value where value.contains("fetch") && value.contains("init"):
      .fetchingInitImage
    case let value where value.contains("unpack"):
      .unpackingImage
    case let value where value.contains("kernel"):
      .fetchingKernel
    case let value where value.contains("push") || value.contains("upload"):
      .pushingImage
    case let value where value.contains("fetch") || value.contains("pull"):
      .fetchingImage
    default:
      .preparing
    }
  }
}
