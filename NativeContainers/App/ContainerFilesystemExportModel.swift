import Foundation
import Observation

@MainActor
@Observable
final class ContainerFilesystemExportModel {
  private(set) var isExporting = false
  private(set) var receipt: ContainerFilesystemExportReceipt?
  private(set) var errorMessage: String?
  private(set) var warningMessage: String?

  let containerID: String
  private let container: ContainerRecord
  private let exporter: any ContainerFilesystemExporting

  init(
    container: ContainerRecord,
    exporter: any ContainerFilesystemExporting
  ) {
    self.container = container
    containerID = container.id
    self.exporter = exporter
  }

  @discardableResult
  func export(to destinationURL: URL) async -> Bool {
    guard !isExporting, receipt == nil else { return false }

    isExporting = true
    errorMessage = nil
    warningMessage = nil
    defer { isExporting = false }

    do {
      let request = try ContainerFilesystemExportRequest(
        container: container,
        destinationURL: destinationURL
      )
      receipt = try await exporter.exportFilesystem(request)
      return true
    } catch let partial as ContainerFilesystemExportPartialCompletionError {
      receipt = partial.receipt
      warningMessage = partial.localizedDescription
      return true
    } catch is CancellationError {
      errorMessage = "The export was cancelled. No destination archive was published."
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearMessages() {
    guard !isExporting, receipt == nil else { return }
    errorMessage = nil
    warningMessage = nil
  }
}
